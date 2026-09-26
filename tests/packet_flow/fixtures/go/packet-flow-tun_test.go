// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"golang.zx2c4.com/wireguard/tun"
	"io"
	"testing"
)

func TestFlowTUNUsesNoDescriptor(t *testing.T) {
	f, _ := newPacketFlowTUN(1420)
	defer f.Close()
	if f.File() != nil || f.BatchSize() != 1 {
		t.Fatal("unexpected native resource")
	}
	if m, e := f.MTU(); e != nil || m != 1420 {
		t.Fatal("bad MTU")
	}
	if n, e := f.Name(); e != nil || n != "vpnsplitter-packet-flow" {
		t.Fatal("OS interface claimed")
	}
	if e := <-f.Events(); e != tun.EventUp {
		t.Fatal("missing up event")
	}
	f.Close()
	if _, ok := <-f.Events(); ok {
		t.Fatal("event stream not closed")
	}
}
func TestFlowTUNReadUsesOffsetAndSizes(t *testing.T) {
	f, _ := newPacketFlowTUN(1420)
	defer f.Close()
	p := flowPacket(64, 11)
	_ = f.input.put(p)
	buf := bytes.Repeat([]byte{99}, 160)
	sizes := []int{999}
	n, err := f.Read([][]byte{buf}, sizes, 16)
	if err != nil || n != 1 || sizes[0] != 64 || !bytes.Equal(buf[16:80], p) || buf[15] != 99 || buf[80] != 99 {
		t.Fatal("read changed framing")
	}
}
func TestFlowTUNWriteUsesOffset(t *testing.T) {
	f, _ := newPacketFlowTUN(1420)
	defer f.Close()
	p := flowPacket(64, 11)
	n, err := f.Write([][]byte{append(make([]byte, 16), p...)}, 16)
	if err != nil || n != 1 {
		t.Fatal("write rejected")
	}
	out := make([]byte, 64)
	_, err = f.output.read(out)
	if err != nil || !bytes.Equal(out, p) {
		t.Fatal("write changed framing")
	}
}
func TestFlowTUNRejectsInvalidBuffers(t *testing.T) {
	f, _ := newPacketFlowTUN(1420)
	defer f.Close()
	for _, o := range []int{-1, 100} {
		if _, e := f.Read([][]byte{make([]byte, 64)}, []int{0}, o); e == nil {
			t.Fatal("bad read offset")
		}
		if _, e := f.Write([][]byte{make([]byte, 64)}, o); e == nil {
			t.Fatal("bad write offset")
		}
	}
	if _, e := f.Read(nil, nil, 0); e == nil {
		t.Fatal("missing buffers")
	}
	if _, e := f.Read([][]byte{make([]byte, 64)}, nil, 0); e == nil {
		t.Fatal("missing sizes")
	}
	if _, e := f.Write(nil, 0); e == nil {
		t.Fatal("missing packet")
	}
}
func TestFlowTUNCloseReleasesBothDirections(t *testing.T) {
	f, _ := newPacketFlowTUN(1420)
	read := make(chan error, 1)
	write := make(chan error, 1)
	for i := 0; i < packetFlowQueueCapacity; i++ {
		_ = f.output.put(flowPacket(64, 0))
	}
	go func() { _, e := f.Read([][]byte{make([]byte, 1420)}, []int{0}, 0); read <- e }()
	go func() { _, e := f.Write([][]byte{flowPacket(64, 1)}, 0); write <- e }()
	f.Close()
	f.Close()
	if waitFlow(t, read) != io.EOF || waitFlow(t, write) != io.ErrClosedPipe {
		t.Fatal("close did not release I/O")
	}
}
func TestFlowTUNNoPartialWriteOnBadPacket(t *testing.T) {
	f, _ := newPacketFlowTUN(1420)
	defer f.Close()
	if n, e := f.Write([][]byte{make([]byte, 64)}, 0); n != 0 || e == nil {
		t.Fatal("bad packet written")
	}
	if f.output.count != 0 {
		t.Fatal("bad output queued")
	}
}
