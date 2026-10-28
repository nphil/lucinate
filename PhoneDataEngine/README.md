# Phone Data engine

The Go program behind Phone Data in Lucinate's TravelMate tab. It is a WireGuard **server** that runs
inside the app on the iPhone and shares the phone's cellular data with a travel router, so the carrier
counts it as the phone's own data instead of hotspot data.

- [wireguard-go](https://git.zx2c4.com/wireguard-go) decrypts what the router sends.
- A [gVisor](https://gvisor.dev) userspace TCP/IP stack ends the router's TCP connections and UDP flows.
- Each one is made again with the iPhone's **own sockets, bound to its cellular interface**
  (`cellular.go`). Nothing needs root or a network extension.

The Swift side is `Lucinate/Features/PhoneData/Engine/PhoneDataServer.swift`. It calls the C API in
`exports.go`: `LucinateWGStart`, `LucinateWGStop`, `LucinateWGSetPeers`, `LucinateWGStats`,
`LucinateWGFree` and `LucinateWGFreeMemory`.

## Origin

Adapted from [Tether](https://github.com/viktor-svirsky/tether) by Viktor Svirsky (MIT licence,
`LICENSE` here is Tether's, and has to stay with the code that came from it). The code comes from
Tether's `WireGuard/` directory at commit `e3ae272d5579197965b02b98364d332348081f2b` (27 Oct 2026,
"Say up front that each device needs a WireGuard client, and that travel routers work"). Tether's
tests came with it, and they still pass. Lucinate's own changes, below, are under the licence of
the rest of the repository.

## What Lucinate changed

- **Module** is `lucinate/phonedataengine`. The C API is `LucinateWG*` instead of `TetherWG*`, and
  `go.mod` names the toolchain (`toolchain go1.27.3`) so CI builds with the version the tests ran on.
- **Cellular binding** (`cellular.go`, `cellular_darwin.go`, `cellular_other.go`). Every socket made
  for forwarded traffic, the TCP dials in `server.go` and the UDP cone sockets in `udp.go`, is bound
  to the iPhone's cellular interface with `IP_BOUND_IF` (`IPV6_BOUND_IF` for IPv6). Without it, a
  phone that is joined to Wi-Fi would send the traffic that way: back through the router when it is
  the router's own Wi-Fi, or through a hotel's. The interface is the first `pdp_ip*` that is up and
  has a non-link-local address of the socket's IP family, looked up for each new socket since it can
  change. With none, the socket stays unbound. If the bind itself fails, the connection fails, rather
  than leaving by the wrong interface. `Server.dial` and `Server.listenUDP` can still be swapped, so
  the tests reach listeners on loopback. Off Apple platforms the bind does nothing, which is why the
  tests run on Linux. The WireGuard socket in `bind.go` is not bound: it faces the router.
- **Wording.** Comments and the tunnel's name talk about Lucinate and routers, not Tether and devices.
- Tether's app features (its setup screens, QR codes and so on) are Swift, and not part of this
  directory. The server logic is Tether's, untouched: several peers, and a router that sends for the
  devices behind it.

## Limits

- IPv4 sockets are only bound when a `pdp_ip*` interface has an IPv4 address. On a carrier that gives
  the phone IPv6 only, they stay unbound and take whatever route iOS picks, since iOS translates
  IPv4 on such networks itself (464XLAT).
- `pdp_ip0` is normally the data connection, and the other `pdp_ip*` interfaces are for things like
  voice. They are only chosen when `pdp_ip0` has no usable address of the family a socket needs.

## Build

`scripts/build-phone-data-engine.sh` builds `build/LucinateWG.xcframework`: a static library for the
iPhone (arm64) and the simulator (arm64 and x86_64), built for iOS 26.0 and up, with the module map
`LucinateWG` that Swift imports. It needs Go and Xcode. XcodeGen runs it before it generates the
project (`preGenCommand` in `project.yml`), and it skips the build when the Go sources and the Go
version haven't changed. CI sets Go up from `go.mod` before it runs. `build/` is not committed.

## Test

    go -C PhoneDataEngine test ./...
    go -C PhoneDataEngine test -race ./...
    go -C PhoneDataEngine test -run '^$' -fuzz FuzzReplyPackets -fuzztime 30s ./...

`go test` needs a C compiler, since the C API uses cgo.

## Third-party code in the build

wireguard-go (MIT), gVisor and google/btree (Apache 2.0), and golang.org/x/crypto, net, sys and time
(BSD 3-clause). The app's About screen credits Tether, wireguard-go and gVisor.
