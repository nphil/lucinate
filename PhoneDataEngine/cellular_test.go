package main

import (
	"net/netip"
	"testing"
)

func addrList(list ...string) []netip.Addr {
	var out []netip.Addr
	for _, s := range list {
		out = append(out, netip.MustParseAddr(s))
	}
	return out
}

// An iPhone's interfaces, as the system lists them: the loopback, the cellular data connection,
// Wi-Fi, the hotspot's bridge and a tunnel.
func phoneInterfaces() []ifaceInfo {
	return []ifaceInfo{
		{Name: "lo0", Index: 1, Up: true, Addrs: addrList("127.0.0.1", "::1", "fe80::1")},
		{Name: "pdp_ip0", Index: 2, Up: true, Addrs: addrList("10.52.8.17", "fe80::8c1:23ff:fe45:6789", "2607:fb90:1a2b::17")},
		{Name: "en0", Index: 6, Up: true, Addrs: addrList("192.168.8.20", "fe80::1c2:3344:5566:7788")},
		{Name: "bridge100", Index: 15, Up: true, Addrs: addrList("172.20.10.1", "fe80::b8:cd")},
		{Name: "utun3", Index: 20, Up: true, Addrs: addrList("100.101.102.103")},
	}
}

func TestCellularIndexPicksTheCellularInterface(t *testing.T) {
	phone := phoneInterfaces()
	if got := cellularIndex(phone, false); got != 2 {
		t.Fatalf("IPv4 socket: got interface %d, want 2 (pdp_ip0)", got)
	}
	if got := cellularIndex(phone, true); got != 2 {
		t.Fatalf("IPv6 socket: got interface %d, want 2 (pdp_ip0)", got)
	}
}

func TestCellularIndexLeavesTheSocketUnboundWithoutACellularInterface(t *testing.T) {
	if got := cellularIndex(nil, false); got != 0 {
		t.Fatalf("no interfaces: got %d, want 0", got)
	}
	// A Mac, or an iPad without a SIM: no cellular interface, only Wi-Fi and the like.
	noCellular := phoneInterfaces()
	noCellular = append(noCellular[:1], noCellular[2:]...)
	for _, v6 := range []bool{false, true} {
		if got := cellularIndex(noCellular, v6); got != 0 {
			t.Fatalf("ipv6=%v: got %d without pdp_ip*, want 0", v6, got)
		}
	}
}

func TestCellularIndexOnlyTakesPdpNames(t *testing.T) {
	ifaces := []ifaceInfo{
		{Name: "xpdp_ip0", Index: 3, Up: true, Addrs: addrList("10.0.0.2")},
		{Name: "pdp", Index: 4, Up: true, Addrs: addrList("10.0.0.3")},
		{Name: "en0", Index: 5, Up: true, Addrs: addrList("10.0.0.4")},
	}
	if got := cellularIndex(ifaces, false); got != 0 {
		t.Fatalf("got %d, want 0: none of these is a pdp_ip* interface", got)
	}
	ifaces = append(ifaces, ifaceInfo{Name: "pdp_ip3", Index: 9, Up: true, Addrs: addrList("10.0.0.5")})
	if got := cellularIndex(ifaces, false); got != 9 {
		t.Fatalf("got %d, want 9 (pdp_ip3)", got)
	}
}

func TestCellularIndexSkipsAnInterfaceThatIsDown(t *testing.T) {
	ifaces := []ifaceInfo{
		{Name: "pdp_ip0", Index: 2, Up: false, Addrs: addrList("10.52.8.17")},
		{Name: "pdp_ip1", Index: 3, Up: true, Addrs: addrList("10.60.1.1")},
	}
	if got := cellularIndex(ifaces, false); got != 3 {
		t.Fatalf("got %d, want 3: pdp_ip0 is down", got)
	}
	ifaces[1].Up = false
	if got := cellularIndex(ifaces, false); got != 0 {
		t.Fatalf("got %d, want 0: both are down", got)
	}
}

