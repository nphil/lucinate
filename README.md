# Lucinate

A native **Swift 6 / SwiftUI** OpenWrt router manager, targeting **iOS 26** with
Liquid Glass navigation. The app is the repo root. (This replaced an earlier
Flutter app, which was removed — its history remains in git and in the
`ios-v1.1.x` release tags.)

## Open & build

```bash
xcodegen generate        # brew install xcodegen go (xcodegen first builds the Go Phone Data engine)
open Lucinate.xcodeproj  # scheme: Lucinate
```

CI (`.github/workflows/ios-native-build.yml`) runs on every push to
`claude/native-swift-rewrite*` branches: GitHub's `xcode-27` runner (Xcode 27 /
iOS 27 SDK), Go set up from `PhoneDataEngine/go.mod`, the engine's Go tests,
`xcodegen generate`, simulator build, then unit tests on the first
available iPhone simulator. The deployment target stays iOS 26. That workflow is
the compile gate for this code — it was developed on a Linux container with no
Swift toolchain.

## Decisions

- **Bundle id: `app.cogwheel.lucimobile` (reused).** Feather treats the native
  build as an in-place update of the Flutter app. Change
  `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` if you want side-by-side installs.
- **Branch:** the plan named `claude/native-swift-rewrite`, but this session's
  push access is scoped to `claude/native-swift-rewrite-q5dnyg`, so everything
  lives there (the CI trigger covers both via `claude/native-swift-rewrite*`).
- **Networking = LuCI JSON-RPC bridge (parity contract).** Same transport the
  Flutter app proved out: form login to `/cgi-bin/luci/` → `sysauth` cookie →
  JSON-RPC to `/cgi-bin/luci/admin/ubus`. Kept because it works on a stock LuCI
  install with no extra packages. Native improvements: `URLSession` async/await,
  an actor-based 3-permit semaphore for uhttpd's tiny CGI process cap,
  transient-error retry with backoff, TOFU self-signed-TLS handling via a
  `URLSessionDelegate` with Keychain persistence, and cookie capture through the
  session jar (robust across redirects). A future option is the native
  `/ubus` endpoint (`uhttpd-mod-ubus` + `session.login`), which would drop the
  cookie dance — not used because it requires extra router-side setup.
- **No third-party Swift dependencies.** Foundation/SwiftUI/Charts/Security/Network/
  WebKit/CryptoKit/AppIntents/AVFoundation only. The one exception is the Phone
  Data engine, below.
