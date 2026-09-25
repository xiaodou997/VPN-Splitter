/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 * VPN-Splitter build-candidate adaptation: checked ownership and serialized lifecycle.
 */

package main

// #include <stdlib.h>
// #include <string.h>
// static size_t splitterConfigLength(const char *s) { return strnlen(s, 1048577); }
import "C"

import (
	"os"
	"time"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

// Must match the locked engine revision. This bridge is built inside that module,
// so ReadBuildInfo().Deps does not reliably contain the engine itself.
const splitterEngineRevision = "ecfc5a8d54462e18e13c72173e2623d16d8e25a0"

var engines = bridgeRegistry{retryDelay: time.Second / 2}

// settings must be a valid readable C string, owned by the caller for this call.
// No pointer is retained. Invalid native pointers cannot be validated by Go.
func bridgeSettings(settings *C.char) (string, bool) {
	if settings == nil {
		return "", false
	}
	n := C.splitterConfigLength(settings)
	if n == 0 || n > bridgeConfigLimit {
		return "", false
	}
	return C.GoStringN(settings, C.int(n)), true
}

// createBridgeDevice borrows the provider descriptor and only duplicates it.
// Ownership is handed to the PINNED Darwin CreateTUNFromFile, which closes its
// file on every error path; never close the raw fd again after that handoff.
func createBridgeDevice(tunFd int32) (bridgeDevice, error) {
	dupFD, err := unix.Dup(int(tunFd))
	if err != nil {
		return nil, err
	}
	if err = unix.SetNonblock(dupFD, true); err != nil {
		unix.Close(dupFD)
		return nil, err
	}
	file := os.NewFile(uintptr(dupFD), "/dev/tun")
	if file == nil {
		unix.Close(dupFD)
		return nil, unix.EBADF
	}
	tunDevice, err := tun.CreateTUNFromFile(file, 0)
	if err != nil {
		return nil, err // upstream has already closed file, including its finalizer
	}
	logger := &device.Logger{Verbosef: device.DiscardLogf, Errorf: device.DiscardLogf}
	return device.NewDevice(tunDevice, conn.NewStdNetBind(), logger), nil
}

//export wgSetLogger
func wgSetLogger(context, loggerFn uintptr) {
	// Intentionally disabled for this candidate. Do not retain raw Swift pointers
	// or forward arbitrary engine text. No SIGUSR2 stack-dump handler is installed.
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32) int32 {
	config, ok := bridgeSettings(settings)
	if !ok || tunFd < 0 {
		return -1
	}
	return engines.start(config, func() (bridgeDevice, error) { return createBridgeDevice(tunFd) })
}

//export wgTurnOff
func wgTurnOff(handle int32) { engines.stop(handle) }

//export wgSetConfig
func wgSetConfig(handle int32, settings *C.char) int64 {
	config, ok := bridgeSettings(settings)
	if !ok {
		return -1
	}
	return engines.set(handle, config)
}

//export wgGetConfig
func wgGetConfig(handle int32) *C.char {
	settings, ok := engines.get(handle)
	if !ok {
		return nil
	}
	// Existing ABI: the caller must free this buffer. It may contain keys; this
	// is NOT a sanitized diagnostic interface and must never be logged/exported.
	return C.CString(settings)
}

//export wgBumpSockets
func wgBumpSockets(handle int32) { engines.bump(handle) }

//export wgDisableSomeRoamingForBrokenMobileSemantics
func wgDisableSomeRoamingForBrokenMobileSemantics(handle int32) { engines.disableRoaming(handle) }

//export wgVersion
func wgVersion() *C.char { return C.CString(splitterEngineRevision) }

func main() {}
