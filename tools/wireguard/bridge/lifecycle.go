// SPDX-License-Identifier: MIT
package main

import (
	"errors"
	"math"
	"strings"
	"sync"
	"time"
)

const bridgeConfigLimit = 1024 * 1024

// Only the existing upstream device API crosses this seam. Tests use in-memory
// devices, never a real TUN, socket, keychain, or network-settings API.
type bridgeDevice interface {
	IpcSet(string) error
	IpcGet() (string, error)
	Up() error
	Close()
	BindUpdate() error
	SendKeepalivesToPeersWithCurrentKeypair()
	DisableSomeRoamingForBrokenMobileSemantics()
}

type bridgeEntry struct {
	handle  int32
	device  bridgeDevice
	stop    chan struct{}
	workers sync.WaitGroup
	bumping bool // protected by bridgeRegistry.mu
}

// One active engine per process. All synchronous operations are serialized with
// Close. Handles are monotonic and NEVER reused, including after a failed update.
// This is not a deadline/force-cancellation mechanism for a blocked upstream call.
type bridgeRegistry struct {
	mu         sync.Mutex
	active     *bridgeEntry
	next       int64
	retryDelay time.Duration
}

func validBridgeConfig(settings string) bool {
	return len(settings) > 0 && len(settings) <= bridgeConfigLimit && !strings.ContainsRune(settings, 0)
}

func (r *bridgeRegistry) start(settings string, create func() (bridgeDevice, error)) int32 {
	if !validBridgeConfig(settings) || create == nil {
		return -1
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active != nil || r.next > math.MaxInt32 {
		return -1 // reject before acquiring any resources
	}
	dev, err := create()
	if err != nil {
		if dev != nil {
			dev.Close()
		}
		return -1
	}
	if dev == nil {
		return -1
	}
	accepted := false
	defer func() {
		if !accepted {
			dev.Close() // the device owns the TUN/duplicated descriptor now
		}
	}()
	if err := dev.IpcSet(settings); err != nil {
		return -1
	}
	if err := dev.Up(); err != nil {
		return -1 // never publish a handle after a failed Up
	}
	handle := int32(r.next)
	r.next++
	r.active = &bridgeEntry{handle: handle, device: dev, stop: make(chan struct{})}
	accepted = true
	return handle
}

// Called with mu held. Cancel future retries before closing the owned device.
// A worker already executing a device method owns mu, so Close waits for it.
func (r *bridgeRegistry) retireLocked() *bridgeEntry {
	entry := r.active
	r.active = nil
	close(entry.stop)
	entry.device.Close()
	return entry
}

func (r *bridgeRegistry) stop(handle int32) {
	r.mu.Lock()
	if r.active == nil || r.active.handle != handle {
		r.mu.Unlock()
		return
	}
	entry := r.retireLocked()
	r.mu.Unlock()
	entry.workers.Wait() // no retry goroutine survives a completed stop
}

func bridgeErrorCode(err error) int64 {
	var coded interface{ ErrorCode() int64 }
	if errors.As(err, &coded) {
		if code := coded.ErrorCode(); code != 0 {
			return code
		}
	}
	return -1 // an error, even a malformed zero-code IPCError, is never success
}

func (r *bridgeRegistry) set(handle int32, settings string) int64 {
	if !validBridgeConfig(settings) {
		return -1
	}
	r.mu.Lock()
	if r.active == nil || r.active.handle != handle {
		r.mu.Unlock()
		return -1 // upstream used to return success for an unknown handle
	}
	err := r.active.device.IpcSet(settings)
	if err == nil {
		r.mu.Unlock()
		return 0
	}
	// IpcSet may have made partial changes. Do not expose this engine as usable.
	entry := r.retireLocked()
	r.mu.Unlock()
	entry.workers.Wait()
	return bridgeErrorCode(err)
}

func (r *bridgeRegistry) get(handle int32) (string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active == nil || r.active.handle != handle {
		return "", false
	}
	settings, err := r.active.device.IpcGet()
	return settings, err == nil && len(settings) <= bridgeConfigLimit
}

func (r *bridgeRegistry) disableRoaming(handle int32) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active != nil && r.active.handle == handle {
		r.active.device.DisableSomeRoamingForBrokenMobileSemantics()
	}
}

func (r *bridgeRegistry) bump(handle int32) {
	r.mu.Lock()
	entry := r.active
	if entry == nil || entry.handle != handle || entry.bumping {
		r.mu.Unlock()
		return // coalesce concurrent path notifications into one bounded worker
	}
	entry.bumping = true
	entry.workers.Add(1)
	r.mu.Unlock()
	go func() {
		defer entry.workers.Done()
		defer func() {
			r.mu.Lock()
			entry.bumping = false
			r.mu.Unlock()
		}()
		for attempt := 0; attempt < 10; attempt++ {
			r.mu.Lock()
			if r.active != entry {
				r.mu.Unlock()
				return
			}
			err := entry.device.BindUpdate()
			if err == nil {
				entry.device.SendKeepalivesToPeersWithCurrentKeypair()
			}
			r.mu.Unlock()
			if err == nil || attempt == 9 {
				return
			}
			timer := time.NewTimer(r.retryDelay)
			select {
			case <-entry.stop:
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	}()
}
