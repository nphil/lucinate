package main

import (
	"bytes"
	"net/netip"
	"testing"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

// replyPackets turns whatever a host on the internet sends into packets for a device, so any
// payload must give valid IPv4 fragments that put the datagram back together exactly.
// `go test` runs the seeds. CI fuzzes it for 30 s: go test -run '^$' -fuzz FuzzReplyPackets
func FuzzReplyPackets(f *testing.F) {
	f.Add([]byte("hello"), uint16(53), uint16(5000), uint16(7))
	f.Add([]byte{}, uint16(0), uint16(0), uint16(0))
	f.Add(make([]byte, 3000), uint16(443), uint16(40000), uint16(0xffff))
	f.Add(make([]byte, MTU-28), uint16(1), uint16(2), uint16(3)) // exactly one full packet
	f.Fuzz(func(t *testing.T, payload []byte, srcPort, dstPort, id uint16) {
		src := netip.AddrPortFrom(netip.MustParseAddr("1.2.3.4"), srcPort)
		dst := netip.AddrPortFrom(netip.MustParseAddr("10.7.0.2"), dstPort)
		ps := replyPackets(src, dst, payload, id)
		if header.UDPMinimumSize+len(payload) > 0xffff-header.IPv4MinimumSize {
			if ps != nil {
				t.Fatal("a datagram too big for IPv4 was sent")
			}
			return
		}
		var datagram []byte
		for i, p := range ps {
			ip := header.IPv4(p)
			if len(p) > MTU || !ip.IsValid(len(p)) || !ip.IsChecksumValid() {
				t.Fatalf("fragment %d of %d is not a valid IPv4 packet of at most the MTU", i, len(ps))
			}
			if ip.ID() != id || int(ip.FragmentOffset()) != len(datagram) || ip.More() != (i < len(ps)-1) {
				t.Fatalf("fragment %d: id %d offset %d more %v", i, ip.ID(), ip.FragmentOffset(), ip.More())
			}
			datagram = append(datagram, ip.Payload()...)
		}
		u := header.UDP(datagram)
		if len(datagram) != header.UDPMinimumSize+len(payload) || !bytes.Equal(u.Payload(), payload) {
			t.Fatalf("the fragments carry %d bytes, want the %d byte payload behind a UDP header", len(datagram), len(payload))
		}
		if u.SourcePort() != srcPort || u.DestinationPort() != dstPort {
			t.Fatalf("ports %d -> %d, want %d -> %d", u.SourcePort(), u.DestinationPort(), srcPort, dstPort)
		}
		srcAddr, dstAddr := tcpip.AddrFrom4(src.Addr().As4()), tcpip.AddrFrom4(dst.Addr().As4())
		if !u.IsChecksumValid(srcAddr, dstAddr, checksum.Checksum(u.Payload(), 0)) {
			t.Fatal("the UDP checksum is wrong")
		}
	})
}
