import AppKit

/// Menu-bar fan. Clicking it opens only the fan-speed section (two fans + sliders).
final class FanMenuBar: NSObject {
  let overlay = CPUFanOverlayView(frame: NSRect(x: 8, y: 8, width: 264, height: 116))
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private var heatShown: FanHeat?

  func install() {
    if let button = statusItem.button {
      button.image = FanIconView.menuBarImage(heat: .normal)
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
      button.target = self
      button.action = #selector(toggle)
      button.toolTip = "MacmonDash fans"
    }

    let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 132))
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.black.cgColor
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
    let heat = FanHeat.from(tempC: tempC)
    if heatShown != heat {
      heatShown = heat
      statusItem.button?.image = FanIconView.menuBarImage(heat: heat)
    }
    overlay.update(fans: fans, manual0: manual0, manual1: manual1, tempC: tempC)
    guard let button = statusItem.button else { return }
    if fans.isEmpty {
      button.toolTip = "MacmonDash fans"
    } else {
      button.toolTip = fans.map { "\($0.rpm) rpm" }.joined(separator: "  ·  ")
    }
  }

  @objc private func toggle() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    overlay.needsLayout = true
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }
}
