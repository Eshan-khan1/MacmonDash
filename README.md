# MacmonDash

A native macOS window around [macmon](https://github.com/vladkens/macmon) — the Apple Silicon performance monitor — with the things the terminal version can't do: **fan control sliders**, temperature-colored fan icons, Temp/Power history panels, and a one-click **CLEAN** button that frees RAM without closing any of your apps.

![MacmonDash](docs/screenshot.png)

- **Live CPU / GPU / RAM / power / temperature** — the real macmon TUI, rendered in a resizable native window (SwiftTerm), pixel-aligned overlays on its grid.
- **Fan control** — two sliders set fan speed through the SMC. Fans go back to automatic when you quit, and the helper returns them to automatic on its own if the app ever stops responding.
- **Heat-aware fan icons** — green normally, yellow from 70 °C, red from 85 °C.
- **CLEAN** — stops idle hidden background services (Siri, Spotlight indexers, Photos analysis, QuickLook thumbnails, …) that launchd restarts on demand, then flushes the file cache. It never quits a visible app.
- Keyboard: `q` quit · `c` colour · `v` view · `-`/`+` sampling interval (macmon's own keys) · `⌘0` all fans automatic.

## Requirements

- Apple Silicon Mac (M1 or newer). Intel Macs are not supported — macmon itself is Apple Silicon only.
- macOS 14 Sonoma or newer.

## Install

1. Download `MacmonDash-x.y.z.dmg` (or the `.zip`) from the [latest release](https://github.com/Eshan-khan1/MacmonDash/releases/latest).
2. Drag **MacmonDash** into **Applications**.
3. **First launch:** MacmonDash is open source and not notarized by Apple (no paid developer account), so macOS blocks the first open. Either
   - right-click (Control-click) the app → **Open** → **Open**, or
   - open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
   - from Terminal: `xattr -dr com.apple.quarantine /Applications/MacmonDash.app`

   This is needed once. Everything in the bundle is built from this repository (see [Build from source](#build-from-source)).

## Permissions — what the app asks for and why

Monitoring needs nothing special. Two features need a tiny **privileged helper**, and MacmonDash asks you before installing it:

![Permission dialog](docs/permission-dialog.png)

| Feature | Why it needs admin rights |
|---|---|
| Fan sliders | Fan targets are written to the System Management Controller (`F0Tg`, `F0Md`…), which only root may do. |
| CLEAN → cache flush | `/usr/sbin/purge` is root-only. (Stopping background services does **not** need the helper; CLEAN still works without it.) |

What gets installed when you click **Allow** (macOS shows its own password dialog — the app never sees your password):

- `/usr/local/libexec/macmondash-fanhelper` — a copy of the MacmonDash binary running in daemon mode
- `/Library/LaunchDaemons/com.local.macmondash.fanhelper.plist`
- a Unix socket at `/var/run/macmondash-fan.sock`; log at `/var/log/macmondash-fanhelper.log`

The helper understands five commands (`VERSION`, `PING`, `SET <fan> <rpm>`, `AUTO <fan>`, `PURGE`) and nothing else. RPM is clamped to 0–20 000. If it hears nothing from the app for 30 s while any fan is manual, it hands the fans back to macOS.

**Remove it any time:** menu **MacmonDash → Remove Fan Helper…** (fans → auto, daemon stopped, all three files deleted). Or from Terminal:

```sh
sudo /Applications/MacmonDash.app/Contents/MacOS/MacmonDash --uninstall-fan-helper
```

> Note: the socket is readable by every local user account on the Mac, so any local process could set a fan speed. It cannot do anything else. If that matters on a shared machine, remove the helper when you're done.

## Build from source

```sh
git clone https://github.com/Eshan-khan1/MacmonDash.git
cd MacmonDash
./Scripts/package-app.sh          # builds, assembles dist/MacmonDash.app, installs to /Applications
./Scripts/make-release.sh 1.0.0   # builds .zip + .dmg into dist/ (no install)
```

Needs Xcode Command Line Tools (Swift 5.9+). The bundled `Resources/macmon` (0.7.2, TUI) and `macmon10` (0.10.0, JSON metrics for fans/temps/power) are unmodified upstream release binaries. The app icon is generated from the same bit-graphic fan the UI draws: `python3 Scripts/make-icon.py` (needs Pillow).

## How it works

```
┌───────────────────────── MacmonDash.app ──────────────────────────┐
│ SwiftTerm ── runs ──▶ macmon 0.7.2 (TUI, drawn as-is)              │
│ MetricsPipe ─ runs ─▶ macmon10 pipe  (fans, temps, power as JSON)  │
│ Overlays on the terminal grid: fans+sliders, Temp, Power, CLEAN    │
│ HelperSetup ── explains, asks, then installs/updates the helper    │
└──────────────┬────────────────────────────────────────────────────┘
               │ unix socket  (SET / AUTO / PURGE / PING / VERSION)
┌──────────────▼────────────────────────────────────────────────────┐
│ macmondash-fanhelper (LaunchDaemon, root)                          │
│ AppleSMC writes for fan mode/target · purge · 30 s watchdog → auto │
└───────────────────────────────────────────────────────────────────┘
```

## Credits

- [macmon](https://github.com/vladkens/macmon) by vladkens — MIT
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza — MIT

## License

MIT — see [LICENSE](LICENSE).
