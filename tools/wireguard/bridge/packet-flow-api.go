// SPDX-License-Identifier: MIT
package main

// #include <stdint.h>
import "C"

import (
	"sync"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

// Registry locks never span blocking packet I/O or engine shutdown. Handles come
// from the existing monotonic lifecycle registry; stopped handles are not reused.
var packetFlows = struct {
	sync.Mutex
	items    map[int32]*packetFlowTUN
	starting bool
	stopping bool
}{items: make(map[int32]*packetFlowTUN)}

func findPacketFlow(handle int32) *packetFlowTUN {
	packetFlows.Lock()
	defer packetFlows.Unlock()
	return packetFlows.items[handle]
}

//export wgTurnOnPacketFlow
func wgTurnOnPacketFlow(settings *C.char, mtu int32) int32 {
	config, ok := bridgeSettings(settings)
	if !ok {
		return -1
	}
	packetFlows.Lock()
	if packetFlows.starting || packetFlows.stopping || len(packetFlows.items) != 0 {
		packetFlows.Unlock()
		return -1
	}
	packetFlows.starting = true
	packetFlows.Unlock()
	defer func() {
		packetFlows.Lock()
		packetFlows.starting = false
		packetFlows.Unlock()
	}()
	flow, err := newPacketFlowTUN(int(mtu))
	if err != nil {
		return -1
	}
	handle := engines.start(config, func() (bridgeDevice, error) {
		logger := &device.Logger{Verbosef: device.DiscardLogf, Errorf: device.DiscardLogf}
		return device.NewDevice(flow, conn.NewStdNetBind(), logger), nil
	})
	if handle < 0 {
		flow.Close()
		return -1
	}
	packetFlows.Lock()
	packetFlows.items[handle] = flow
	packetFlows.Unlock()
	return handle
}

// Pair ONLY with wgTurnOnPacketFlow. Closing queues first interrupts C/Swift and
// WireGuard workers before engines.stop waits for the engine's lifecycle lock.
//
//export wgTurnOffPacketFlow
func wgTurnOffPacketFlow(handle int32) {
	packetFlows.Lock()
	flow := packetFlows.items[handle]
	delete(packetFlows.items, handle)
	if flow != nil {
		packetFlows.stopping = true
	}
	packetFlows.Unlock()
	if flow != nil {
		flow.Close()
		engines.stop(handle)
		packetFlows.Lock()
		packetFlows.stopping = false
		packetFlows.Unlock()
	}
}

// Buffers must be valid, caller-owned memory throughout the call. No pointer is
// retained. A length check cannot prove arbitrary native pointers are safe.
//
//export wgReadPacketFlow
func wgReadPacketFlow(handle int32, buffer *C.uint8_t, capacity int32) int32 {
	flow := findPacketFlow(handle)
	if flow == nil || buffer == nil || capacity < int32(flow.mtu) || capacity > 65535 {
		return -1
	}
	n, err := flow.output.read(unsafe.Slice((*byte)(unsafe.Pointer(buffer)), int(capacity)))
	if err != nil {
		return -1
	}
	return int32(n)
}

//export wgWritePacketFlow
func wgWritePacketFlow(handle int32, buffer *C.uint8_t, length int32) int32 {
	flow := findPacketFlow(handle)
	if flow == nil || buffer == nil || length < 20 || length > int32(flow.mtu) {
		return -1
	}
	if flow.input.put(unsafe.Slice((*byte)(unsafe.Pointer(buffer)), int(length))) != nil {
		return -1
	}
	return length
}
