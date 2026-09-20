# Packaging World Brief

World Brief ships as a native application on four platforms. On the desktop the application *is*
the whole system: one process holds the FastAPI server, the refresh scheduler and a native window,
so a single click on the icon starts everything and closing the window leaves the news being
collected in the background. On Android it is a client for the copy running on your own machine.

| Platform | What you get | Built by |
|---|---|---|
| macOS | `World Brief.app`, delivered in a disc image with its own background and layout | `packaging/macos/build_macos.sh` |
| Windows | a per-user installer (`WorldBrief-<v>-setup.exe`) and a portable `.zip` | `packaging/windows/build_windows.ps1` |
| Linux | `.deb`, `.AppImage` and a portable `.tar.gz` | `packaging/linux/build_linux.sh` |
| Android | `.apk` to sideload and `.aab` for Play | `packaging/android/build_android.sh` |

`packaging/build.sh` picks the right one for the machine you are on. Every platform at once is a
job for CI: push a `v*` tag and `.github/workflows/release.yml` builds all four and attaches them
to the release.

## What goes inside

`packaging/worldbrief.spec` is the PyInstaller recipe the three desktop builds share. It bundles
the backend, the frontend (with Leaflet vendored locally, so the map works with no CDN),
the sixteen interface languages, scikit-learn and the CTranslate2 translation runtime. Nothing
else is needed at runtime. Only the news itself, and any translation packages the user chooses to
install, come from the network.

`packaging/make_icons.py` draws every icon and every piece of installer artwork from one
description — the three-arc ring the web interface already uses in its header. It writes the
`.icns`, the `.ico`, the Linux hicolor PNGs, the Android launcher mipmaps, the Inno Setup wizard
bitmaps and the disc image background. Run it alone to preview a change:

```
.venv/bin/python packaging/make_icons.py
```

## Where the app keeps things

A packaged build never writes inside itself, so an app in `/Applications` or `C:\Program Files`
still works. `backend/appdirs.py` decides where state goes:

| | Data (database, briefs, models, language packs) | Settings | Logs |
|---|---|---|---|
| macOS | `~/Library/Application Support/WorldBrief` | same | `~/Library/Logs/WorldBrief` |
| Windows | `%LOCALAPPDATA%\WorldBrief` | same | `…\WorldBrief\logs` |
| Linux | `~/.local/share/worldbrief` | `~/.config/worldbrief` | `~/.local/state/worldbrief` |

Run from a checkout instead and everything stays in `data/`, exactly as it did before.

## Signing

All four builds work unsigned; the operating system simply asks the user to confirm the first
launch. To sign, set these before building — each script skips its signing step when they are absent.

| Platform | Variables |
|---|---|
| macOS | `MACOS_SIGN_IDENTITY`, and `NOTARY_PROFILE` for notarisation |
| Windows | `WINDOWS_CERT_PFX`, `WINDOWS_CERT_PASSWORD` |
| Android | `WORLDBRIEF_KEYSTORE`, `WORLDBRIEF_KEYSTORE_PASSWORD`, `WORLDBRIEF_KEY_ALIAS`, `WORLDBRIEF_KEY_PASSWORD` |

In CI the same values come from repository secrets; see the workflow.

## Cross-compiling

You cannot. PyInstaller freezes the interpreter it is run with, so each desktop package has to be
built on its own operating system, and on the oldest one you intend to support — glibc is forward
compatible, not backward, so building the Linux packages on Ubuntu 22.04 covers 24.04 too, but not
the reverse. The Android packages are the exception and build anywhere with a JDK and the SDK.