- **Phone Data (TravelMate tab) shares the iPhone's cellular data over USB.**
  Personal Hotspot gives the iPhone `172.20.10.1` on a bridge interface; Lucinate
  runs a WireGuard server there (`PhoneDataEngine/`, Go: wireguard-go + gVisor,
  vendored from [Tether](https://github.com/viktor-svirsky/tether), MIT). It
  re-dials every connection from the iPhone with sockets bound to the cellular
  interface, so the carrier sees phone traffic, not hotspot traffic, and nothing
  loops when the iPhone is also on the router's Wi-Fi. Swift has no WireGuard or
  userspace TCP/IP stack, so the engine stays Go; `scripts/build-phone-data-engine.sh`
  (run by `xcodegen generate`) builds `PhoneDataEngine/build/LucinateWG.xcframework`.
  Router side (packages `kmod-usb-net-ipheth usbmuxd kmod-wireguard wireguard-tools`):
  interface `phone_usb` (DHCP on the iPhone's USB netdev, no default route, no
  peer DNS) and `phone_wg` (WireGuard, `tunlink phone_usb`, peer
  `172.20.10.1:51820`, allowed IPs `0.0.0.0/1 128.0.0.0/1`), both in the `wan`
  zone. netifd's host dependency keeps `phone_wg` down unless `phone_usb` is up,
  so unplugging falls back to the travelmate uplink with no script on the
  router. The app keeps running in the background with a silent audio loop while
  the hotspot is up (sideloaded app; App Store review would reject it). Shortcuts
  action "Use Phone Data" wakes it.
- **Phone Data over Wi-Fi rides on TravelMate's VPN hook.** The router joins the
  iPhone's hotspot as a TravelMate uplink with `vpn 1`, `vpnservice wireguard`,
  `vpniface phone_wifi`; TravelMate brings `phone_wifi` (`auto 0`, `metric 10`,
  its own router key and tunnel address, so it never fights the USB tunnel) up
  on that uplink and down on any other. TravelMate tears down every WireGuard
  interface it knows, so setup writes `trm_vpnifacelist` (never with
  `phone_wg`); `trm_proactive 1` plus moving the iPhone's STA section first in
  `wireless` (`uci order`) makes "Hotspot on" win over hotel Wi-Fi. Known limits:
  TravelMate only starts the tunnel after its own internet check and NTP sync
  through the hotspot, so a carrier that blocks hotspot traffic outright stops
  it; if the tunnel can't come up, TravelMate leaves the router on plain hotspot
  data. While the router uses the hotspot, the iPhone isn't on the router's
  Wi-Fi and Lucinate can't open the router; the phone-side status still shows.
- **Session recovery.** LuCI answers an expired session with JSON-RPC -32002
  "Access denied" for every call. The client re-logs in once (shared by
  concurrent callers) and retries; an object missing from the session-free
  `list` reply is reported as not installed instead. Only read-only calls are
  retried after a timeout, so a mutation is never sent twice.
- **Hotel sign-in runs in-app over Wi-Fi only.** travelmate reports a portal as
  `net cp '<host>'`. While iOS treats a Wi-Fi as captive it is not the default
  route, so the sign-in WKWebView goes through a loopback proxy whose upstream
  connections require Wi-Fi; a Wi-Fi-pinned probe of Apple's captive URL
  detects when sign-in is done.
- **Package updates go through LuCI's own wrapper, over cgi-io.** Settings →
  Software Updates runs `/usr/libexec/package-manager-call` via
  `/cgi-bin/cgi-exec` (what LuCI's package page uses). rpcd ACLs never grant
  `/usr/bin/apk` itself, ubus `file exec` is SIGKILLed at rpcd's 30 s timeout,
  and the wrapper drops `-` flags (so `--simulate` would really upgrade).
  Upgrades are computed by comparing `list-installed` with `list-available`
  (apk's exact version ordering, ported in `PackageCatalog.swift`) and then
  installed one package per call, which is what makes per-package live
  progress possible and keeps each call under uhttpd's 60 s CGI limit.
  Packages that can restart the web stack or the network install last; a
  final re-read of installed versions confirms every row.
- **Themes are hand-authored tokens** (not seed-generated): 10 dark + 10 light
  palettes that reskin background/surfaces/text/separators/semantic colors and
  the chart series (RX = `success`, TX = `info`).

## Status by phase

| Phase | Scope | Status |
|---|---|---|
| 0 | Scaffold, XcodeGen project, CI gate | ✅ green |
| 1 | Networking core, models, themes, design system, unit tests | ✅ green |
| 2 | App shell: splash/login/reviewer mode, 4-tab glass nav, Connection pill, hostname menu, Settings, Manage Routers, mock client | ✅ green |
| 3 | Parity: Home dashboard (vitals, live chart), Network hub (Clients + Interfaces + WireGuard), TravelMate (full), Tailscale (full), dashboard prefs, reboot flow | ✅ green |
| 4 | Tier A: Control Center quick toggles, Wi-Fi AP editor, DHCP static leases, client actions (Reserve IP / WoL / block) | ✅ green |
| 5 | Tier B: port forwards + firewall rule toggles, system/kernel log viewer, ping diagnostic | ✅ green |
| 6 | Polish pass + this README | ✅ |
| 7 | Phone Data over USB: Go engine, router setup, TravelMate card + screen, Shortcuts | ✅ green (real-router test pending) |
| 8 | Phone Data over Wi-Fi: TravelMate VPN hook, per-link keys, Wi-Fi setup sheet | ✅ green (real-router test pending) |

### Not done (Tier C / known gaps)

- Throughput Live Activity / home-screen widget (Tier C) — skipped.
- Per-client bandwidth (nlbwmon) (Tier C) — skipped. Package updates shipped
  later (apk routers only; opkg routers get an explanation instead).
- Global search across tabs (bonus in the plan) — per-list `.searchable` only.
- Landscape gets scrolling layouts rather than a bespoke Home arrangement.
- Clients come from the active router only; the earlier All Routers aggregate
  view was removed.

## What to test on-device

1. **Login** against a real router (http, https with self-signed cert → the
   Accept Risk flow, `host:port` forms). An expired router session (router
   reboot, long background) is renewed silently on the next call.
2. **Reviewer mode**: 5-second long-press on the login brand → type `REVIEWER`.
   Whole app runs on mock data.
3. **Home**: live throughput chart (2s cadence), vitals, cards jump to the
   right tab. Customize Dashboard prefs persist per router.
4. **Clients**: expand, copy fields, Reserve IP / Wake on LAN / Block internet.
   The uplink's access point must not appear as a client.
5. **TravelMate**: scan + add uplink, Saved badge + Reconnect for a network
   travelmate paused, forget (swipe), broadcast band 2.4/5/Both, channel picker
   suggestions.
6. **Hotel sign-in**: behind a portal (travelmate `net cp`) the banner appears
   and the in-app sign-in sheet opens once; it closes itself once the internet
   works.
7. **Tailscale**: exit-node switch, MagicDNS/Shields-Up confirms (danger copy),
   peers list. Full `form_data` writes — verify no flags get cleared. Behind a
   portal it reads "not connected yet", never "not installed".
8. **Reboot** from the hostname menu / Control Center: lockout overlay +
   auto-reconnect when the router returns.
9. **Themes**: all 20 palettes reskin every screen incl. chart colors;
   System/Light/Dark mode switching.
10. **Phone Data**: TravelMate → Phone Data → Install, plug the iPhone into the
    router's USB port with Personal Hotspot on, tap Trust, Finish. The router
    should then use the iPhone's data (speeds on the screen move), fall back to
    hotel Wi-Fi when unplugged, and come back when plugged in again. Check it
    keeps sharing with the screen locked (Settings → Face ID & Passcode → USB
    Accessories on) and after the "Use Phone Data" shortcut.
11. **Phone Data over Wi-Fi**: Phone Data → Wi-Fi → Set Up with Personal Hotspot
    open, pick the iPhone, enter the hotspot password, Connect. Then on hotel
    Wi-Fi turn Personal Hotspot on: within about a minute the router should move
    to the iPhone and the hero should read "Sharing over Wi-Fi"; hotspot off →
    back to hotel Wi-Fi. With the cable also plugged in, USB wins.

## Layout

```
  project.yml           XcodeGen spec (Swift 6, iOS 26, unsigned CI builds; builds the engine first)
  PhoneDataEngine/      Go WireGuard server for Phone Data (from Tether, MIT) + its tests
  scripts/              build-phone-data-engine.sh (Go → LucinateWG.xcframework)
  Icon/                 SVG icon source + generator (light/dark/tinted PNGs)
  Support/Info.plist    ATS allows LAN http; local-network usage string
  Lucinate/
    App/                LucinateApp, AppState, RootView, MainTabView, Splash, Login
    Networking/         JSONValue, RouterEndpoint, UbusClient (actor), RouterService,
                        ThroughputCalculator, KeychainStore, AsyncSemaphore, MockUbusClient
    Models/             Router, Client, NetworkInterface(+WireGuardPeer), WirelessNetwork,
                        Tailscale*, Travelmate*, DashboardPreferences
    Theme/              Theme tokens, 20 palettes, ThemeManager, environment key
    DesignSystem/       Spacing, Typography, Card, Haptics, StatusDot, Skeleton,
                        state views, glass helpers, formatters
    Features/
      Home/             Dashboard + throughput chart + dashboard prefs
      Network/          Clients, Interfaces, Wi-Fi editor, Static Leases, Firewall
      TravelMate/       Controller + screens (scan, channel picker)
      Tailscale/        Controller + screen
      PhoneData/        iPhone side (keys, engine bridge, keep-alive, Shortcuts),
                        router setup controller, TravelMate card + screen
      ControlCenter/    Connection pill accessory + quick-controls sheet
      Diagnostics/      Log viewer (logread/dmesg) + ping
      Settings/         Settings sheet, theme pickers, Manage Routers, About
  LucinateTests/        RPC envelope/URL/throughput/theme-catalog tests
```
