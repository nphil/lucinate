# Lucinate — Native Swift Rewrite: Autonomous Build Plan

> **Audience:** Claude Fable, executing this build autonomously (overnight, unattended).
> **Goal:** Ship a native **SwiftUI (iOS 26, Liquid Glass)** rewrite of the existing Flutter
> OpenWrt manager, with **superior UX/UI**, on branch `claude/native-swift-rewrite`, that
> **compiles green in CI** and is ready for the owner to test on-device and merge to `main`.
>
> This document is self-contained. Everything you need — the exact router API, every feature,
> the theme palettes, the navigation model, the CI gate, and the execution order — is below.
> Read it fully once, then execute Phase 0 → Phase 6 in order, committing green at each phase.

---

## 0. TL;DR / Prime Directives

1. **You cannot compile Swift in this Linux container.** Your only compile gate is a **macOS
   GitHub Actions runner** you will set up in Phase 0. **Commit and push frequently**; after each
   meaningful chunk, push and confirm CI stays green. A red CI is your top priority to fix before
   moving on. Treat "CI green" the way the Flutter side treats it (see `CLAUDE.md`).
2. **Correct-by-construction.** Since you can't run the compiler locally, write conservative,
   idiomatic Swift 6 / SwiftUI you are highly confident compiles. Prefer boring, well-known APIs.
   Keep files small and cohesive so a single mistake fails a small unit.
3. **Ship a working app at every checkpoint.** A launchable, parity-correct app beats a
   half-built ambitious one. Do Phases in order; do not start Phase N+1 until Phase N is green.
4. **Conserve tokens with subagents.** You are running unattended on a budget. Delegate
   well-scoped, independent, mechanical work to subagents (Task tool). Keep architecture,
   the networking layer, and app-shell integration in your own context. See §12.
5. **Never touch `main` or `lib/` (the Flutter app).** All new code lives under `native/` on
   `claude/native-swift-rewrite`. Do not delete or edit the Flutter sources; the owner merges later.
6. **Design bar:** Apple Music-class polish. Real Liquid Glass, wholesale theming, tasteful
   spring animations, haptics, large titles, materials, swipe actions, context menus. See §7–§9.

---

## 1. Product Brief

**Lucinate** is a mobile remote-management client for an **OpenWrt** travel router (the owner runs
the **TravelMate** and **Tailscale** plugins). It talks to the router over the **LuCI JSON-RPC /
ubus** HTTP API on the LAN or over Tailscale. Core tenets, in priority order:

1. **Responsiveness** — instant, fluid, never blocks; optimistic UI; cached-first rendering.
2. **Reliability** — resilient networking (self-signed TLS, HTTP/HTTPS auto-detect, retries,
   concurrency limits), correct state, graceful degradation on wired-only routers.
3. **Excellent UX + beautiful UI** — Apple Music-grade navigation and motion; deep theming.

The current Flutter app defines the **minimum feature floor** (§5). The rewrite must reach parity,
then **exceed** it in UX/organization and add the **new mobile-management features** in §6.
**TravelMate and Tailscale are first-class**, not buried in settings (§4).

---

## 2. Tech Stack & Project Setup (Phase 0)

- **Language:** Swift 6 (strict concurrency). **UI:** SwiftUI. **Min target:** iOS 26.0 (Liquid Glass).
- **State:** `@Observable` (Observation framework) + `@State`/`@Environment`. No third-party deps.
- **Networking:** `URLSession` (async/await). **Persistence:** Keychain (Security framework) for
  credentials/certs; `UserDefaults` for non-secret prefs (theme ids, toggles).
- **No external packages.** Everything above ships with the SDK. (Zero SPM dependencies keeps the
  CI build fast and eliminates a class of failures.)
- **Project generation:** Use **XcodeGen** (`project.yml`) so the `.xcodeproj` is generated on the
  macOS runner — you do **not** hand-write `.pbxproj`. XcodeGen is `brew install`-able on the runner.

### 2.1 Repo layout (create under `native/`)

```
native/
  project.yml                # XcodeGen spec
  Lucinate/
    App/                     # LucinateApp.swift, AppState (@Observable), RootView
    Networking/              # UbusClient, LuciSession, RPC models, TLS delegate, Keychain
    Models/                  # Router, Client, NetworkInterface, Tailscale*, Travelmate*, DashboardPreferences
    Theme/                   # Theme.swift (token struct), Themes.swift (20 palettes), ThemeManager
    DesignSystem/            # Spacing, Typography, Card, GlassBackground, Haptics, StatusDot, reusable views
    Features/
      Home/                  # HomeView + view models + cards (vitals, throughput chart, quick controls)
      Clients/               # ClientsView, ClientRow, ClientDetail
      Network/               # NetworkView (interfaces + wifi + firewall + dhcp + portforwards)
      TravelMate/            # TravelMateView + controller
      Tailscale/             # TailscaleView + controller
      Settings/              # SettingsView, ManageRouters, ThemePicker, DashboardPrefs, About
      Search/                # Global search
      ControlCenter/         # Bottom-accessory expanded quick-controls sheet
    Components/              # Charts (throughput), skeletons, error/empty states, pull-to-refresh
    Resources/               # Assets.xcassets (app icon, colors), Info.plist
  LucinateTests/             # Unit tests (RPC envelope parsing, throughput math, url parsing, theme count)
.github/workflows/ios-native-build.yml
```

### 2.2 `project.yml` (XcodeGen) — create verbatim, adjust names as needed

```yaml
name: Lucinate
options:
  bundleIdPrefix: app.cogwheel
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    IPHONEOS_DEPLOYMENT_TARGET: "26.0"
    MARKETING_VERSION: "2.0.0"
    CURRENT_PROJECT_VERSION: "1"
    DEVELOPMENT_TEAM: ""
    CODE_SIGNING_ALLOWED: "NO"        # CI builds unsigned; owner signs locally/Feather
    GENERATE_INFOPLIST_FILE: "YES"
    ENABLE_USER_SCRIPT_SANDBOXING: "YES"
targets:
  Lucinate:
    type: application
    platform: iOS
    sources: [Lucinate]
    info:
      path: Lucinate/Resources/Info.plist
      properties:
        UILaunchScreen: {}
        CFBundleDisplayName: Lucinate
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true   # LAN routers use http / self-signed https
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
  LucinateTests:
    type: bundle.unit-test
    platform: iOS
    sources: [LucinateTests]
    dependencies:
      - target: Lucinate
```

