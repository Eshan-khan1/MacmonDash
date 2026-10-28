import AppKit
import Foundation
import os.log

private let log = Logger(subsystem: "com.local.macmondash", category: "Update")

/// Checks GitHub Releases for a newer MacmonDash and offers a download.
/// One GET to api.github.com on launch (and from Help → Check for Updates).
enum UpdateChecker {
  static let releasesAPI = URL(string: "https://api.github.com/repos/Eshan-khan1/MacmonDash/releases/latest")!
  static let downloadURL = URL(string: "https://github.com/Eshan-khan1/MacmonDash/releases/latest/download/MacmonDash.dmg")!
  static let skipKey = "SkippedUpdateVersion"
  static let lastAutoPromptKey = "LastAutoUpdatePromptVersion"

  static var currentVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
  }

  /// Silent launch check after a short delay. Shows an alert only when an update
  /// exists, was not skipped, and was not already prompted for this version.
  static func checkOnLaunch(window: NSWindow?) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
      check(manual: false, window: window)
    }
  }

  static func check(manual: Bool, window: NSWindow?) {
    var req = URLRequest(url: releasesAPI, timeoutInterval: 12)
    req.setValue("MacmonDash/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

    URLSession.shared.dataTask(with: req) { data, response, error in
      DispatchQueue.main.async {
        if let error {
          log.debug("update check failed: \(error.localizedDescription)")
          if manual { showFailure(error.localizedDescription, window: window) }
          return
        }
        guard let data,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else {
          if manual { showFailure("Could not read the latest release from GitHub.", window: window) }
          return
        }

        let remote = normalize(tag)
        let local = normalize(currentVersion)
        guard isNewer(remote, than: local) else {
          if manual { showUpToDate(local: local, window: window) }
          return
        }

        let skipped = UserDefaults.standard.string(forKey: skipKey).map(normalize)
        if !manual, skipped == remote { return }
        if !manual,
           UserDefaults.standard.string(forKey: lastAutoPromptKey).map(normalize) == remote {
          return
        }

        let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        showAvailable(
          remote: remote, local: local, notes: notes, page: page,
          manual: manual, window: window
        )
      }
    }.resume()
  }

  // MARK: - UI

  private static func showAvailable(
    remote: String, local: String, notes: String?, page: URL?,
    manual: Bool, window: NSWindow?
  ) {
    if !manual {
      UserDefaults.standard.set(remote, forKey: lastAutoPromptKey)
    }
    let alert = NSAlert()
    alert.messageText = "MacmonDash \(remote) is available"
    var info = "You have \(local). A newer release is on GitHub."
    if let notes, !notes.isEmpty {
      let preview = notes.split(separator: "\n").prefix(6).joined(separator: "\n")
      info += "\n\n" + preview
    }
    alert.informativeText = info
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Download")
    alert.addButton(withTitle: "Later")
    if !manual {
      alert.addButton(withTitle: "Skip \(remote)")
    }
    present(alert, window: window) { response in
      switch response {
      case .alertFirstButtonReturn:
        NSWorkspace.shared.open(page ?? downloadURL)
      case .alertThirdButtonReturn where !manual:
        UserDefaults.standard.set(remote, forKey: skipKey)
      default:
        break
      }
    }
  }

  private static func showUpToDate(local: String, window: NSWindow?) {
    let alert = NSAlert()
    alert.messageText = "You’re up to date"
    alert.informativeText = "MacmonDash \(local) is the latest release on GitHub."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    present(alert, window: window, completion: nil)
  }

  private static func showFailure(_ detail: String, window: NSWindow?) {
    let alert = NSAlert()
    alert.messageText = "Couldn’t check for updates"
    alert.informativeText = detail + "\n\nYou can download the latest build from GitHub Releases."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open Releases")
    alert.addButton(withTitle: "OK")
    present(alert, window: window) { response in
      if response == .alertFirstButtonReturn {
        NSWorkspace.shared.open(AppMenu.repoURL.appendingPathComponent("releases"))
      }
    }
  }

  private static func present(_ alert: NSAlert, window: NSWindow?, completion: ((NSApplication.ModalResponse) -> Void)?) {
    if let window, window.isVisible {
      alert.beginSheetModal(for: window) { response in completion?(response) }
    } else {
      let response = alert.runModal()
      completion?(response)
    }
  }

  // MARK: - Version compare

  static func normalize(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.lowercased().hasPrefix("v") { s.removeFirst() }
    return s
  }

  /// True when `remote` is a higher dotted version than `local` (e.g. 1.0.6 > 1.0.5).
  static func isNewer(_ remote: String, than local: String) -> Bool {
    let r = parts(remote)
    let l = parts(local)
    let n = max(r.count, l.count)
    for i in 0..<n {
      let rv = i < r.count ? r[i] : 0
      let lv = i < l.count ? l[i] : 0
      if rv != lv { return rv > lv }
    }
    return false
  }

  private static func parts(_ version: String) -> [Int] {
    version.split(separator: ".").map { chunk in
      Int(chunk.filter { $0.isNumber }) ?? 0
    }
  }
}
