# Lucinate — Native SwiftUI Rewrite

A native **Swift 6 / SwiftUI** rewrite of the Flutter OpenWrt manager, targeting
**iOS 26** with Liquid Glass navigation. Lives entirely under `native/`; the
Flutter app (`lib/`) is untouched.

## Open & build

```bash
cd native
xcodegen generate        # brew install xcodegen (project is generated, never committed)
open Lucinate.xcodeproj  # scheme: Lucinate
```

CI (`.github/workflows/ios-native-build.yml`) runs on every push to
`claude/native-swift-rewrite*` branches: `macos-26` runner (Xcode 26 / iOS 26
SDK), `xcodegen generate`, simulator build, then unit tests on the first
available iPhone simulator. That workflow is the compile gate for this code —
it was developed on a Linux container with no Swift toolchain.

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
- **No third-party dependencies.** Foundation/SwiftUI/Charts/Security only.
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

### Not done (Tier C / known gaps)

- Throughput Live Activity / home-screen widget (Tier C) — skipped.
- Per-client bandwidth (nlbwmon) and opkg update check (Tier C) — skipped.
- Global search across tabs (bonus in the plan) — per-list `.searchable` only.
- Landscape gets scrolling layouts rather than a bespoke Home arrangement.
- Client actions (WoL/block/reserve) are hidden in All-Routers aggregate mode
  by design — they act on the active router only.

## What to test on-device

1. **Login** against a real router (http, https with self-signed cert → the
   Accept Risk flow, `host:port` forms). Auto-relogin after backgrounding.
2. **Reviewer mode**: 5-second long-press on the login brand → type `REVIEWER`.
   Whole app runs on mock data.
3. **Home**: live throughput chart (2s cadence), vitals, cards jump to the
   right tab. Customize Dashboard prefs persist per router.
4. **Clients**: All Routers vs This Router toggle, expand, copy fields,
   Reserve IP / Wake on LAN / Block internet on the active router.
5. **TravelMate**: scan + add uplink, forget (swipe), broadcast band 2.4/5/Both,
   channel picker suggestions, captive-portal banner.
6. **Tailscale**: exit-node switch, MagicDNS/Shields-Up confirms (danger copy),
   peers list. Full `form_data` writes — verify no flags get cleared.
7. **Reboot** from the hostname menu / Control Center: lockout overlay +
   auto-reconnect when the router returns.
8. **Themes**: all 20 palettes reskin every screen incl. chart colors;
   System/Light/Dark mode switching.

## Layout

```
native/
  project.yml           XcodeGen spec (Swift 6, iOS 26, unsigned CI builds)
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
      ControlCenter/    Connection pill accessory + quick-controls sheet
      Diagnostics/      Log viewer (logread/dmesg) + ping
      Settings/         Settings sheet, theme pickers, Manage Routers, About
  LucinateTests/        RPC envelope/URL/throughput/theme-catalog tests
```
