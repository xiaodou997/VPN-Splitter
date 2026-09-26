// SPDX-License-Identifier: MIT
package main

import (
	"os"
	"sync"

	"golang.zx2c4.com/wireguard/tun"
)

// An in-process tun.Device backed by the SAME NEPacketTunnelProvider.packetFlow.
// It does not open a TUN, create an interface, configure routes, or borrow any fd.
// The name is an internal engine label, never an OS interface/ownership claim.
type packetFlowTUN struct {
	input, output *packetFlowQueue
	events        chan tun.Event
	mtu           int
	once          sync.Once
}

var _ tun.Device = (*packetFlowTUN)(nil)

func newPacketFlowTUN(mtu int) (*packetFlowTUN, error) {
	input, err := newPacketFlowQueue(mtu)
	if err != nil {
		return nil, err
	}
	output, err := newPacketFlowQueue(mtu)
	if err != nil {
		input.close()
		return nil, err
	}
	result := &packetFlowTUN{input: input, output: output, mtu: mtu, events: make(chan tun.Event, 1)}
	result.events <- tun.EventUp
	return result, nil
}

func (t *packetFlowTUN) File() *os.File           { return nil }
func (t *packetFlowTUN) Name() (string, error)    { return "vpnsplitter-packet-flow", nil }
func (t *packetFlowTUN) MTU() (int, error)        { return t.mtu, nil }
func (t *packetFlowTUN) BatchSize() int           { return 1 }
func (t *packetFlowTUN) Events() <-chan tun.Event { return t.events }
func (t *packetFlowTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if len(bufs) != 1 || len(sizes) < len(bufs) || offset < 0 || offset > len(bufs[0]) {
		return 0, errPacketFlowInput
	}
	sizes[0] = 0
	n, err := t.input.read(bufs[0][offset:])
	if err != nil {
		return 0, err
	}
	sizes[0] = n
	return 1, nil
}
func (t *packetFlowTUN) Write(bufs [][]byte, offset int) (int, error) {
	if len(bufs) != 1 || offset < 0 || offset > len(bufs[0]) {
		return 0, errPacketFlowInput
	}
	if err := t.output.put(bufs[0][offset:]); err != nil {
		return 0, err
	}
	return 1, nil
}
func (t *packetFlowTUN) Close() error {
	t.once.Do(func() {
		t.input.close()
		t.output.close()
		close(t.events)
	})
	return nil
}
