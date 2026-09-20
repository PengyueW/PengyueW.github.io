# Continuum

**See it. Clean it. Secure it. Know your Mac.** One native, self-contained
macOS app — a full Mac control center spanning cleaning, disk visualization,
security, privacy, app management and deep hardware telemetry.

### Core divisions

| Division | From | What it does |
|---|---|---|
| **Cleaner** | CacheClean | Scans whitelisted locations (caches, logs, DerivedData, orphaned app support) for reclaimable space, previews everything, moves to Trash — never hard-deletes. Plus Spotlight reindex / DNS flush maintenance. |
| **Disk Map** | DiskScope | Interactive squarified-treemap visualization of any folder or volume. Click to zoom, double-click to reveal in Finder. Optional one-prompt **Read All Files (Admin)** scan reads even root-owned files (drawn with a red outline). |
| **Security** | MacScan | Malware / adware / spyware scanner with three tiers (standard, deep, forensic), reversible quarantine, and a blind-spot ledger. |

### Apps & privacy

| Division | Kit | What it does |
|---|---|---|
| **Uninstaller** | UninstallKit | Locates every on-disk trace of an app — bundle, hidden launch agents/daemons, application support, preference plists, caches, container & group-container data — and removes the chosen items (user-domain → Trash; system-domain → admin-prompted delete). |
| **Extensions** | ExtensionsKit | One dashboard to review/enable/disable app extensions, browser extensions, internet plug-ins, preference panes, login items, launch agents/daemons (the common slow-boot culprits) and VPN configurations. |
| **Permissions** | PermissionsKit | Aggregates which apps hold hardware access (Camera, Microphone) and sensitive data access (Full Disk Access, Accessibility, Screen Recording, folders, Contacts…), read from the TCC databases, with per-app/per-service revoke. |
| **Network Monitor** | NetGuardKit | A reverse firewall: surfaces outbound connections in real time, alerts when a new app starts talking to an external server, and blocks unauthorized hosts via a dedicated pf anchor. |
| **Shredder** | ShredKit | Multi-pass secure erase (Zero, Random, DoD 5220.22-M with verify, Schneier 7-pass) that overwrites file contents in place, then deletes them. |
| **Free Space Wipe** | FreeSpaceKit | Overwrites a volume's *free* space (Zero, Random, DoD, Schneier) so previously-deleted files can't be recovered — by filling unused blocks only, never touching live data. Keeps a safety reserve free. |

### Hardware & sensors

| Division | Kit | What it does |
|---|---|---|
| **Thermal & Fans** | HardwareKit | Every SMC temperature sensor, live fan RPM, and a custom fan curve (hottest CPU sensor → fan speed). |
| **Battery** | HardwareKit | Health %, exact charge cycles, manufacture date, pack temperature, live signed discharge/charge wattage, voltage & amperage. |
| **Power & Peripherals** | HardwareKit | USB-PD negotiation (contract V/A/W, every offered PD profile, max wattage, change log) and per-device USB bus-power draw in mA. |
| **Drive Health** | DriveHealthKit | Lifetime Terabytes Written (TBW) and the full NVMe S.M.A.R.T. log: data units read/written, power cycles, unsafe shutdowns, critical warnings, endurance estimate. |
| **Sensors** | SensorsKit | Live Ambient Light Sensor (lux, estimated Kelvin CCT, RGB spectrum), Lid Angle (0–180° + angular velocity), and SoC Accelerometer (3-axis g, tilt, magnitude). |
| **Automations** | SensorsKit | Inject user shell scripts that run when a sensor metric crosses a threshold (edge-triggered, run in background). |
| **Menu Bar Monitors** | StatsKit | Live CPU thread utilization, RAM pressure and network bandwidth as on-screen gauges and a glanceable menu-bar item — plus the **App Mode switch** (Dock & Window / Menu Bar Only / Hidden background). |

The Home page gives access to every division: the three core divisions as
feature cards (with a startup-disk overview and live status), and the rest as
a "More Tools" grid. The app uses the CacheClean icon.

> **Honest capabilities.** Several hardware/sensor sources don't exist on every
> Mac and some have no stable public API; each reader degrades gracefully and
> the UI explains when a sensor or controller is unavailable rather than faking
> a value. The network monitor has no kernel filter entitlement, so it monitors
> established connections and enforces blocks with pf — it doesn't claim
> packet-level interception.

## Build & run

```sh
./build.sh                  # → build/Continuum.app (Command Line Tools only, no Xcode)
open build/Continuum.app
cp -R build/Continuum.app /Applications/   # optional: install
./scripts/make-dmg.sh       # → dist/Continuum-<version>.dmg (release installer)
```

### Older macOS

`build.sh` takes a deployment target. Each produces its own bundle and DMG:

```sh
./build.sh 12               # → build/Continuum-macOS12.0.app   (Monterey)
./build.sh 11               # → build/Continuum-macOS11.0.app   (Big Sur)
./build.sh 10.15            # → build/Continuum-macOS10.15.app  (Catalina)
./scripts/make-dmg.sh 11    # → dist/Continuum-<version>-macOS11.0.dmg
./build.sh all               # builds all four targets in one go
./scripts/make-dmg.sh all    # packages a DMG for each of the four targets
./scripts/release.sh all     # build → notarize → package → notarize, ×4
```

All four are built from the same sources and every one is a universal
(x86_64 + arm64) binary, so an older build still runs natively on an Apple
Silicon Mac. Version differences are handled by runtime `#available` checks in
`Sources/Compat`, never by conditional compilation — which means an older build
running on a newer system uses that system's newer APIs rather than a
fallback. The macOS 10.15 build additionally carries an AppKit application
host, because SwiftUI's `App`/`Scene` lifecycle only exists from macOS 11.

`make-dmg.sh` produces the distributable disk image: a Finder window with the
app on the left, an Applications shortcut on the right, an arrow between them,
and a branded gradient background — the familiar drag-to-install experience.

Requires Swift 5.8+ to build (macOS 13 SDK / Command Line Tools 14.3). The
default target is macOS 13; see *Older macOS* above for 12, 11 and 10.15. On
machines with full Xcode,
`swift build` also works against `Package.swift`; `build.sh` is the supported
path on Command Line Tools-only machines (where SwiftPM fails with the
xcrun "PlatformPath" error).

## Architecture

Thirteen Swift modules — twelve feature kits compiled as static libraries and
one app shell — plus the small standalone `diskscope-scan` helper executable.
Separate module names are what let codebases that each define `ContentView`,
`ScanView`, `AppModel`, … coexist unmodified.

```
Sources/
├── CacheCleanKit/    the cleaner (from cacheClean/ minus @main)
├── DiskScopeKit/     the treemap (from diskView/ minus @main)
├── MacScanKit/       the security GUI (from virusScan/gui minus @main)
│   └── Engine/MacScanEngine.swift   + bundled-engine discovery (see below)
├── UninstallKit/     smart app uninstall (leftover discovery + removal)
├── ExtensionsKit/    extension / plug-in / login-item / launch-agent / VPN governance
├── PermissionsKit/   TCC permission manager (read-only DB + tccutil/deep links)
├── NetGuardKit/      reverse-firewall connection monitor + pf-anchor blocking
├── ShredKit/         multi-pass secure file shredding
├── FreeSpaceKit/     free-space wipe (fills unused blocks; never touches live data)
│   └── DiskScopeScan/ (sibling) diskscope-scan privileged-scan helper executable
├── HardwareKit/      SMC thermal & fan curves, battery, USB-PD, peripheral power
├── DriveHealthKit/   NVMe S.M.A.R.T. + Terabytes Written
├── SensorsKit/       ALS / lid angle / accelerometer + scriptable automations
├── StatsKit/         menu-bar CPU/RAM/network monitors + app-presentation switch
└── Continuum/         the shell
    ├── ContinuumApp.swift @main, menu commands (⌘O, Go ⌘1–⌘5 + tools, ⌘↑), Settings
    ├── RootView.swift    unified sidebar (Home + grouped division sections, badges)
    └── HomeView.swift    landing page: disk gauge, core-division cards, More Tools grid
```