> **Bundle id:** keep the Flutter app's id **`app.cogwheel.lucimobile`** so Feather treats it as the
> same app (in-place update), OR choose a new id if the owner wants side-by-side installs. **Default
> to reusing `app.cogwheel.lucimobile`** unless told otherwise; note this decision in your final report.

### 2.3 CI workflow `.github/workflows/ios-native-build.yml`

Mirror the Flutter pipeline's philosophy (see `CLAUDE.md`), but **build-only** (no release) on the
rewrite branch. It is your compile gate.

```yaml
name: iOS Native Build
on:
  push:
    branches: [claude/native-swift-rewrite]
  workflow_dispatch: {}
concurrency:
  group: native-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    runs-on: macos-15        # or the latest macOS image with Xcode 26
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode 26
        run: sudo xcode-select -s /Applications/Xcode_26.app || xcodebuild -version
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Generate project
        working-directory: native
        run: xcodegen generate
      - name: Build
        working-directory: native
        run: |
          set -o pipefail
          xcodebuild build \
            -project Lucinate.xcodeproj \
            -scheme Lucinate \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO | xcbeautify || \
          xcodebuild build -project Lucinate.xcodeproj -scheme Lucinate \
            -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
      - name: Unit tests
        working-directory: native
        run: |
          xcodebuild test -project Lucinate.xcodeproj -scheme Lucinate \
            -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
            CODE_SIGNING_ALLOWED=NO || true   # tests non-fatal on first passes; tighten later
```

> **Runner image caveat:** the exact `runs-on` label and Xcode path for **Xcode 26 / iOS 26 SDK**
> may differ. In Phase 0, **verify the available image** (`xcodebuild -version`, list
> `/Applications/Xcode_*.app`) via the first CI run and pin the correct values. If iOS 26 SDK is not
> yet on public runners, fall back to the newest available SDK, keep the Liquid Glass code behind
> `if #available(iOS 26.0, *)` (§8.7), and lower `deploymentTarget` accordingly so it still builds —
> document this in your report so the owner can bump it on their Mac.
>
> **Token-efficient CI checks (per `CLAUDE.md`):** do **not** call `list_workflow_runs` (it dumps
> ~180k chars). Check status with a **small** `actions_list` slice or the commit's check-runs, and
> read failed job logs with `get_job_logs` (`failed_only`, `tail_lines`). When a build breaks,
> dispatch a subagent to pull the failing log tail and return the exact file:line + error, then fix.

### 2.4 App icon

Reuse the existing icon so branding is consistent. Source PNG lives at
`ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png` (1024²). Copy it into the
new `Assets.xcassets` app-icon set. (You may generate the required sizes, or use a single 1024
"any appearance" icon which Xcode 26 accepts.)

---

## 3. Networking Layer — Exact OpenWrt/LuCI API Reference

> This is the backbone. The Flutter app's behavior below is the **contract**; reproduce it exactly.
> Transport is **JSON-RPC 2.0 over HTTP POST** to the LuCI ubus bridge. There is no persistent
> socket — every call is one POST. Auth is a LuCI session cookie value reused as the ubus session id.

### 3.1 Login (form POST, **not** JSON-RPC)

- `POST {scheme}://{host[:port]}/cgi-bin/luci/` (trailing slash required)
- Header: `Content-Type: application/x-www-form-urlencoded`
- Body: `luci_username={urlenc user}&luci_password={urlenc pass}`
- Follow redirects. Accept status **200–399** (incl. **302**).
- **Extract token:** read **`Set-Cookie`** headers; find the cookie whose name contains
  **`sysauth`** (real names: `sysauth_http` / `sysauth_https`); the **value** (`cookie.split(';')[0].split('=')[1]`)
  is the **`sysauth` session token**, reused as the ubus RPC session id. There is no separate ubus login.
- **HTTP↔HTTPS auto-detect:** attempt with chosen scheme following redirects; inspect the **final
  URL scheme**. If started HTTP but ended HTTPS and a `sysauth` cookie is present → treat as HTTPS
  (persist `useHttps=true`). On a TLS verify failure during an HTTP+redirect attempt, retry over
  HTTPS. If initial HTTP attempt fails outright, retry once over HTTPS.
- **Retry:** login retries up to **3×** on transient/network errors, backoff `500ms × attempt`.
  A reached-server-but-no-cookie result = bad credentials → **do not retry**, fail fast.
