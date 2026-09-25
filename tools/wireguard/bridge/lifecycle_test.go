// SPDX-License-Identifier: MIT
package main

import (
	"errors"
	"fmt"
	"math"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Explicit engine double. It owns no descriptor, socket, route, or credentials.
type fakeBridgeDevice struct {
	mu          sync.Mutex
	calls       []string
	closed      bool
	postClose   int
	setError    error
	upError     error
	getError    error
	bindError   error
	getValue    string
	bindEntered chan struct{}
	bindRelease chan struct{}
	setEntered  chan struct{}
	setRelease  chan struct{}
}

func (d *fakeBridgeDevice) record(method string) {
	if d.closed {
		d.postClose++
	}
	d.calls = append(d.calls, method)
}
func (d *fakeBridgeDevice) IpcSet(string) error {
	d.mu.Lock()
	d.record("set")
	entered, release, err := d.setEntered, d.setRelease, d.setError
	d.mu.Unlock()
	if entered != nil {
		entered <- struct{}{}
		<-release
	}
	return err
}
func (d *fakeBridgeDevice) Up() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.record("up")
	return d.upError
}
func (d *fakeBridgeDevice) IpcGet() (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.record("get")
	return d.getValue, d.getError
}
func (d *fakeBridgeDevice) Close() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.record("close")
	d.closed = true
}
func (d *fakeBridgeDevice) BindUpdate() error {
	d.mu.Lock()
	d.record("bind")
	entered, release, err := d.bindEntered, d.bindRelease, d.bindError
	d.mu.Unlock()
	if entered != nil {
		entered <- struct{}{}
		<-release
	}
	return err
}
func (d *fakeBridgeDevice) SendKeepalivesToPeersWithCurrentKeypair() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.record("keepalive")
}
func (d *fakeBridgeDevice) DisableSomeRoamingForBrokenMobileSemantics() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.record("roaming")
}
func (d *fakeBridgeDevice) snapshot() ([]string, int) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.calls...), d.postClose
}
func newFake(r *bridgeRegistry, d *fakeBridgeDevice) int32 {
	return r.start("synthetic-settings\n", func() (bridgeDevice, error) { return d, nil })
}
func await(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatal("test synchronization timed out")
	}
}
func requireCalls(t *testing.T, d *fakeBridgeDevice, want []string) {
	t.Helper()
	got, after := d.snapshot()
	if !reflect.DeepEqual(got, want) || after != 0 {
		t.Fatalf("calls %v; post-close %d; want %v", got, after, want)
	}
}