Every kit's `Exports.swift` follows the same pattern: a `*Controller`
(ObservableObject) owns the division's internal state object for the app's
lifetime and re-publishes its changes for shell-level UI (sidebar badges, Home
status lines), and a public detail view dispatches the division's pages while
injecting that state via `environmentObject`. Everything else in each kit stays
`internal`. Division-internal navigation (e.g. the security dashboard's "go
scan" shortcuts) reaches the shell through `MacScanController.pageRequests`.

Each kit carries its own `CLAUDE.md` documenting its data sources, the
fragile/layout-sensitive bits (e.g. the NVMe and SMC IOKit struct mirrors),
and its non-negotiable safety rules. `PROGRESS.md` is the build journal.

### Safety posture across the new kits

State-changing operations use only Apple-supported mechanisms and stay
reversible or clearly gated:

- **Shredder / Uninstaller** refuse protected system paths, never follow
  symlinks, prefer the Trash, and sit behind explicit confirmation; system-
  domain removals take one admin prompt.
- **Free Space Wipe** only ever *creates new files* in its own scratch dir, so
  the kernel allocates exclusively from free blocks — live data is structurally
  untouchable. It leaves a configurable reserve free, cleans up its scratch dir
  on success/cancel/error, and is honest about SSD/APFS/snapshot limits.
- **Permissions** opens the TCC databases read-only and changes state only via
  `tccutil reset` and System Settings deep links — never by writing TCC.
- **Extensions** uses `pluginkit`, `launchctl`, `scutil` and System Events;
  it never edits another app's files, and only user-domain launch agents are
  toggleable.
- **HardwareKit** writes an SMC key allowlist (fan target/mode only), always
  clamps to the fan's min/max, and returns fans to automatic control on quit.
- **DriveHealthKit** issues no NVMe write/admin commands.
- **NetGuardKit** confines pf rules to its own anchor and applies them behind
  an admin prompt; `Unblock All` flushes the anchor.
- **Automations** scripts run with the user's privileges via `/bin/sh`; the
  editor warns and rules are edge-triggered so a held condition can't spam.

## The bundled scan engine

The security division drives the pure-Python `macscan` CLI (stdlib only). The
engine lives in `Engine/` and is copied into
`Continuum.app/Contents/Resources/macscan-engine/` at build time, so the app
needs nothing outside its own bundle. Discovery order in `MacScanEngine`:
`MACSCAN_CLI` env var → bundled copy → user-saved path → walk-up (dev
checkouts). The launcher sets `PYTHONDONTWRITEBYTECODE=1` so Python never
writes `__pycache__` inside the signed bundle.

All MacScan safety guarantees are unchanged: scans are read-only, removal is a
confirmed, reversible quarantine to `~/.macscan/quarantine/`, and the Python
side re-validates eligibility no matter what the GUI sends.

## Signing, Full Disk Access & self-containment

The app is deliberately **not sandboxed**: the cleaner needs direct access to
`~/Library/Caches` etc., and Full Disk Access only grants real visibility to
non-sandboxed processes.

**Full Disk Access is a single grant for the whole app.** Every division runs
inside the one Continuum process, and the bundled Python security engine runs
as a *child* of that process, so it inherits the same TCC grant. You grant
Full Disk Access to **Continuum** once (Settings ▸ Full Disk Access has a live
status panel and a one-click opener) and it covers everything — there is no
per-module grant. The app is otherwise self-contained: the security engine's
sources are copied into `Contents/Resources/macscan-engine/` at build time, so
nothing outside the bundle is needed except the system `/usr/bin/python3`.

**Signing & why the grant sometimes "disappears."** `build.sh` selects a
signing identity in this order:

1. `$CONTINUUM_CODESIGN_IDENTITY` if set,
2. else a **“Developer ID Application: Pengyue Wang”** certificate if installed
   (the identity used for public, notarized releases — signed with a secure
   timestamp + hardened runtime),
3. else a stable self-signed identity named **“Continuum Local Codesign”**,
4. else **ad-hoc** (`codesign --sign -`).

Ad-hoc signatures have no stable identity: every rebuild changes the app's code
hash, so macOS treats each build as a different app and **invalidates the
previous build's Full Disk Access grant** (old entries pile up in System
Settings, which looks like the app asking for access repeatedly). To grant FDA
once and have it persist across rebuilds — with a single entry covering the
whole app — create the stable identity once:

```sh
./scripts/make-signing-identity.sh    # one-time; macOS asks for your password once
./build.sh                            # now auto-signs with the stable identity
```

**Releasing (signed + notarized).** With Pengyue Wang's *Developer ID
Application* certificate installed and notary credentials exported (see
`scripts/notarize.sh` for the exact variables), one command produces the
distributable image:

```sh
./scripts/release.sh    # build → sign → notarize app → DMG → notarize DMG → staple
```

It yields a fully notarized, stapled `dist/Continuum-<version>.dmg` that opens
on any Mac with no Gatekeeper warning. Without the certificate/credentials the
same script still produces a working ad-hoc image and tells you which steps it
skipped.

## How this was built

Continuum is architected and directed by **Pengyue Wang**, with **Claude** used as an
implementation assistant.

Claude generated boilerplate, scaffolded unit tests, and accelerated the front-end
(SwiftUI) work. The engineering judgement is mine:

- **Architecture.** I designed the split into independent feature kits, the privileged-task
  and secure-store boundaries, the safety policy that governs what the cleaner is ever
  allowed to touch, and the compatibility layer that lets one code base target macOS 10.15
  through 26 from a single source tree.
- **Review.** I peer-reviewed every change that came back, and reworked or rejected what did
  not fit the design or the safety policy.
- **Debugging.** I found and fixed the inconsistencies and functional flaws — sandbox and TCC
  permission edge cases, cache-cleaning safety rules, SMART parsing on unusual drives, and
  back-deployment breakages across four SDK versions.
- **Direction.** I decided which module came next, how it should behave, and when it was done.

## License

Copyright © 2026 Pengyue Wang.

Continuum is licensed under the **Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)**
license — see [`LICENSE`](LICENSE). You may share and adapt the work for
**non-commercial** purposes, with attribution, and any derivatives must be
shared under the same license. The full text also ships inside the app at
`Continuum.app/Contents/Resources/LICENSE`.

## Data locations (shared with the standalone apps)

- Cleaner history: `~/Library/Application Support/CacheClean/history.json`
- Security quarantine/manifests/last scan: `~/.macscan/`
