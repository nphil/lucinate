package main

import "syscall"

// bindToInterface ties the socket to the interface with this index, so what it sends and receives
// uses that interface only, whatever the routing table says. IP_BOUND_IF is Darwin's, and
// IPV6_BOUND_IF is its IPv6 twin. iOS builds use this file too, since GOOS=ios counts as darwin.
func bindToInterface(c syscall.RawConn, ipv6 bool, index int) error {
	var err error
	if cerr := c.Control(func(fd uintptr) {
		if ipv6 {
			err = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF, index)
		} else {
			err = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF, index)
		}
	}); cerr != nil {
		return cerr
	}
	return err
}
