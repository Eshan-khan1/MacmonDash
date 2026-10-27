import AppKit

/// Menu-bar temperature. Click opens fan controls; right-click opens dashboard / quit.
/// Stays alive after the main window closes so fans can be controlled in the background.
final class FanMenuBar: NSObject {
  let overlay = CPUFanOverlayView(frame: NSRect(x: 8, y: 8, width: 264, height: 116))
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let popover = NSPopover()
  private var shownText = ""
  var onShowDashboard: (() -> Void)?

  func install() {
    if let button = statusItem.button {
      button.image = nil
      button.imagePosition = .noImage
      button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      button.title = "--°"
      button.target = self
      button.action = #selector(statusClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.toolTip = "MacmonDash temperature — click for fans, right-click for menu"
    }

    let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 132))
    host.wantsLayer = true
    host.layer?.backgroundColor = tuiBackground.cgColor
    overlay.frame = host.bounds.insetBy(dx: 8, dy: 8)
    overlay.autoresizingMask = [.width, .height]
    host.addSubview(overlay)

    let controller = NSViewController()
    controller.view = host
    popover.contentViewController = controller
    popover.contentSize = host.frame.size
    popover.behavior = .transient
    popover.appearance = NSAppearance(named: .darkAqua)
  }

  func update(fans: [FanReading], manual0: Double?, manual1: Double?, tempC: Double) {
    overlay.update(fans: fans, manual0: manual0, manual1: manual1, tempC: tempC)
    guard let button = statusItem.button else { return }
    let tempF = fahrenheit(fromCelsius: tempC)
    let text = tempC > 1 ? "\(Int(tempF.rounded()))°" : "--°"
    if text != shownText {
      shownText = text
      button.title = text
    }
    var tip = tempC > 1 ? "\(Int(tempF.rounded()))°F · PMU TP package" : "Temperature"
    if !fans.isEmpty {
      tip += "\n" + fans.map { "\($0.rpm) rpm" }.joined(separator: "  ·  ")
    }
    tip += "\nClick: fans · Right-click: menu"
    button.toolTip = tip
  }

  @objc private func statusClicked(_ sender: Any?) {
    let type = NSApp.currentEvent?.type
    if type == .rightMouseUp {
      if popover.isShown { popover.performClose(nil) }
      showStatusMenu()
      return
    }
    togglePopover()
  }

  private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    overlay.needsLayout = true
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  private func showStatusMenu() {
    guard let button = statusItem.button else { return }
    let menu = NSMenu()
    menu.addItem(withTitle: "Show Dashboard", action: #selector(showDashboard), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit MacmonDash", action: #selector(quitApp), keyEquivalent: "")
    for item in menu.items { item.target = self }
    // Pop up under the status item (stays available with no main window).
    let loc = NSPoint(x: button.bounds.minX, y: button.bounds.minY - 2)
    menu.popUp(positioning: nil, at: loc, in: button)
  }

  @objc private func showDashboard() {
    onShowDashboard?()
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }
}
