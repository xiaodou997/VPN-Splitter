// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"sync"
	"testing"
	"time"
)

func flowPacket(length int, value byte) []byte {
	p := make([]byte, length)
	p[0] = 0x45
	binary.BigEndian.PutUint16(p[2:4], uint16(length))
	for i := 20; i < length; i++ {
		p[i] = value
	}
	return p
}
func flowQueue(t *testing.T) *packetFlowQueue {
	t.Helper()
	q, err := newPacketFlowQueue(1420)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(q.close)
	return q
}
func waitFlow(t *testing.T, finished <-chan error) error {
	t.Helper()
	select {
	case err := <-finished:
		return err
	case <-time.After(2 * time.Second):
		t.Fatal("worker did not settle")
		return nil
	}
}
func TestFlowMTUBounds(t *testing.T) {
	for _, n := range []int{-1, 0, 575, 65536} {
		if _, err := newPacketFlowQueue(n); err == nil {
			t.Fatal("accepted invalid MTU")
		}
	}
	for _, n := range []int{576, 1420, 65535} {
		q, err := newPacketFlowQueue(n)
		if err != nil {
			t.Fatal(err)
		}
		q.close()
	}
}
func TestFlowCopiesInputAndOutput(t *testing.T) {
	q := flowQueue(t)
	p := flowPacket(64, 7)
	expected := append([]byte(nil), p...)
	if err := q.put(p); err != nil {
		t.Fatal(err)
	}
	p[20] = 99
	out := make([]byte, 1420)
	n, err := q.read(out)
	if err != nil || !bytes.Equal(out[:n], expected) {
		t.Fatal("not an isolated copy")
	}
	out[20] = 88
	if q.count != 0 || q.packets[0] != nil {
		t.Fatal("consumed plaintext retained")
	}
}
func TestFlowRejectsMalformedPackets(t *testing.T) {
	q := flowQueue(t)
	cases := [][]byte{nil, make([]byte, 19), flowPacket(1421, 0)}
	for _, mutate := range []func([]byte){func(p []byte) { p[0] = 0x65 }, func(p []byte) { p[0] = 0x44 }, func(p []byte) { p[0] = 0x4f }, func(p []byte) { p[3]++ }} {
		p := flowPacket(40, 1)
		mutate(p)
		cases = append(cases, p)
	}
	for _, p := range cases {
		if q.put(p) == nil {
			t.Fatal("malformed packet accepted")
		}
	}
	if q.count != 0 {
		t.Fatal("invalid input changed queue")
	}
}
func TestFlowIPv4Options(t *testing.T) {
	q := flowQueue(t)
	p := flowPacket(64, 8)
	p[0] = 0x46
	if err := q.put(p); err != nil {
		t.Fatal(err)
	}
}
func TestFlowShortReadDoesNotConsume(t *testing.T) {
	q := flowQueue(t)
	p := flowPacket(64, 8)
	_ = q.put(p)
	if _, err := q.read(make([]byte, 63)); err != io.ErrShortBuffer {
		t.Fatal(err)
	}
	out := make([]byte, 64)
	n, err := q.read(out)
	if err != nil || n != 64 || !bytes.Equal(out, p) {
		t.Fatal("short buffer consumed packet")
	}
}
func TestFlowFIFOAndRingWrap(t *testing.T) {
	q := flowQueue(t)
	for round := 0; round < 5; round++ {
		for i := 0; i < packetFlowQueueCapacity; i++ {
			_ = q.put(flowPacket(64, byte(i)))
		}
		for i := 0; i < packetFlowQueueCapacity; i++ {
			p := make([]byte, 64)
			_, err := q.read(p)
			if err != nil || p[20] != byte(i) {
				t.Fatal("order changed")
			}
		}
	}
}
func TestFlowCloseUnblocksReader(t *testing.T) {
	q := flowQueue(t)
	done := make(chan error, 1)
	go func() { _, err := q.read(make([]byte, 1420)); done <- err }()
	q.close()
	if err := waitFlow(t, done); err != io.EOF {
		t.Fatal(err)
	}
}
func TestFlowCloseUnblocksFullWriter(t *testing.T) {
	q := flowQueue(t)
	for i := 0; i < packetFlowQueueCapacity; i++ {
		_ = q.put(flowPacket(64, 0))
	}
	done := make(chan error, 1)
	go func() { done <- q.put(flowPacket(64, 7)) }()
	q.close()
	if err := waitFlow(t, done); err != io.ErrClosedPipe {
		t.Fatal(err)
	}
}
func TestFlowBackpressureResumesAfterRead(t *testing.T) {
	q := flowQueue(t)
	for i := 0; i < packetFlowQueueCapacity; i++ {
		_ = q.put(flowPacket(64, 0))
	}
	done := make(chan error, 1)
	go func() { done <- q.put(flowPacket(64, 7)) }()
	select {
	case <-done:
		t.Fatal("capacity was not enforced")
	case <-time.After(10 * time.Millisecond):
	}
	_, _ = q.read(make([]byte, 64))
	if err := waitFlow(t, done); err != nil {
		t.Fatal(err)
	}
}
func TestFlowCloseDiscardsAndCannotRestart(t *testing.T) {
	q := flowQueue(t)
	_ = q.put(flowPacket(64, 7))
	q.close()
	q.close()
	if q.put(flowPacket(64, 1)) != io.ErrClosedPipe {
		t.Fatal("queue reopened")
	}
	if _, err := q.read(make([]byte, 64)); err != io.EOF {
		t.Fatal("closed queue emitted packet")
	}
	for _, p := range q.packets {
		if p != nil {
			t.Fatal("plaintext reference retained")
		}
	}
}
func TestFlowConcurrentProducersAndConsumer(t *testing.T) {
	q := flowQueue(t)
	var writers sync.WaitGroup
	for i := 0; i < 8; i++ {
		writers.Add(1)
		go func(value byte) {
			defer writers.Done()
			for j := 0; j < 80; j++ {
				if err := q.put(flowPacket(64, value)); err != nil {
					t.Error(err)
					return
				}
			}
		}(byte(i))
	}
	counts := [8]int{}
	for i := 0; i < 640; i++ {
		p := make([]byte, 1420)
		n, err := q.read(p)
		if err != nil || n != 64 || p[20] >= 8 {
			t.Fatal("corrupt packet")
		}
		counts[p[20]]++
	}
	writers.Wait()
	for _, count := range counts {
		if count != 80 {
			t.Fatal("packet loss")
		}
	}
}
func TestFlowConcurrentCloseAndIO(t *testing.T) {
	q := flowQueue(t)
	var workers sync.WaitGroup
	for i := 0; i < 16; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for q.put(flowPacket(64, 1)) == nil {
			}
		}()
	}
	for i := 0; i < 8; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for {
				if _, err := q.read(make([]byte, 1420)); err != nil {
					return
				}
			}
		}()
	}
	q.close()
	workers.Wait()
}
