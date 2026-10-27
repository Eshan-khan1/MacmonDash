import AppKit
import os.log

private let log = Logger(subsystem: "com.local.macmondash", category: "Helper")

/// Why we are about to ask for the privileged helper — shapes the dialog text.
enum HelperReason {
  case welcome, fans, purge, menu
}

enum HelperOutcome {
  case ready, declined, failed, unavailable
}

/// Owns every admin-privilege interaction: explains first, asks, then installs.
/// macOS shows its own password sheet afterwards; we never see the password.
/// All methods are to be called on the main thread.
final class HelperSetup {
  static let welcomeShownKey = "HelperWelcomeShown"
  private var inFlight = false
  /// Cached once the daemon has answered with the current protocol.
  private(set) var isReady = false

  // MARK: Public entry points

  /// First launch: explain what the app does and offer to set up the helper.
  func showWelcomeIfNeeded(window: NSWindow?) {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.welcomeShownKey) else {
      refreshState()
      return
    }
    defaults.set(true, forKey: Self.welcomeShownKey)
    DispatchQueue.global(qos: .userInitiated).async {
      let state = FanPrivileged.state()
      DispatchQueue.main.async {
        if state == .ready { self.isReady = true; return }
        // Fresh Mac → full welcome; older helper from a previous version → update text.
        self.ensureReady(reason: state == .notInstalled ? .welcome : .menu, window: window) { _ in }
      }
    }
  }

  /// Makes sure the helper is installed and current, asking the user first.
  /// Completion is on the main thread.
  func ensureReady(reason: HelperReason, window: NSWindow?, completion: @escaping (HelperOutcome) -> Void) {
    if isReady { completion(.ready); return }
    guard !inFlight else { completion(.unavailable); return }
    inFlight = true
    DispatchQueue.global(qos: .userInitiated).async {
      let state = FanPrivileged.state()
      DispatchQueue.main.async {
        if state == .ready {
          self.isReady = true
          self.inFlight = false
          completion(.ready)
          return
        }
        guard self.askConsent(reason: reason, state: state, window: window) else {
          self.inFlight = false
          completion(.declined)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let ok = FanPrivileged.installOrUpdate()
          DispatchQueue.main.async {
            self.inFlight = false
            self.isReady = ok
            log.info("helper install ok=\(ok)")
            if !ok { self.showInstallFailed(window: window) }
            completion(ok ? .ready : .failed)
          }
        }
      }
    }
  }

  /// "Remove Fan Helper…" — confirm, then uninstall with one admin prompt.
  func removeHelper(window: NSWindow?, completion: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = "Remove the MacmonDash fan helper?"
    alert.informativeText = """
      Fans return to automatic control and the background helper is deleted \
      from your Mac. You can install it again any time from this menu.

      macOS will ask for an administrator password.
      """
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove Helper")
    alert.addButton(withTitle: "Cancel")
    guard run(alert, in: window) == .alertFirstButtonReturn else { completion(false); return }
    DispatchQueue.global(qos: .userInitiated).async {
      let ok = FanPrivileged.uninstall()
      DispatchQueue.main.async {
        self.isReady = false
        log.info("helper uninstall ok=\(ok)")
        completion(ok)
      }
    }
  }

  func refreshState() {
    DispatchQueue.global(qos: .utility).async {
      let ready = FanPrivileged.state() == .ready
      DispatchQueue.main.async { self.isReady = ready }
    }
  }

  // MARK: Dialogs

  private func askConsent(reason: HelperReason, state: HelperState, window: NSWindow?) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.icon = NSApp.applicationIconImage

    let updating = state == .needsUpdate
    switch reason {
    case .welcome:
      alert.messageText = "Welcome to MacmonDash"
      alert.informativeText = """
        MacmonDash shows live CPU, GPU, RAM, power and temperature for your Mac. \
        Monitoring needs no special permission.

        Two features need a small helper that runs with administrator rights:

        •  Fan control — the sliders in the CPU box set fan speed through the \
        System Management Controller (SMC).
        •  CLEAN — flushing the file cache (macOS “purge”) after stopping idle \
        background services.

        You install the helper once; macOS asks for your password. Fans always \
        go back to automatic when MacmonDash quits, and the helper itself \
        returns them to automatic if the app ever stops responding. \
        You can remove it at any time from the MacmonDash menu.
        """
      alert.addButton(withTitle: "Install Helper…")
      alert.addButton(withTitle: "Not Now")
    case .fans:
      alert.messageText = updating ? "Fan helper needs an update" : "Allow MacmonDash to control the fans?"
      alert.informativeText = updating
        ? "This version of MacmonDash includes a newer fan helper. macOS will ask for an administrator password to update it."
        : """
          Setting fan speed writes to the System Management Controller, which \
          needs administrator rights. MacmonDash installs a small helper once; \
          macOS will ask for your password.

          Fans return to automatic when the app quits, and the helper restores \
          automatic control by itself if the app stops responding.
          """
      alert.addButton(withTitle: updating ? "Update Helper…" : "Allow")
      alert.addButton(withTitle: "Cancel")
    case .purge:
      alert.messageText = updating ? "Fan helper needs an update" : "Allow MacmonDash to purge the file cache?"
      alert.informativeText = updating
        ? "This version of MacmonDash includes a newer helper. macOS will ask for an administrator password to update it."
        : """
          CLEAN stops idle background services (never your apps) and then \
          flushes the file cache with macOS “purge”, which needs administrator \
          rights. MacmonDash installs a small helper once; macOS will ask for \
          your password.

          If you skip this, CLEAN still stops background services — it just \
          won't purge the cache.
          """
      alert.addButton(withTitle: updating ? "Update Helper…" : "Allow")
      alert.addButton(withTitle: updating ? "Cancel" : "Skip")
    case .menu:
      alert.messageText = updating ? "Update the fan helper?" : "Install the fan helper?"
      alert.informativeText = """
        The helper runs with administrator rights so MacmonDash can set fan \
        speed (SMC) and purge the file cache. macOS will ask for your password.
        """
      alert.addButton(withTitle: updating ? "Update Helper…" : "Install Helper…")
      alert.addButton(withTitle: "Cancel")
    }
    // Esc always means "no" regardless of the button's wording.
    alert.buttons[1].keyEquivalent = "\u{1b}"
    return run(alert, in: window) == .alertFirstButtonReturn
  }

  private func showInstallFailed(window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "The fan helper could not be installed"
    alert.informativeText = """
      Either the password prompt was cancelled or the helper failed to start. \
      You can try again from the MacmonDash menu.

      Log: \(FanDaemon.logPath)
      """
    alert.addButton(withTitle: "OK")
    _ = run(alert, in: window)
  }

  func showHelperStatus(window: NSWindow?) {
    DispatchQueue.global(qos: .userInitiated).async {
      let state = FanPrivileged.state()
      DispatchQueue.main.async {
        self.isReady = state == .ready
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        switch state {
        case .ready:
          alert.messageText = "Fan helper is installed and running"
          alert.informativeText = "Fan control and cache purge are available.\n\nHelper: \(FanDaemon.helperPath)\nLaunchDaemon: \(FanDaemon.helperID)"
        case .needsUpdate:
          alert.messageText = "Fan helper is installed but outdated"
          alert.informativeText = "Choose “Update Fan Helper…” from the MacmonDash menu."
        case .notInstalled:
          alert.messageText = "Fan helper is not installed"
          alert.informativeText = "Monitoring works without it. Fan sliders and cache purge will offer to install it when used."
        }
        alert.addButton(withTitle: "OK")
        _ = self.run(alert, in: window)
      }
    }
  }

  @discardableResult
  private func run(_ alert: NSAlert, in window: NSWindow?) -> NSApplication.ModalResponse {
    NSApp.activate(ignoringOtherApps: true)
    // Sheets would be nicer, but the installer blocks on osascript right after;
    // a modal alert keeps the sequence simple and obvious.
    _ = window
    return alert.runModal()
  }
}
