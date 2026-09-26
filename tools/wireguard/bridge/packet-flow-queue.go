// SPDX-License-Identifier: MIT
package main

import (
	"encoding/binary"
	"errors"
	"io"
	"sync"
)

// Each direction retains at most 32 MTU-sized IPv4 packets. A blocked producer
// owns at most one additional caller buffer; no per-packet goroutines are created.
// Close discards queued plaintext and wakes all waiters. This is not zeroization.
const packetFlowQueueCapacity = 32

var errPacketFlowInput = errors.New("invalid packet flow input")

func validPacketFlowIPv4(packet []byte, mtu int) bool {
	if len(packet) < 20 || len(packet) > mtu || packet[0]>>4 != 4 {
		return false
	}
	header := int(packet[0]&15) * 4
	return header >= 20 && header <= len(packet) && int(binary.BigEndian.Uint16(packet[2:4])) == len(packet)
}

type packetFlowQueue struct {
	mu      sync.Mutex
	changed *sync.Cond
	packets [packetFlowQueueCapacity][]byte
	head    int
	count   int
	mtu     int
	closed  bool
}

func newPacketFlowQueue(mtu int) (*packetFlowQueue, error) {
	if mtu < 576 || mtu > 65535 {
		return nil, errPacketFlowInput
	}
	q := &packetFlowQueue{mtu: mtu}
	q.changed = sync.NewCond(&q.mu)
	return q, nil
}

// put copies before returning, never retains a C/Swift-owned pointer. Backpressure
// is bounded in memory, not in time: callers must close to cancel blocked I/O.
func (q *packetFlowQueue) put(packet []byte) error {
	if !validPacketFlowIPv4(packet, q.mtu) {
		return errPacketFlowInput
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	for !q.closed && q.count == len(q.packets) {
		q.changed.Wait()
	}
	if q.closed {
		return io.ErrClosedPipe
	}
	q.packets[(q.head+q.count)%len(q.packets)] = append([]byte(nil), packet...)
	q.count++
	q.changed.Broadcast()
	return nil
}

// A too-small destination does not consume the pending packet.
func (q *packetFlowQueue) read(destination []byte) (int, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for !q.closed && q.count == 0 {
		q.changed.Wait()
	}
	if q.closed {
		return 0, io.EOF
	}
	packet := q.packets[q.head]
	if len(destination) < len(packet) {
		return 0, io.ErrShortBuffer
	}
	n := copy(destination, packet)
	q.packets[q.head] = nil
	q.head = (q.head + 1) % len(q.packets)
	q.count--
	q.changed.Broadcast()
	return n, nil
}

func (q *packetFlowQueue) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.closed = true
	for index := range q.packets {
		q.packets[index] = nil
	}
	q.count = 0
	q.changed.Broadcast()
}
