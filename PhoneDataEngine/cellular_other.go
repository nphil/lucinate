//go:build !darwin

package main

import "syscall"

// bindToInterface does nothing off Apple platforms: IP_BOUND_IF is Darwin's, and the machines the
// tests run on have no pdp_ip* interface to bind to anyway.
func bindToInterface(syscall.RawConn, bool, int) error { return nil }
