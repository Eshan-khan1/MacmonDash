# MacmonDash — real-app checklist

Production-readiness backlog for a real macOS utility. Status is relative to this repo today.

| Tag | Meaning |
|---|---|
| **Done** | Shipped and working |
| **Partial** | Exists but should be improved |
| **Todo** | Not done yet |
| **N/A** | Not required for this app |

---

## Permissions and trust

- [x] **Done** — First-launch welcome that explains the app (`HelperSetup.showWelcomeIfNeeded`)
- [x] **Done** — Ask before installing the Fan Helper; user can decline (`ensureReady` + consent alerts)
- [x] **Done** — Clear copy for fan control vs CLEAN / purge (README + permission dialogs)
- [x] **N/A** — Accessibility / automation permissions (app does not drive other apps or capture input)
- [ ] **Todo** — Hardened Runtime + Apple notarization so Gatekeeper opens without right-click / Open Anyway
- [ ] **Todo** — Developer ID Application signing (replace ad-hoc codesign used in `Scripts/package-app.sh`)

---

## Support and feedback

- [~] **Partial** — Help → **Report an Issue** opens GitHub Issues (add issue templates with app version, macOS version, chip)
- [ ] **Todo** — Help → **Send Feedback** / feature-request path (or a dedicated Issues template)
- [~] **Partial** — About panel with name, credits (`showAbout`); keep `CFBundleShortVersionString` in sync with GitHub releases
- [~] **Partial** — README: install, Gatekeeper, permissions, uninstall helper, troubleshooting — keep in sync with each release

---

## Lifecycle and safety

- [x] **Done** — Quit restores fans to automatic; helper watchdog returns fans to auto if the app stops pinging
- [x] **Done** — **Remove Fan Helper…** from the app menu (and CLI uninstall)
- [x] **Done** — Closing the dashboard keeps the menu-bar temp/fans; **Quit** fully exits
- [ ] **Todo** — In-app update check or “What’s New” when a newer GitHub release exists
- [~] **Partial** — Graceful handling if `macmon` / metrics pipe exits (message in terminal); no crash reporter yet

---

## Product polish

- [ ] **Todo** — Preferences: °C/°F, refresh interval, other light settings
- [ ] **Todo** — Open at login (menu-bar background mode)
- [~] **Partial** — App icon, display name, bundle ID `com.local.macmondash`, copyright in Info.plist (consider a reverse-DNS ID under a real domain if distributing widely)
- [ ] **Todo** — Document sandbox stance: main app + root LaunchDaemon helper (SMC) cannot be fully App Sandbox without a redesign (XPC / blessed helper)

---

## Distribution

- [x] **Done** — GitHub Releases with versioned DMG/ZIP and stable `MacmonDash.dmg` / `.zip` names
- [x] **Done** — One-click Download badge + latest-release links on README
- [ ] **Todo** — Notarize DMG and staple ticket for clean first launch
- [x] **Done** — Minimum OS stated: macOS 14+ / Apple Silicon (README + `LSMinimumSystemVersion`)

---

## Privacy and legal

- [ ] **Todo** — Short privacy policy (even if: no accounts, no analytics, no network except optional update/issue links the user opens)
- [~] **Partial** — MIT [LICENSE](LICENSE) in repo; surface in About / README (README already links it)
- [ ] **Todo** — One-paragraph “what stays on your Mac” blurb (temps, fan RPM, power via local sensors/helper; no cloud)

---

## How to use this list

1. Prefer shipping **Todo** items that unblock trust (signing, notarization) and support (issue templates).
2. Tick boxes and flip tags when something lands; open a GitHub issue per chunk of work if helpful.
3. Feature work is out of scope of this file itself — it is the backlog, not the implementation.
