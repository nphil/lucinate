package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"syscall"
)

// Every socket the engine opens for a router's traffic is bound to the iPhone's cellular interface
// when there is one. Left to the routing table, the traffic would take the phone's Wi-Fi whenever
// it is joined to a network: the router's own, which sends it straight back to the router, or a
// hotel's, where the carrier never counts it as the phone's own data. The WireGuard socket in
// bind.go is the one socket that isn't bound: it has to face the router.
//
// Binding is Darwin's IP_BOUND_IF, see cellular_darwin.go. Elsewhere there is nothing to bind to,
// which is also what lets the tests run on Linux.

// cellularPrefix starts the name of each of the iPhone's cellular interfaces. pdp_ip0 is normally
// the data connection, and the others are for things like voice and messages.
const cellularPrefix = "pdp_ip"

// ifaceInfo is what choosing the cellular interface needs to know about a network interface.
type ifaceInfo struct {
	Name  string
	Index int
	Up    bool
	Addrs []netip.Addr
}

// cellularIndex returns the index of the interface a socket of one IP family is bound to: the first
// one named pdp_ip* that is up and has an address of that family which isn't link-local, since
// those only work on their own link. ifaces come in the order the system lists them, by index,
// which puts pdp_ip0 first. Zero means there is none, and the socket stays unbound.
func cellularIndex(ifaces []ifaceInfo, ipv6 bool) int {
	for _, ifc := range ifaces {
		if !ifc.Up || ifc.Index <= 0 || !strings.HasPrefix(ifc.Name, cellularPrefix) {
			continue
		}
		for _, a := range ifc.Addrs {
			a = a.Unmap() // an IPv4 address that comes as ::ffff:a.b.c.d is IPv4
			// Global unicast also covers the private and carrier-grade NAT addresses a cellular
			// interface usually has. It leaves out link-local, loopback, multicast and unspecified.
			if a.Is6() == ipv6 && a.IsGlobalUnicast() {
				return ifc.Index
			}
		}
	}
	return 0
}

// cellularInterfaces lists the interfaces that cellularIndex chooses from. It leaves out every
// interface that isn't an up pdp_ip*, so it reads the addresses of few.
func cellularInterfaces() []ifaceInfo {
	all, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []ifaceInfo
	for _, ifc := range all {
		if ifc.Flags&net.FlagUp == 0 || !strings.HasPrefix(ifc.Name, cellularPrefix) {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		info := ifaceInfo{Name: ifc.Name, Index: ifc.Index, Up: true}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok {
				if ip, ok := netip.AddrFromSlice(n.IP); ok {
					info.Addrs = append(info.Addrs, ip.Unmap())
				}
			}
		}
		out = append(out, info)
	}
	return out
}

// bindCellular is the Control function of every socket the engine makes for forwarded traffic.
// net.Dialer and net.ListenConfig call it after creating the socket and before connecting or
// binding it, with network set to tcp4, tcp6, udp4 or udp6.
//
// The interface is looked up for each socket: the phone's data connection comes and goes, and a
// lookup costs next to nothing beside making a connection. With no cellular interface the socket
// stays unbound. A bind that fails ends the connection: sending it out of the interface the system
// picks instead is the very thing the binding is for.
func bindCellular(network, address string, c syscall.RawConn) error {
	ipv6 := strings.HasSuffix(network, "6")
	index := cellularIndex(cellularInterfaces(), ipv6)
	if index == 0 {
		return nil
	}
	return bindToInterface(c, ipv6, index)
}

// listenCellularUDP opens the unconnected IPv4 UDP socket of a cone, on any port.
func listenCellularUDP() (*net.UDPConn, error) {
	lc := net.ListenConfig{Control: bindCellular}
	pc, err := lc.ListenPacket(context.Background(), "udp4", ":0")
	if err != nil {
		return nil, err
	}
	conn, ok := pc.(*net.UDPConn)
	if !ok { // can't be, but a panic here would end the app
		pc.Close()
		return nil, errors.New("not a UDP socket")
	}
	return conn, nil
}
