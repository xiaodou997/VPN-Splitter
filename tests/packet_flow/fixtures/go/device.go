// SPDX-License-Identifier: MIT
// TEST DOUBLE: plaintext echo through the ACTUAL packetFlow tun.Device; no cipher,
// handshake, socket, routing, or WireGuard engine behavior is tested.
package device

import (
	"golang.zx2c4.com/wireguard/tun"
	"sync"
)

type Logger struct{ Verbosef, Errorf func(string, ...any) }

func DiscardLogf(string, ...any) {}

type Device struct {
	flow    tun.Device
	workers sync.WaitGroup
	once    sync.Once
}

func NewDevice(flow tun.Device, _ any, _ *Logger) *Device { return &Device{flow: flow} }
func (d *Device) Up() error {
	d.workers.Add(1)
	go func() {
		defer d.workers.Done()
		data := make([]byte, 65535+16)
		sizes := []int{0}
		for {
			n, err := d.flow.Read([][]byte{data}, sizes, 16)
			if err != nil {
				return
			}
			if n != 1 {
				panic("unexpected batch")
			}
			if _, err := d.flow.Write([][]byte{data[:16+sizes[0]]}, 16); err != nil {
				return
			}
		}
	}()
	return nil
}
func (d *Device) Close() { d.once.Do(func() { d.flow.Close(); d.workers.Wait() }) }