func TestStartPublishesOnlyAfterSetAndUp(t *testing.T) {
	r := &bridgeRegistry{}
	d := &fakeBridgeDevice{getValue: "synthetic-runtime"}
	h := newFake(r, d)
	if h < 0 {
		t.Fatal("unexpected rejection")
	}
	if value, ok := r.get(h); !ok || value != d.getValue {
		t.Fatal("missing owned device")
	}
	r.stop(h)
	r.stop(h)
	requireCalls(t, d, []string{"set", "up", "get", "close"})
}
func TestStartFactoryErrorsReleaseReturnedOwnership(t *testing.T) {
	for _, withDevice := range []bool{false, true} {
		r := &bridgeRegistry{}
		d := &fakeBridgeDevice{}
		h := r.start("synthetic", func() (bridgeDevice, error) {
			if withDevice {
				return d, errors.New("synthetic failure")
			}
			return nil, errors.New("synthetic failure")
		})
		if h >= 0 || r.active != nil {
			t.Fatal("failed factory published a handle")
		}
		if withDevice {
			requireCalls(t, d, []string{"close"})
		}
	}
	r := &bridgeRegistry{}
	if r.start("synthetic", func() (bridgeDevice, error) { return nil, nil }) >= 0 {
		t.Fatal("nil accepted")
	}
}
func TestFailedInitialSetClosesDeviceAndNeverCallsUp(t *testing.T) {
	r := &bridgeRegistry{}
	d := &fakeBridgeDevice{setError: errors.New("synthetic-secret-do-not-log")}
	if newFake(r, d) >= 0 || r.active != nil {
		t.Fatal("failed configuration published")
	}
	requireCalls(t, d, []string{"set", "close"})
	if newFake(r, &fakeBridgeDevice{}) < 0 {
		t.Fatal("failure leaked active slot")
	}
	r.stop(0)
}
func TestFailedUpClosesWholeDeviceExactlyOnce(t *testing.T) {
	r := &bridgeRegistry{}
	d := &fakeBridgeDevice{upError: errors.New("synthetic-bind-failure")}
	if newFake(r, d) >= 0 || r.active != nil {
		t.Fatal("failed Up reported success")
	}
	r.stop(0)
	requireCalls(t, d, []string{"set", "up", "close"})
}
func TestInvalidConfigurationRejectedBeforeFactory(t *testing.T) {
	for _, config := range []string{"", "synthetic\x00trailer", strings.Repeat("x", bridgeConfigLimit+1)} {
		r := &bridgeRegistry{}
		if r.start(config, func() (bridgeDevice, error) { t.Fatal("factory was called"); return nil, nil }) >= 0 {
			t.Fatal("invalid accepted")
		}
	}
	if (&bridgeRegistry{}).start("synthetic", nil) >= 0 {
		t.Fatal("nil factory accepted")
	}
}
func TestSingleActiveSlotRejectsBeforeResourceCreation(t *testing.T) {
	r := &bridgeRegistry{}
	h := newFake(r, &fakeBridgeDevice{})
	if r.start("synthetic", func() (bridgeDevice, error) { t.Fatal("second device created"); return nil, nil }) >= 0 {
		t.Fatal("second start succeeded")
	}
	r.stop(h)
}
func TestConcurrentStartsPublishOneDevice(t *testing.T) {
	r := &bridgeRegistry{}
	var created atomic.Int32
	var accepted atomic.Int32
	var work sync.WaitGroup
	for i := 0; i < 64; i++ {
		work.Add(1)
		go func() {
			defer work.Done()
			if r.start("synthetic", func() (bridgeDevice, error) { created.Add(1); return &fakeBridgeDevice{}, nil }) >= 0 {
				accepted.Add(1)
			}
		}()
	}
	work.Wait()
	if created.Load() != 1 || accepted.Load() != 1 {
		t.Fatal("duplicate engine acquisition")
	}
	r.stop(0)
}
func TestStoppedHandlesAreNeverReused(t *testing.T) {
	r := &bridgeRegistry{}
	for i := int32(0); i < 40; i++ {
		d := &fakeBridgeDevice{}
		h := newFake(r, d)
		if h != i {
			t.Fatal("handle sequence mismatch")
		}
		if i > 0 {
			r.stop(i - 1)
			r.bump(i - 1)
			r.disableRoaming(i - 1)
			if r.set(i-1, "synthetic") == 0 {
				t.Fatal("old handle accepted")
			}
			if _, ok := r.get(i - 1); ok {
				t.Fatal("old handle read new engine")
			}
		}
		r.stop(h)
		requireCalls(t, d, []string{"set", "up", "close"})
	}
}
func TestHandleExhaustionNeverWrapsOrAcquires(t *testing.T) {
	r := &bridgeRegistry{next: math.MaxInt32}
	h := newFake(r, &fakeBridgeDevice{})
	if h != math.MaxInt32 {
		t.Fatal("last valid handle rejected")
	}
	r.stop(h)
	if r.start("synthetic", func() (bridgeDevice, error) { t.Fatal("exhausted factory called"); return nil, nil }) >= 0 {
		t.Fatal("handle wrapped")
	}
}

type fakeCode int64

