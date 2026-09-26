// SPDX-License-Identifier: MIT
// TEST DOUBLE: production lifecycle.go is not replaced in native builds.
package main

// #include <string.h>
// static size_t configLength(const char *s) { return strnlen(s, 1048577); }
import "C"
import "sync"

type bridgeDevice interface {
	Up() error
	Close()
}
type fixtureRegistry struct {
	sync.Mutex
	next  int32
	items map[int32]bridgeDevice
}

var engines = fixtureRegistry{items: make(map[int32]bridgeDevice)}

func (r *fixtureRegistry) start(_ string, create func() (bridgeDevice, error)) int32 {
	d, err := create()
	if err != nil {
		return -1
	}
	if err = d.Up(); err != nil {
		d.Close()
		return -1
	}
	r.Lock()
	defer r.Unlock()
	r.next++
	r.items[r.next] = d
	return r.next
}
func (r *fixtureRegistry) stop(h int32) {
	r.Lock()
	d := r.items[h]
	delete(r.items, h)
	r.Unlock()
	if d != nil {
		d.Close()
	}
}
func bridgeSettings(s *C.char) (string, bool) {
	if s == nil {
		return "", false
	}
	n := C.configLength(s)
	if n == 0 || n > 1048576 {
		return "", false
	}
	return C.GoStringN(s, C.int(n)), true
}
func main() {}