- Result: `(token, actualUseHttps)`. Persist the **actual** protocol (may differ from user's choice).

### 3.2 RPC transport (ubus `call`)

- `POST {scheme}://{host[:port]}/cgi-bin/luci/admin/ubus`, `Content-Type: application/json`.
- **Request envelope:**
  ```json
  { "jsonrpc": "2.0", "id": 1, "method": "call",
    "params": [ "<sysauth>", "<object>", "<procedure>", { /* args */ } ] }
  ```
  `params[0]`=session token (empty string `""` for the unauthenticated availability probe),
  `params[1]`=object, `params[2]`=procedure, `params[3]`=args (default `{}`). `id` is always `1`.
- **Response envelope:** `{ "jsonrpc":"2.0","id":1,"result":[<status:int>, <data>],"error":null }`.
  - If `error` non-null → throw `"RPC error: {message}"`.
  - `result` is a `[status, data]` pair. **status 0 = success**; non-zero is a ubus error
    (e.g. `6` = permission denied) — treat as failure (message from `data` if it's a string).
  - If `result` is empty/non-list, normalize to `[0, result]`.
  - Non-200 HTTP → throw `"Failed to call RPC: HTTP {code}"`.
- **Concurrency gate (critical):** OpenWrt's `uhttpd` serves this CGI with a tiny process cap.
  **Cap concurrent RPCs at 3** (global async semaphore). All calls funnel through it.
- **Transient retry:** up to **3×**, backoff `300ms × attempt`, on connection/timeout/reset/closed/
  broken-pipe errors. Real HTTP/RPC errors surface immediately.
- **Timeouts:** connect **10s**, read/write **15s**.

### 3.3 TLS / self-signed certs (TOFU)

Implement a `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)` server-trust handler
that trusts a cert **only if** the user previously accepted it for `host:port`. Persist accepted
certs in Keychain as a map `{"host:port": true}` (key `accepted_certificates`). Default HTTPS port
443. On first handshake failure, surface a "Certificate Warning — Accept Risk" dialog; on accept,
store and proceed. Clear per-host on router removal; clear all on logout.

### 3.4 URL parsing (reproduce exactly)

Trim, strip trailing slashes. With scheme → use it (default port 80/443). No scheme: bare host →
HTTP:80; `host:port` → validate port 1–65535, infer **HTTPS only if port is 443 or 8443**;
`[IPv6]:port` supported (keep brackets). Validate IPv4 octets 0–255 or hostname regex.
`hostWithPort` omits the port when it's the scheme default.

### 3.5 Complete ubus surface (object → procedure → args)

| Object | Procedure | Args | Used for |
|---|---|---|---|
| `system` | `board` | `{}` | Model/hostname/kernel/release. Also availability probe with `""` session. |
| `system` | `info` | `{}` | Uptime, load, memory. |
| `system` | `reboot` | `{}` | Reboot. |
| `system` | `exec` | `{command:"<shell>"}` | e.g. `wifi reload` after radio toggle. |
| `luci-rpc` | `getNetworkDevices` | `{}` | Per-device `stats.rx_bytes/tx_bytes`. **Throughput source.** |
| `luci-rpc` | `getWirelessDevices` | `{}` | Radio→interfaces tree. Optional (wired-only may lack). |
| `luci-rpc` | `getDHCPLeases` | `{}` | `dhcp_leases[]`. Clients. |
| `network.interface` | `dump` | `{}` | `{interface:[{interface,device,l3_device,...}]}`. |
| `uci` | `get` | `{config:"<c>"}` | Read config (`wireless`, `travelmate`, `dhcp`, `firewall`, `network`). `{values:{section:{...}}}`. |
| `uci` | `set` | `{config,section,values:{k:v(strings)}}` | Set options. |
| `uci` | `add` | `{config,type,name?,values}` | Add section. |
| `uci` | `delete` | `{config,section}` | Delete section. |
| `uci` | `commit` | `{config}` | Commit staged changes (always after set/add/delete). |
| `iwinfo` | `assoclist` | `{device:"<ifname>"}` | Associated stations `{results:[{mac,...}]}`. |
| `iwinfo` | `scan` | `{device:"<radioN>"}` | Wi-Fi scan `{results:[{ssid,signal,encryption,channel,...}]}`. |
| `luci.wireguard` | `getWgInstances` | `{}` | WG peers (public_key, endpoint, latest_handshake). Custom pkg. |
| `file` | `read` | `{path:"<path>"}` | Read file (travelmate runtime json). |
| `file` | `exec` | `{command:"<bin>",params:[...]}` | Exec binary (`/etc/init.d/travelmate restart`, `/sbin/wifi reload`). |
| `tailscale` | `get_status` | `{}` | Tailscale status. Custom rpcd. |
| `tailscale` | `get_settings` | `{}` | Tailscale settings. |
| `tailscale` | `set_settings` | `{form_data:<map>}` | Save settings (send **full** form_data). |

**Composed operations:**
- Toggle radio: `uci set wireless {section} {disabled:"0"/"1"}` → `commit wireless` → `system exec {command:"wifi reload"}`.
- TravelMate enable: `uci set travelmate global {trm_enabled}` → `commit travelmate` → `file exec /etc/init.d/travelmate restart`.
- Add uplink: `uci add wireless wifi-iface` (`mode:"sta"`, `network:"travel_wan"`, `ssid`, `encryption`, `disabled:"0"`, `key` if encrypted) + `uci add travelmate uplink` (`enabled:"1"`, `device`, `ssid`) → commit both → travelmate restart.
- Remove uplink: find matching sta `wifi-iface` from `uci get wireless` → `uci delete` it + `uci delete travelmate {sectionId}` → commit both → restart.
- Channel/band: `uci set wireless {section} {channel|disabled}` → `commit wireless` → `file exec /sbin/wifi reload`.

### 3.6 Throughput polling

- `Timer`/async loop every **2s** → one `luci-rpc.getNetworkDevices` call. Start after dashboard
  load; stop on logout / router switch / reboot.
- Bytes: `dev.stats.rx_bytes` (fallback `dev.rx_bytes`); same for tx.
- Rate: keep last bytes + timestamp per device; `rate = max(0,(cur-last)/elapsedSec)`; require
  `elapsed >= 0.1s`; clamp each rate to ≤ `1000*1024*1024` B/s; ring buffer **50** points; first
  sample emits `0.0`. **Aggregate** = sum over non-loopback devices (device names from
  `network.interface dump`, each interface's `device`+`l3_device`, excluding `lo`/`loopback`).
- Per-interface option: map interface id → device (wireless prefs formatted `"SSID (device)"` →
  regex `\(([^)]+)\)`; wired = plain device) and mirror that series.

### 3.7 Keychain / persistence schema

- Credentials: `ipAddress`, `username`, `password`, `useHttps` ("true"/"false"). **Token not stored**
  — re-login on resume.
- `routers`: JSON array of `{id,ipAddress,username,password,useHttps,lastKnownHostname?}`; `id = "ip-username"`.
- `selectedRouterId`. `accepted_certificates`: `{"host:port":true}`.
- Non-secret in `UserDefaults`: `lightThemeId`, `darkThemeId`, `themeMode`, `clients_aggregate_all`,
  `dashboard_preferences:<routerId>`.

### 3.8 Reboot flow

On reboot: lock nav (see §4), show persistent "Rebooting… Connection will be interrupted." toast,
call `system reboot`. Then poll availability: wait ~30s, ping `/`, `/cgi-bin/luci/`,
`/cgi-bin/luci/admin` with exponential backoff (3→5→8→12→18→20s, ≤40 attempts ≈5 min); on success
auto-relogin and toast "Router is back online, reconnecting…"; on timeout notify the same way.

---

## 4. Navigation Model (Apple Music-grade)

**Use the iOS 26 `TabView` with `Tab(...)` items** (automatic Liquid Glass tab bar). Model the
information architecture on **Apple Music**: a small set of clear tabs, large navigation titles,
a persistent bottom accessory (the "Now Playing" analog), a global search, and an account/settings
button in the top-right.

### 4.1 Tabs (5) — TravelMate & Tailscale are first-class

| Tab | System image | Contents |
|---|---|---|
| **Home** | `house` / `gauge` | Vitals, throughput hero chart, **Quick Controls** (radios, TravelMate, Tailscale exit node), release/version, at-a-glance status. |
| **Clients** | `person.2` | DHCP + wireless clients, search, all-routers vs selected toggle, detail, **actions** (§6). |
| **Network** | `network` | Interfaces (wired+wireless), Wi-Fi AP management, DHCP/static leases, port forwards, firewall toggles (§5–§6). |
| **TravelMate** | `airplane` / `wifi.router` | Full TravelMate (uplinks, scan/add, forget, broadcast band/channel, status, captive). |
| **Tailscale** | `lock.shield` | Full Tailscale (status, exit node, routes, DNS, peers). |

- Add a **Search** experience via `.searchable` on Home/Clients/Network (global search over clients,
  interfaces, settings). Optionally a dedicated `Tab(role: .search)` if it reads cleaner.
- **Router switcher** = tap the large title / a toolbar menu (like Apple Music's library switcher):
  lists saved routers with live hostname + active check; selecting switches router.
- **Settings** = a top-right toolbar **account/gear button** opening a Settings sheet
  (Manage Routers, Appearance/Themes, Dashboard customization, About, Logout). Do **not** make
  Settings a tab — keep the five above.
- **Reboot lockout:** while rebooting, disable Home/Clients/Network/TravelMate/Tailscale
  interactions except the Settings sheet path; show the rebooting toast/state.
- `.tabBarMinimizeBehavior(.onScrollDown)` so the glass bar collapses on scroll (Apple Music feel).

### 4.2 The persistent **Connection Accessory** (the "Now Playing" analog)

Use `.tabViewBottomAccessory { ConnectionPill() }`. It floats above the tab bar on every screen:

- **Collapsed:** router hostname + colored status dot + live **↓ / ↑** throughput (compact).
- **Tap → expand** into a **Control Center** sheet: quick toggles for each Wi-Fi radio, TravelMate
  on/off + active uplink, Tailscale connect/exit-node, and a Reboot action. This puts the two
  must-have plugins one tap away from anywhere — satisfying "not hidden in settings."
- Read `@Environment(\.tabViewBottomAccessoryPlacement)` to adapt collapsed/expanded layout.

---

## 5. Feature-Parity Floor (must match the Flutter app)

Reproduce **all** of the following. Copy strings/labels verbatim where quoted; dialogs and
destructive confirmations must be preserved. (Full behavioral detail is authoritative here.)

### 5.1 Launch / Auth
- Splash (branded, ~2s) → reviewer-mode check → auto-login from saved credentials → app, else Login.
- Login form: **Router Address** (helper `"e.g. 192.168.1.1, router.local:8080, https://192.168.1.1"`,
  validated via §3.4), **Username** (default `root`), **Password** (show/hide). Connect button with
  spinner; error banner from state; "Need help?" → GitHub issues; version footer.
- **Reviewer Mode** easter egg: 5s long-press on brand → dialog requiring typing `REVIEWER` →
  bypasses auth with **mock data**. Preserve this (bundle mock JSON; a `MockUbusClient`).

### 5.2 Home / Dashboard (parity)
- Device Info (model + version with a colored **release-channel badge**: SNAPSHOT/BETA/RC/TESTING/STABLE).
- **Realtime Throughput** hero: ↓ (download) + ↑ (upload) formatted bps/Kbps/Mbps (bytes×8), plus a
  **line chart** with two gradient-filled curved series (RX + TX), touch tooltips, animated draw.
- System Vitals: CPU load (`load[0]/65536×100`), Memory (used=total−free−buffered, %), Uptime (`Xd Yh Zm`).
- Wireless cards per SSID (signal dBm, channel) — tap → Network tab scrolled to that device.
- Interface status cards (UP/DOWN pill, proto-based icon) — tap: `tailscale`→Tailscale, `travel_wan`
  →TravelMate, else Network tab scrolled to it. Respect per-router visibility prefs (§5.7).

### 5.3 Clients (parity)
- All-routers vs Selected toggle (persisted, default **All**). Search across hostname/IP/MAC/vendor/dnsName.
- Rows: presence dot, hostname, IP (+`+N` IPv6), vendor, connection-type chip (Wi-Fi/Wired/Unknown).
- Expand → IP / IPv6 / MAC / Vendor / DNS Name / **Lease Time Remaining** (red if expired). IP/IPv6/MAC
  **tap-to-copy** with snackbar. Build clients by merging DHCP leases + wireless assoc MACs, dedupe by
  MAC, sort wireless→wired→unknown then hostname. Aggregated mode logs into every saved router.

### 5.4 Network / Interfaces (parity)
- Sections **Wired** then **Wireless**. Expandable cards; DOWN interfaces grayscale + "OFF" chip.
- Wired detail: Device, Uptime, IP, IPv6, Gateway (ignore 0.0.0.0), DNS (copyable); WireGuard peers
  section (truncated pubkey `8…8`, last handshake relative, endpoint); footer Received/Transmitted bytes.
- Wireless detail: Device, Mode, Channel, Signal (dBm), Network; UCI-disabled ones show "MODE • Disabled".
- Auto-scroll+expand to a target interface when navigated from Home.

### 5.5 TravelMate (parity — already refined in Flutter; match it)
- Master **TravelMate** switch (`trm_enabled`). Captive-portal banner with "Open" → `http://neverssl.com`.
- Status card (connected state, active SSID, uplink subnet).
- **Broadcast** section (router's own AP): band SegmentedButton **2.4 / 5 / Both** (refuse to disable
  all radios; confirm "devices will briefly disconnect"); per-radio **channel** tiles (Auto or Ch N;
  **locked** when that radio is the active hotel uplink); channel picker with **Scan** + least-congested
  suggestions (2.4 favors 1/6/11; 5 favors emptiest of 36/40/44/48/149/153/157/161).
- **Saved networks:** list with active badge; **swipe-to-forget** (confirm) → removes sta iface +
  travelmate uplink. **Add network** (FAB): scan (both radios parallel, hide <−80 dBm & hidden SSIDs,
  strongest first), password prompt for encrypted, `addUplink`.

### 5.6 Tailscale (parity)
- Status card: state (Connected/Needs Login/Disconnected), Tailnet IP, Tailnet, Peers online, Exit node.
- **Routing:** Exit Node picker (None + online candidates), Accept Routes switch, Advertise Exit Node switch.
- **DNS & Security:** MagicDNS/Accept-DNS switch (danger confirm: breaks package updates), Shields Up
  switch (danger confirm: blocks SSH/this app over Tailscale). **Peers** list with exit-node badges.
- Writes send the **full** `form_data` (every flag '1'/'0') so unspecified flags aren't cleared; setting
  an exit node forces `advertise_exit_node='0'`.

### 5.7 Settings & multi-router (parity)
- Reboot (confirm + lockout + recovery polling). Manage Routers (add/edit/remove; `id=ip-username`;
  duplicate check; active chip; delete confirm; clears that host's certs). About dialog (version, repo link).
- Logout (confirm; clears certs; back to Login). App Customization: **Theme Mode** (System/Light/Dark),
  **Light Palette** + **Dark Palette** pickers, **Customize Dashboard** (per-router visibility + throughput
  interface; empty set = "show all"; auto-save debounced). Reviewer-mode exit.
- Persisted settings only (no polling-interval/units/language settings). Keep it that lean unless §6 adds.

### 5.8 Models (field reference — implement as `Codable`/`Sendable` structs)
- **Router**: `id`(=`ip-username`), `ipAddress`, `username`, `password`, `useHttps`, `lastKnownHostname?`.
- **Client**: `ipAddress`("N/A"), `macAddress`, `hostname`("Unknown"), `hostId?`, `leaseTime?`(s remaining),
  `vendor?`, `dnsName?`, `clientId?`, `activeTime?`, `expiresAt?`(epoch s), `connectionType`{wired,wireless,unknown},
  `ipv6Addresses?`. Computed lease/active/expiry formatting. Factories `fromLease` (heuristic conn-type from
  signal/port/ifname/hostname/OUI) + `fromWirelessStation`.
- **NetworkInterface**: `name`, `isUp`, `protocol`, `uptime`, `device`(fallback `l3_device`), `ipAddress?`,
  `netmask?`, `gateway?`(ignore 0.0.0.0), `dnsServers[]`, `stats`(rx/tx bytes…), `ipv6Addresses?`.
- **TailscalePeer/Status/Settings**, **TravelmateStatus/Uplink/WifiScanResult/BroadcastRadio**,
  **DashboardPreferences** — full fields in the parity detail above; `bandLabelFor(2/5/6)`→"2.4/5/6 GHz".

---

## 6. New Features (add after parity — mobile-management gaps, prioritized)

Do these in priority tiers. **Tier A first** (highest value / most-used on mobile). Anything you don't
reach is fine — leave a clear TODO and note it in your report. Each new mutation follows the same
`uci set/add/delete → commit → reload/restart` pattern (§3.5) and must confirm destructive actions.

**Tier A (do these):**
1. **Control Center quick toggles** (the bottom-accessory sheet, §4.2): per-radio Wi-Fi on/off,
   TravelMate on/off, Tailscale exit-node quick pick, Reboot. This is the single biggest UX win.
2. **Wi-Fi AP editing** (`config: wireless`): per-SSID enable/disable, edit **SSID**, **password**
   (`key`), **channel**, **band/width**, **hidden** toggle. (Currently only radio toggle exists.)
3. **DHCP static leases / reservations** (`config: dhcp`, `host` sections): list, add, edit, delete a
   MAC↔IP reservation (+ optional hostname). Extremely useful on the go; pairs with Clients ("Reserve IP").
4. **Client actions** from a client's detail / context menu: **Copy** fields (parity), **Reserve IP**
   (creates a `dhcp host`), **Wake-on-LAN** (`system exec` `etherwake`/`/usr/bin/etherwake -b <mac>` if
   present), and **Block/Unblock** (a firewall rule by MAC). Gate WoL/Block on tool availability; degrade gracefully.

**Tier B (do if time remains):**
5. **Port forwards** (`config: firewall`, `redirect` sections): list, toggle enable, add/edit/delete a
   simple port forward (name, proto, ext port, internal IP:port).
6. **Firewall rule toggles** (`config: firewall`, `rule`): read-only list + enable/disable toggle.
7. **System log viewer**: `file exec {command:"logread", params:["-l","200"]}` (or read `/var/log`),
   monospaced, pull-to-refresh, search. Kernel log via `dmesg` similarly.
8. **Ping / connectivity diagnostic**: `system exec {command:"ping -c 4 <host>"}`, show output; a quick
   "Internet OK?" check on Home.

**Tier C (nice-to-have; only if everything above is green):**
9. **Throughput Live Activity / Home-Screen widget** (WidgetKit) showing live ↓/↑ — the Apple Music
   "now playing on lock screen" analog. Ambitious; keep isolated so it can't break the app build.
10. **Per-client bandwidth** (if `luci-rpc`/`nlbwmon` present) and **installed-package/update check**
    (`opkg` via exec, read-only).

> **Scope discipline:** parity (Phase 3) and Tier A (Phase 4) are the target for "a working app to wake
> up to." Tiers B/C are bonus. Never let a bonus feature jeopardize a green build.

---

## 7. Design Principles (Apple Music as the yardstick)

- **Large navigation titles** that collapse on scroll; grouped/inset lists; generous whitespace on a
  4/8pt spacing grid (xs4 sm8 md16 lg24 xl32 xxl48).
- **Materials & depth:** Liquid Glass **only on the navigation layer** (tab bar, toolbars, the bottom
  accessory, floating controls, sheets) — never on content lists/cards (§8). Content uses solid
  theme surfaces with soft shadows and rounded corners (card radius 16–20, continuous corners).
- **Motion:** tasteful springs (`.snappy`/`.bouncy`), matched-geometry transitions, animated number
  changes on the throughput readout, 800ms chart draw, skeleton shimmer on first load. Respect
  **Reduce Motion**. No gratuitous continuous animation on glass.
- **Haptics everywhere** the Flutter app stubbed them: pull-to-refresh (`.impact(.medium)`), toggles
  (`.selection`), destructive confirm (`.warning`/`.error`), success (`.success`). Use
  `UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator` or SwiftUI `.sensoryFeedback`.
- **Gestures:** pull-to-refresh, **swipe actions** on rows (forget uplink, delete router, reserve/block
  client), **context menus** (long-press) for secondary actions, tap-to-copy.
- **Content-first states:** cached data renders instantly; skeletons on true first load; friendly
  empty/error states with a retry affordance (reproduce the Flutter copy).
- **Accessibility:** Dynamic Type, VoiceOver labels, ≥4.5:1 contrast, honor Reduce Transparency (glass
  auto-frosts). Let the system handle glass accessibility — don't override.
- **Adaptivity:** support portrait + landscape (Home has a distinct landscape layout in Flutter — a
  scrollable variant; you may simply make Home scroll gracefully in both).

---

## 8. Liquid Glass Implementation Guide (iOS 26 SwiftUI)

**Golden rule:** glass is for the **navigation layer that floats above content**, never for content
(lists, tables, media, cards). Apply `.glassEffect()` **last** in the modifier chain. Don't stack
glass-on-glass — group with `GlassEffectContainer`.

### 8.1 Core API
```swift
// Floating control / pill
someView.padding().glassEffect()                    // .regular, capsule by default
someView.glassEffect(.regular, in: .rect(cornerRadius: 20))
someView.glassEffect(.regular.tint(.accentColor).interactive())  // CTA only; interactive = GPU cost
```
`Glass`: `.regular` (default), `.clear` (over media), `.identity` (disable). `.tint(_:)` for
**semantic** meaning only (primary action/state) — not decoration. `.interactive()` adds
press-scale/shimmer; reserve for hero interactions.

### 8.2 Grouping & morphing
```swift
GlassEffectContainer(spacing: 20) {
    ForEach(controls) { c in c.view.glassEffect() }   // shared sampling region; enables morph
}
// Morph between states:
@Namespace var ns
view.glassEffect().glassEffectID("id", in: ns)        // inside a GlassEffectContainer, animate state
```

### 8.3 Tab bar / toolbars (automatic glass)
```swift
TabView {
  Tab("Home", systemImage: "house") { HomeView() }
  Tab("Clients", systemImage: "person.2") { ClientsView() }
  // ...
}
.tabBarMinimizeBehavior(.onScrollDown)
.tabViewBottomAccessory { ConnectionPill() }          // persistent accessory (§4.2)
```
Toolbars get glass automatically; use `ToolbarSpacer(.fixed, spacing:)`/`.flexible`,
`.buttonStyle(.glass)` / `.glassProminent` (primary), `.sharedBackgroundVisibility(.hidden)` to opt a
toolbar item out of the shared glass background.

### 8.4 Buttons
`.buttonStyle(.glass)` (secondary), `.buttonStyle(.glassProminent).tint(theme.accent)` (primary).
`.controlSize(.large)`, `.buttonBorderShape(.capsule)`. For circular prominent glass buttons, add
`.clipShape(Circle())` to fix rendering artifacts.

### 8.5 Sheets & search
Sheets get an inset glass background automatically; use `.presentationDetents([.medium,.large])`.
Search: `.searchable(text:)` (+ `.searchToolbarBehavior(.minimized)`), or `Tab(role: .search)`.
For form sheets, `.scrollContentBackground(.hidden)` so the glass shows through.

### 8.6 Accessibility (free)
Reduced Transparency → auto-frost; Increased Contrast → borders; Reduce Motion → calmer. Read
`@Environment(\.accessibilityReduceTransparency)` only if you must conditionally use `.identity`.

### 8.7 Backward-compat shim (use if runner SDK < iOS 26)
```swift
@ViewBuilder func glassy(in shape: some Shape = Capsule(), interactive: Bool = false) -> some View {
  if #available(iOS 26.0, *) {
    glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
  } else {
    background(shape.fill(.ultraThinMaterial)
      .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1)))
  }
}
```
Wrap **all** glass usage so the app still builds/runs if CI only has an older SDK; the owner gets the
full effect on iOS 26 hardware. Prefer real `.glassEffect` when `#available`.

---

## 9. Theming Engine (10 dark + 10 light, real palettes, wholesale reskin)

**Requirement:** themes must change the app **wholesale** — background, surfaces, elevated surfaces,
text, separators, accents, semantic colors, **and chart colors** — not just an accent tint. The
Flutter app's weakness was seed-only Material generation; **you hand-author true tokens** below.

### 9.1 Token struct (drive the entire UI off this)
```swift
struct Theme: Identifiable, Sendable, Equatable {
  let id: String
  let name: String
  let isDark: Bool
  // Surfaces
  let background: Color        // window / root
  let surface: Color           // cards, grouped rows
  let elevated: Color          // raised cards, sheets, menus
  // Text
  let textPrimary: Color
  let textSecondary: Color
  let separator: Color
  // Accents
  let accent: Color            // primary tint (buttons, selection, links)
  let accent2: Color           // secondary accent
  // Semantic
  let success: Color           // also throughput RX (download)
  let warning: Color
  let error: Color
  let info: Color              // also throughput TX (upload)
}
```
- Inject via `@Environment`. Build a SwiftUI `.preferredColorScheme` per `isDark`. Map onto system
  where helpful (`.tint(theme.accent)`), but drive backgrounds/surfaces/text explicitly so **every**
  screen recolors. **Chart RX = `success`, TX = `info`** (fixes the Flutter hardcoded-green/blue bug).
- Persist `lightThemeId` / `darkThemeId` / `themeMode` (System/Light/Dark). Default light **Tokyo Day**,
  dark **Catppuccin Mocha** (match Flutter defaults). Picker = grid of live swatch previews (show
  background + surface + 3 accent dots + name; ring/check the selected).
- Hex → Color helper: `Color(hex: "RRGGBB")`.

### 9.2 The 10 DARK themes (hand-authored hex tokens)

| id | name | background | surface | elevated | textPrimary | textSecondary | separator | accent | accent2 | success(RX) | warning | error | info(TX) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| tokyo-night | Tokyo Night | 1a1b26 | 24283b | 292e42 | c0caf5 | 565f89 | 2f3549 | 7aa2f7 | bb9af7 | 9ece6a | e0af68 | f7768e | 7dcfff |
| catppuccin-mocha | Catppuccin Mocha | 1e1e2e | 313244 | 45475a | cdd6f4 | a6adc8 | 45475a | 89b4fa | cba6f7 | a6e3a1 | fab387 | f38ba8 | 89dceb |
| dracula | Dracula | 282a36 | 343746 | 44475a | f8f8f2 | 6272a4 | 44475a | bd93f9 | ff79c6 | 50fa7b | ffb86c | ff5555 | 8be9fd |
| nord | Nord | 2e3440 | 3b4252 | 434c5e | eceff4 | 8f9ab0 | 434c5e | 88c0d0 | 81a1c1 | a3be8c | ebcb8b | bf616a | 5e81ac |
| gruvbox-dark | Gruvbox Dark | 282828 | 3c3836 | 504945 | ebdbb2 | a89984 | 3c3836 | fe8019 | 8ec07c | b8bb26 | fabd2f | fb4934 | 83a598 |
| rose-pine | Rosé Pine | 191724 | 1f1d2e | 26233a | e0def4 | 908caa | 26233a | c4a7e7 | ebbcba | 9ccfd8 | f6c177 | eb6f92 | 31748f |
| one-dark | One Dark | 282c34 | 2c313a | 3b4048 | abb2bf | 828997 | 3b4048 | 61afef | c678dd | 98c379 | e5c07b | e06c75 | 56b6c2 |
| monokai-pro | Monokai Pro | 2d2a2e | 363438 | 403e41 | fcfcfa | 939293 | 403e41 | 78dce8 | ab9df2 | a9dc76 | ffd866 | ff6188 | fc9867 |
| solarized-dark | Solarized Dark | 002b36 | 073642 | 0d4a58 | 93a1a1 | 657b83 | 0d4a58 | 268bd2 | 6c71c4 | 859900 | b58900 | dc322f | 2aa198 |
| nocturne | Nocturne | 0b1120 | 0f172a | 1e293b | e2e8f0 | 94a3b8 | 1e293b | 22d3ee | 818cf8 | 34d399 | fbbf24 | fb7185 | 38bdf8 |

> That is 9 rows for compactness in this doc; **add a 10th dark theme** — **Ayu Dark**:
> bg `0b0e14`, surface `11151c`, elevated `1c212b`, textPrimary `bfbdb6`, textSecondary `565b66`,
> separator `1c212b`, accent `ffb454` (orange), accent2 `59c2ff`, success `7fd962`, warning `f29e74`,
> error `f26d78`, info `73b8ff`.

### 9.3 The 10 LIGHT themes (hand-authored hex tokens)

| id | name | background | surface | elevated | textPrimary | textSecondary | separator | accent | accent2 | success(RX) | warning | error | info(TX) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| catppuccin-latte | Catppuccin Latte | eff1f5 | e6e9ef | dce0e8 | 4c4f69 | 6c6f85 | ccd0da | 1e66f5 | 8839ef | 40a02b | fe640b | d20f39 | 209fb5 |
| rose-pine-dawn | Rosé Pine Dawn | faf4ed | fffaf3 | f2e9e1 | 575279 | 797593 | dfdad9 | 907aa9 | d7827e | 56949f | ea9d34 | b4637a | 286983 |
| tokyo-day | Tokyo Day | e1e2e7 | d5d6db | c8cad3 | 3760bf | 6172b0 | c4c8da | 2e7de9 | 9854f1 | 587539 | 8c6c3e | f52a65 | 007197 |
| nord-light | Nord Light | eceff4 | e5e9f0 | d8dee9 | 2e3440 | 4c566a | d8dee9 | 5e81ac | 81a1c1 | a3be8c | ebcb8b | bf616a | 88c0d0 |
| solarized-light | Solarized Light | fdf6e3 | eee8d5 | e4ddc8 | 586e75 | 657b83 | ded8c4 | 268bd2 | 6c71c4 | 859900 | b58900 | dc322f | 2aa198 |
| gruvbox-light | Gruvbox Light | fbf1c7 | ebdbb2 | d5c4a1 | 3c3836 | 7c6f64 | d5c4a1 | d65d0e | 427b58 | 79740e | b57614 | cc241d | 076678 |
| one-light | One Light | fafafa | eaeaeb | e5e5e6 | 383a42 | 696c77 | dcdcdd | 4078f2 | a626a4 | 50a14f | c18401 | e45649 | 0184bc |
| github-light | GitHub Light | ffffff | f6f8fa | eaeef2 | 1f2328 | 656d76 | d0d7de | 0969da | 8250df | 1a7f37 | bc4c00 | cf222e | 0550ae |
| everforest-light | Everforest Light | fdf6e3 | f4f0d9 | efebd4 | 5c6a72 | 829181 | e0dcc7 | 8da101 | 3a94c5 | 35a77c | dfa000 | f85552 | 3a94c5 |
| ios-sky | iOS Sky | f2f2f7 | ffffff | ffffff | 1c1c1e | 8e8e93 | c6c6c8 | 007aff | 5856d6 | 34c759 | ff9500 | ff3b30 | 30b0c7 |

- All hex are 6-digit RRGGBB. These reproduce each palette's **signature backgrounds/surfaces**, so
  switching themes visibly transforms the whole app (the goal). Keep RX=`success`, TX=`info`.
- Add a **unit test** asserting `Themes.dark.count == 10 && Themes.light.count == 10` and that all ids
  are unique — cheap guard that the catalog stays complete.

---

## 10. Reliability & Edge Cases (don't regress these)

- Wired-only routers: `getWirelessDevices` / `uci get wireless` may fail — **degrade gracefully**,
  don't crash, hide wireless sections.
- Custom rpcd objects (`tailscale`, `luci.wireguard`) may be absent (permission/ubus error) → show the
  "not available/installed" empty state, never a crash.
- The 3-concurrent RPC cap + transient retry are **load-bearing** for reliability on `uhttpd` — keep them.
- Optimistic UI for toggles/forget, but reconcile with a reload; on failure, revert + error toast.
- Router switch cancels the throughput loop and clears per-router caches; restart cleanly.
- All destructive actions confirm (reproduce Flutter dialog copy). Reboot lockout must hold.

---

## 11. Build Order (Phases — commit green after each)

Push after each phase; keep CI green. If CI breaks, fix before continuing (subagent-triage the log).

- **Phase 0 — Scaffold & CI.** `native/` tree, `project.yml`, minimal `LucinateApp` + placeholder
  `RootView` ("Hello"), Info.plist, app icon, the CI workflow. **Push. Confirm the runner builds an
  empty app green.** Pin the correct `runs-on`/Xcode/SDK; if iOS 26 SDK absent, apply the §8.7 shim
  and lower the deployment target. **Do not proceed until green.**
- **Phase 1 — Networking + Models + Theme foundation.** `UbusClient` (login, RPC envelope, semaphore,
  retry, TLS TOFU, timeouts), Keychain store, URL parser, all model structs, throughput engine, the
  `Theme` struct + all 20 palettes + `ThemeManager` + swatch picker, DesignSystem primitives
  (Spacing, Typography, Card, `glassy`, Haptics, StatusDot). Unit tests for RPC unwrap, URL parse,
  throughput math, theme counts. **Push, green.**
- **Phase 2 — App shell & navigation.** Splash → Login (+ reviewer mode) → 5-tab `TabView` with glass
  bar, the **Connection Accessory**, router switcher, Settings sheet, global search scaffolding.
  Wire `AppState`. **Push, green.**
- **Phase 3 — Parity features.** Home (vitals + throughput chart + wireless/interface cards), Clients,
  Network (interfaces + WG peers), TravelMate (full), Tailscale (full), Manage Routers, Themes,
  Dashboard prefs, About, reboot flow. This is the **parity floor** — the app is now usable. **Push, green.**
- **Phase 4 — Tier A new features.** Control-Center quick toggles, Wi-Fi AP editing, DHCP static
  leases, client actions (reserve/WoL/block). **Push, green.**
- **Phase 5 — Tier B (if time).** Port forwards, firewall toggles, log viewer, ping diagnostic. **Push, green.**
- **Phase 6 — Polish.** Haptics pass, animation/transition pass, empty/error/skeleton states,
  landscape, accessibility labels, Dynamic Type, VoiceOver spot-checks. Optional Tier C (Live
  Activity/widget) only if everything is green. **Push, green.**

At the end, write `native/README.md`: how to open (`cd native && xcodegen generate && open Lucinate.xcodeproj`),
what's done vs TODO per tier, the bundle-id decision, any SDK/runner caveat, and known gaps.

---

## 12. Subagent Delegation Strategy (conserve tokens — you're unattended on a budget)

**Keep in your own (main) context:** architecture decisions, the `UbusClient`/networking layer, the
app shell + navigation + `AppState`, and integration/wiring between modules. These have the most
cross-cutting context and are where mistakes are expensive.

**Delegate to subagents** (Task tool, `general-purpose`) — independent, well-specified, leaf-level work
where you can hand a precise spec and get back a complete file with little back-and-forth:

- **Theme catalog** — "Create `Theme.swift` + `Themes.swift` with these 20 palettes (paste the two
  tables from §9) and a `Color(hex:)` init. Return the full files." (Purely mechanical.)
- **Model structs** — one subagent for "all `Codable`/`Sendable` model structs from §5.8 + parity
  detail," returning complete files.
- **Individual feature Views** — once the networking API and design system exist, spin one subagent
  per screen (Clients, Network, TravelMate, Tailscale, Settings, each new feature), each given: the
  parity spec (§5/§6), the `UbusClient` method signatures, the `Theme`/DesignSystem API, and the
  Liquid Glass rules (§8). Ask for a complete, compile-ready SwiftUI file + its view model.
- **Boilerplate** — Info.plist, asset catalog JSON, the CI YAML, unit-test files.
- **CI failure triage** — when a build is red, a subagent pulls the failing `get_job_logs`
  (`failed_only`, `tail_lines`) and returns just the file:line + error message; you apply the fix.

**Rules for delegation:**
- Give each subagent enough spec to work **without** reading the Flutter code (paste the relevant
  section). Provide the exact API surface (method names/signatures) it must call so files line up.
- Require subagents to **return complete file contents** (you write them to disk) — don't have many
  agents editing the same files concurrently (merge conflicts). One file/area per agent.
- After integrating subagent output, **you** do the wiring and push; **CI is the truth** — never
  assume a subagent's Swift compiles. Batch a few files per push so a failure localizes.
- Prefer a handful of substantial delegations over many tiny ones (each dispatch has overhead).

---

## 13. Guardrails & Git

- **Branch:** all work on `claude/native-swift-rewrite` (already created off `main`). Push with
  `git push -u origin claude/native-swift-rewrite`; retry on network errors with backoff. **Do NOT
  open a PR** (the owner will review/merge). **Do not touch `main`, `lib/`, or the Flutter CI.**
- **Do not** run the Flutter iOS release pipeline; the native CI you add is build-only on this branch.
- **Secrets:** never commit credentials, tokens, team ids, or the model identifier. `DEVELOPMENT_TEAM`
  stays empty; CI builds unsigned.
- **Commits:** clear, scoped messages per phase. End each commit message with:
  ```
  Co-Authored-By: Claude Fable <noreply@anthropic.com>
  ```
  (Do not include model identifiers beyond that trailer, in code or PR/commit text.)
- **When you finish (or run low on budget):** push whatever is green, then write the final report /
  `native/README.md` with status per phase/tier, caveats (esp. the iOS 26 SDK/runner situation and
  the bundle-id choice), and exactly what the owner should test on-device. Leave the app **compiling
  green** at the last commit even if incomplete.

---

## 14. Definition of Done (what the owner wakes up to)

- ✅ `claude/native-swift-rewrite` has a `native/` SwiftUI app that **builds green** in
  `ios-native-build.yml`.
- ✅ Login → 5-tab app (Home/Clients/Network/TravelMate/Tailscale) with a Liquid Glass tab bar and the
  persistent Connection accessory.
- ✅ **Parity floor** met (§5): dashboard vitals + live throughput chart, clients, interfaces/WG,
  full TravelMate, full Tailscale, multi-router, reboot, reviewer mode.
- ✅ **20 real-palette themes** (10 dark + 10 light) that reskin the app wholesale, with a live-preview picker.
- ✅ Apple Music-grade UX: large titles, materials, springs, haptics, swipe/context menus, pull-to-refresh.
- ✅ As many **Tier A** new features as time allowed (Control Center, Wi-Fi editing, static leases, client actions).
- ✅ A `native/README.md` with open/build instructions, status, and caveats.

Build it clean. Ship it green. Good luck. 🌙