func (e fakeCode) Error() string    { return "synthetic-error-no-input" }
func (e fakeCode) ErrorCode() int64 { return int64(e) }
func TestUpdateFailureRetiresPartialDeviceAndPreservesError(t *testing.T) {
	for _, code := range []int64{-22, 7, 0} {
		r := &bridgeRegistry{}
		d := &fakeBridgeDevice{}
		h := newFake(r, d)
		d.mu.Lock()
		d.setError = fmt.Errorf("wrapped: %w", fakeCode(code))
		d.mu.Unlock()
		want := code
		if want == 0 {
			want = -1
		}
		if got := r.set(h, "synthetic-update"); got != want {
			t.Fatalf("code %d, want %d", got, want)
		}
		if _, ok := r.get(h); ok {
			t.Fatal("partial device remained usable")
		}
		r.stop(h)
		requireCalls(t, d, []string{"set", "up", "set", "close"})
		if h2 := newFake(r, &fakeBridgeDevice{}); h2 <= h {
			t.Fatal("failed update allowed reuse")
		} else {
			r.stop(h2)
		}
	}
}
func TestInvalidHandleAndInvalidUpdateNeverReportSuccess(t *testing.T) {
	r := &bridgeRegistry{}
	if r.set(22, "synthetic") == 0 {
		t.Fatal("unknown handle succeeded")
	}
	d := &fakeBridgeDevice{}
	h := newFake(r, d)
	if r.set(h, "") == 0 {
		t.Fatal("empty update succeeded")
	}
	if r.set(h, "valid-update") != 0 {
		t.Fatal("valid update failed")
	}
	r.disableRoaming(h)
	r.stop(h)
	requireCalls(t, d, []string{"set", "up", "set", "roaming", "close"})
}
func TestRuntimeReadErrorsAndSizeAreRejected(t *testing.T) {
	for _, d := range []*fakeBridgeDevice{{getError: errors.New("synthetic")}, {getValue: strings.Repeat("x", bridgeConfigLimit+1)}} {
		r := &bridgeRegistry{}
		h := newFake(r, d)
		if _, ok := r.get(h); ok {
			t.Fatal("read failure accepted")
		}
		r.stop(h)
	}
}
func TestStopWaitsForInFlightUpdate(t *testing.T) {
	r := &bridgeRegistry{}
	d := &fakeBridgeDevice{}
	h := newFake(r, d)
	d.mu.Lock()
	d.setEntered = make(chan struct{}, 1)
	d.setRelease = make(chan struct{})
	d.mu.Unlock()
	updated, stopped := make(chan struct{}), make(chan struct{})
	go func() { r.set(h, "synthetic-update"); close(updated) }()
	await(t, d.setEntered)
	go func() { r.stop(h); close(stopped) }()
	select {
	case <-stopped:
		t.Fatal("closed during an update")
	default:
	}
	close(d.setRelease)
	await(t, updated)
	await(t, stopped)
	requireCalls(t, d, []string{"set", "up", "set", "close"})
}
func TestStopCancelsSleepingRebindAndJoinsWorker(t *testing.T) {
	r := &bridgeRegistry{retryDelay: time.Hour}
	d := &fakeBridgeDevice{bindError: errors.New("synthetic"), bindEntered: make(chan struct{}, 1), bindRelease: make(chan struct{})}
	h := newFake(r, d)
	r.bump(h)
	await(t, d.bindEntered)
	close(d.bindRelease)
	stopped := make(chan struct{})
	go func() { r.stop(h); close(stopped) }()
	await(t, stopped)
	requireCalls(t, d, []string{"set", "up", "bind", "close"})
	if d2 := newFake(r, &fakeBridgeDevice{}); d2 <= h {
		t.Fatal("old worker identity reused")
	} else {
		r.stop(d2)
	}
}
func TestRebindRetriesAreBoundedAndCoalesced(t *testing.T) {
	r := &bridgeRegistry{retryDelay: time.Millisecond}
	d := &fakeBridgeDevice{bindError: errors.New("synthetic")}
	h := newFake(r, d)
	r.bump(h)
	r.mu.Lock()
	entry := r.active
	r.mu.Unlock()
	entry.workers.Wait()
	r.stop(h)
	calls, after := d.snapshot()
	binds := 0
	for _, call := range calls {
		if call == "bind" {
			binds++
		}
	}
	if binds != 10 || after != 0 {
		t.Fatalf("retries %d / after-close %d", binds, after)
	}
}
func TestRepeatedBumpCoalescesWhileSleeping(t *testing.T) {
	r := &bridgeRegistry{retryDelay: time.Hour}
	d := &fakeBridgeDevice{bindError: errors.New("synthetic"), bindEntered: make(chan struct{}, 1), bindRelease: make(chan struct{})}
	h := newFake(r, d)
	r.bump(h)
	await(t, d.bindEntered)
	close(d.bindRelease)
	for i := 0; i < 100; i++ {
		r.bump(h)
	}
	r.stop(h)
	requireCalls(t, d, []string{"set", "up", "bind", "close"})
}
func TestSuccessfulRebindSendsKeepaliveOnce(t *testing.T) {
	r := &bridgeRegistry{}
	d := &fakeBridgeDevice{}
	h := newFake(r, d)
	r.mu.Lock()
	entry := r.active
	r.mu.Unlock()
	r.bump(h)
	entry.workers.Wait()
	r.stop(h)
	requireCalls(t, d, []string{"set", "up", "bind", "keepalive", "close"})
}
func TestConcurrentCallsAndStopNeverUseClosedDevice(t *testing.T) {
	for round := 0; round < 30; round++ {
		r := &bridgeRegistry{retryDelay: time.Hour}
		d := &fakeBridgeDevice{bindError: errors.New("synthetic")}
		h := newFake(r, d)
		var work sync.WaitGroup
		for i := 0; i < 32; i++ {
			work.Add(1)
			go func() { defer work.Done(); r.set(h, "synthetic-update"); r.get(h); r.bump(h); r.disableRoaming(h) }()
		}
		r.stop(h)
		work.Wait()
		calls, after := d.snapshot()
		closed := 0
		for _, call := range calls {
			if call == "close" {
				closed++
			}
		}
		if after != 0 || closed != 1 {
			t.Fatalf("post-close calls %d, Close calls %d", after, closed)
		}
	}
}