func TestCellularIndexIgnoresLinkLocalAddresses(t *testing.T) {
	// An interface with only link-local addresses, which only work on their own link.
	linkLocal := []ifaceInfo{{Name: "pdp_ip0", Index: 2, Up: true, Addrs: addrList("169.254.12.34", "fe80::8c1:23ff:fe45:6789")}}
	for _, v6 := range []bool{false, true} {
		if got := cellularIndex(linkLocal, v6); got != 0 {
			t.Fatalf("ipv6=%v: got %d for an interface with only link-local addresses, want 0", v6, got)
		}
	}
}

func TestCellularIndexWantsTheFamilyOfTheSocket(t *testing.T) {
	// An IPv4 socket needs an IPv4 address on the interface, and an IPv6 socket an IPv6 one.
	v6Only := []ifaceInfo{{Name: "pdp_ip0", Index: 2, Up: true, Addrs: addrList("fe80::1", "2607:fb90:1a2b::17")}}
	if got := cellularIndex(v6Only, false); got != 0 {
		t.Fatalf("IPv4 socket on an IPv6-only interface: got %d, want 0", got)
	}
	if got := cellularIndex(v6Only, true); got != 2 {
		t.Fatalf("IPv6 socket on an IPv6-only interface: got %d, want 2", got)
	}
	v4Only := []ifaceInfo{{Name: "pdp_ip0", Index: 2, Up: true, Addrs: addrList("10.52.8.17")}}
	if got := cellularIndex(v4Only, true); got != 0 {
		t.Fatalf("IPv6 socket on an IPv4-only interface: got %d, want 0", got)
	}
	if got := cellularIndex(v4Only, false); got != 2 {
		t.Fatalf("IPv4 socket on an IPv4-only interface: got %d, want 2", got)
	}
	// The family is checked on each interface, so the first one that has it wins.
	split := []ifaceInfo{
		{Name: "pdp_ip0", Index: 2, Up: true, Addrs: addrList("2607:fb90:1a2b::17")},
		{Name: "pdp_ip1", Index: 3, Up: true, Addrs: addrList("10.60.1.1")},
	}
	if got := cellularIndex(split, false); got != 3 {
		t.Fatalf("IPv4 socket: got %d, want 3", got)
	}
	if got := cellularIndex(split, true); got != 2 {
		t.Fatalf("IPv6 socket: got %d, want 2", got)
	}
}

func TestCellularIndexTakesTheFirstInterface(t *testing.T) {
	ifaces := []ifaceInfo{
		{Name: "pdp_ip0", Index: 2, Up: true, Addrs: addrList("10.52.8.17")},
		{Name: "pdp_ip1", Index: 3, Up: true, Addrs: addrList("10.60.1.1")},
	}
	if got := cellularIndex(ifaces, false); got != 2 {
		t.Fatalf("got %d, want 2: the first pdp_ip* that qualifies", got)
	}
}

func TestCellularIndexTakesAnIPv4AddressInIPv6Form(t *testing.T) {
	// net.IP holds IPv4 addresses in 16 bytes, so one can arrive as ::ffff:a.b.c.d.
	mapped := []ifaceInfo{{Name: "pdp_ip0", Index: 2, Up: true, Addrs: addrList("::ffff:10.52.8.17")}}
	if got := cellularIndex(mapped, false); got != 2 {
		t.Fatalf("IPv4 socket: got %d, want 2", got)
	}
	if got := cellularIndex(mapped, true); got != 0 {
		t.Fatalf("IPv6 socket: got %d, want 0: the address is IPv4", got)
	}
}

func TestCellularIndexIgnoresAnInterfaceWithoutAnIndex(t *testing.T) {
	if got := cellularIndex([]ifaceInfo{{Name: "pdp_ip0", Up: true, Addrs: addrList("10.52.8.17")}}, false); got != 0 {
		t.Fatalf("got %d, want 0: index 0 means there is no interface to bind to", got)
	}
}
