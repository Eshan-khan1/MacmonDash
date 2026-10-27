import AppKit

/// Same green + mono face as the SwiftTerm / macmon TUI.
private let fanGreen = tuiGreen

private func tuiFont(size: CGFloat) -> NSFont {
  NSFont(name: "SF Mono", size: size)
    ?? NSFont(name: "Menlo", size: size)
    ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

/// Vertical slider — track + fill + thumb.
final class VerticalFanSlider: NSView {
  var value: Double = 0 { didSet { needsDisplay = true } }
  var onChange: ((Double) -> Void)?
  override var isFlipped: Bool { true }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

  override func draw(_ dirtyRect: NSRect) {
    let midX = bounds.midX
    let top: CGFloat = 3
    let bottom = bounds.height - 3
    let track = NSBezierPath()
    track.move(to: NSPoint(x: midX, y: top))
    track.line(to: NSPoint(x: midX, y: bottom))
    fanGreen.withAlphaComponent(0.35).setStroke()
    track.lineWidth = 3
    track.stroke()

    let fillH = CGFloat(value) * (bottom - top)
    if fillH > 0.5 {
      let fill = NSBezierPath()
      fill.move(to: NSPoint(x: midX, y: bottom))
      fill.line(to: NSPoint(x: midX, y: bottom - fillH))
      fanGreen.setStroke()
      fill.lineWidth = 4
      fill.stroke()
    }

    let y = bottom - CGFloat(value) * (bottom - top)
    let thumb = NSBezierPath()
    thumb.move(to: NSPoint(x: midX - 8, y: y))
    thumb.line(to: NSPoint(x: midX + 8, y: y))
    fanGreen.setStroke()
    thumb.lineWidth = 2.5
    thumb.stroke()
  }

  override func mouseDown(with event: NSEvent) { update(from: event) }
  override func mouseDragged(with event: NSEvent) { update(from: event) }

  private func update(from event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let top: CGFloat = 3
    let bottom = bounds.height - 3
    value = min(max(1 - Double((p.y - top) / max(bottom - top, 1)), 0), 1)
    onChange?(value)
  }
}

/// Fan icon color by temperature: green (normal) → yellow (warm) → red (hot).
enum FanHeat {
  case normal, warm, hot

  /// Thresholds in °C (Apple Silicon: ~70 warm, ~85 hot).
  static func from(tempC: Double) -> FanHeat {
    if tempC >= 85 { return .hot }
    if tempC >= 70 { return .warm }
    return .normal
  }

  /// (dim, mid, bright) shades used by the bit-graphic fan.
  var palette: (NSColor, NSColor, NSColor) {
    switch self {
    case .normal:
      return (
        NSColor(srgbRed: 50 / 255, green: 110 / 255, blue: 40 / 255, alpha: 1),
        tuiGreen,
        NSColor(srgbRed: 130 / 255, green: 220 / 255, blue: 95 / 255, alpha: 1)
      )
    case .warm:
      return (
        NSColor(srgbRed: 130 / 255, green: 105 / 255, blue: 20 / 255, alpha: 1),
        NSColor(srgbRed: 225 / 255, green: 190 / 255, blue: 30 / 255, alpha: 1),
        NSColor(srgbRed: 255 / 255, green: 230 / 255, blue: 110 / 255, alpha: 1)
      )
    case .hot:
      return (
        NSColor(srgbRed: 125 / 255, green: 25 / 255, blue: 20 / 255, alpha: 1),
        NSColor(srgbRed: 225 / 255, green: 50 / 255, blue: 40 / 255, alpha: 1),
        NSColor(srgbRed: 255 / 255, green: 130 / 255, blue: 110 / 255, alpha: 1)
      )
    }
  }
}

final class FanIconView: NSView {
  var linked = false
  var spinning = false { didSet { needsDisplay = true } }
  var rpmFraction: Double = 0
  var heat: FanHeat = .normal {
    didSet { if heat != oldValue { needsDisplay = true } }
  }
  private var frameIndex = 0
  private var timer: Timer?
  private var tickAccum = 0.0
  private let grid = 21
  private let bladeCount = 7

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      guard let self else { return }
      let rate = self.spinning ? (1.0 + self.rpmFraction * 9.0) : (self.linked ? 0.4 : 0)
      guard rate > 0 else { return }
      self.tickAccum += rate / 30.0
      if self.tickAccum >= 1 {
        self.tickAccum -= 1
        self.frameIndex = (self.frameIndex + 1) % 8
        self.needsDisplay = true
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }
  deinit { timer?.invalidate() }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

  override func draw(_ dirtyRect: NSRect) {
    let n = grid
    let cell = min(bounds.width, bounds.height) / CGFloat(n)
    let ox = (bounds.width - cell * CGFloat(n)) / 2
    let oy = (bounds.height - cell * CGFloat(n)) / 2
    let midP = Double(n - 1) / 2.0
    let angle = Double(frameIndex) * (.pi / 4)
    let hubR = midP * 0.22
    let outer = midP * 0.98
    let inner = hubR * 0.85
    var shade = [UInt8](repeating: 0, count: n * n)

    func put(_ xi: Int, _ yi: Int, _ s: UInt8) {
      guard xi >= 0, yi >= 0, xi < n, yi < n, s > 0 else { return }
      let i = yi * n + xi
      if s > shade[i] { shade[i] = s }
    }

    for b in 0..<bladeCount {
      let a0 = angle + Double(b) * (2 * .pi / Double(bladeCount))
      for t in stride(from: 0.0, through: 1.0, by: 0.04) {
        let r = inner + (outer - inner) * t
        let sweep = t * t * 1.15
        let halfW = (0.12 + 0.55 * sin(t * .pi)) * (outer * 0.12)
        for w in stride(from: -halfW, through: halfW, by: 0.35) {
          let a = a0 + sweep + w * 0.04
          let x = midP + cos(a) * r - sin(a) * w
          let y = midP + sin(a) * r + cos(a) * w
          let edge = w / max(halfW, 0.01)
          let s: UInt8 = edge > 0.35 ? 3 : (edge > -0.15 ? 2 : 1)
          let xi = Int(x.rounded()), yi = Int(y.rounded())
          put(xi, yi, s); put(xi + 1, yi, s); put(xi, yi + 1, min(s, 2))
        }
      }
    }
    let hc = Int(midP), hr = Int(hubR.rounded())
    for dy in -hr...hr {
      for dx in -hr...hr where dx * dx + dy * dy <= hr * hr { put(hc + dx, hc + dy, 2) }
    }
    let core = max(hr / 2, 1)
    for dy in -core...core {
      for dx in -core...core where dx * dx + dy * dy <= core * core {
        let xi = hc + dx, yi = hc + dy
        if xi >= 0, yi >= 0, xi < n, yi < n { shade[yi * n + xi] = 1 }
      }
    }

    let (dim, mid, bright) = heat.palette
    let colors: [NSColor] = [.clear, dim, mid, bright]
    for yi in 0..<n {
      for xi in 0..<n {
        let s = Int(shade[yi * n + xi])
        guard s > 0 else { continue }
        let dx = Double(xi) - midP, dy = Double(yi) - midP
        if dx * dx + dy * dy > outer * outer { continue }
        colors[s].setFill()
        let inset = cell * 0.05
        NSBezierPath(rect: NSRect(
          x: ox + CGFloat(xi) * cell + inset,
          y: oy + CGFloat(yi) * cell + inset,
          width: max(cell - inset * 2, 0.5),
          height: max(cell - inset * 2, 0.5)
        )).fill()
      }
    }
  }
}

/// One fan column: title / icon / "rpm  pct%" — frame-laid-out by parent.
final class FanColumnView: NSView {
  let title = NSTextField(labelWithString: "RPM")
  let stats = NSTextField(labelWithString: "0  0%")
  let icon = FanIconView(frame: .zero)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    for lab in [title, stats] {
      lab.textColor = fanGreen
      lab.backgroundColor = .clear
      lab.drawsBackground = false
      lab.isBezeled = false
      lab.alignment = .center
      lab.isEditable = false
      lab.isSelectable = false
      lab.refusesFirstResponder = true
      // Regular SF Mono / Menlo — same face & weight as the TUI (not bold/semibold)
      lab.font = tuiFont(size: 11)
      addSubview(lab)
    }
    addSubview(icon)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let w = bounds.width
    let h = bounds.height
    let titleH: CGFloat = 11
    let statsH: CGFloat = 11
    let gap: CGFloat = 1
    // Prefer a larger icon — take nearly all leftover space.
    let iconSide = min(w - 1, h - titleH - statsH - gap * 2)
    title.frame = NSRect(x: 0, y: h - titleH, width: w, height: titleH)
    icon.frame = NSRect(
      x: (w - iconSide) / 2,
      y: statsH + gap,
      width: iconSide,
      height: iconSide
    )
    stats.frame = NSRect(x: 0, y: 0, width: w, height: statsH)
  }

  func configure(rpm: Int, maxRpm: Int, manualLevel: Double?) {
    let live = maxRpm > 0 ? min(max(Double(rpm) / Double(maxRpm), 0), 1) : 0
    let frac = manualLevel.map { max($0, live) } ?? live
    let pct = Int((frac * 100).rounded())
    // Spacing/format closer to macmon labels (e.g. "25.23 / 32.0 GB")
    stats.stringValue = "\(rpm)rpm \(pct)%"
    icon.linked = maxRpm > 0
    icon.rpmFraction = frac
    icon.spinning = rpm > 40 || (manualLevel ?? 0) > 0.05
  }
}

/// Sketch: Fan | slider | slider | Fan — pure frame layout, no AL overlap.
final class CPUFanOverlayView: NSView {
  private let left = FanColumnView(frame: .zero)
  private let right = FanColumnView(frame: .zero)
  let slider0 = VerticalFanSlider(frame: .zero)
  let slider1 = VerticalFanSlider(frame: .zero)
  var onSlider0: ((Double) -> Void)?
  var onSlider1: ((Double) -> Void)?
  private let noFansLabel = NSTextField(labelWithString: "no fans on this Mac")

  /// False on fanless Macs (MacBook Air): sliders hidden, icons idle.
  var hasFans = true {
    didSet {
      guard hasFans != oldValue else { return }
      slider0.isHidden = !hasFans
      slider1.isHidden = !hasFans
      noFansLabel.isHidden = hasFans
      for col in [left, right] {
        col.stats.stringValue = hasFans ? col.stats.stringValue : "—"
        col.icon.spinning = false
        col.icon.linked = hasFans
        col.icon.alphaValue = hasFans ? 1 : 0.35
      }
      needsLayout = true
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    slider0.onChange = { [weak self] v in self?.onSlider0?(v) }
    slider1.onChange = { [weak self] v in self?.onSlider1?(v) }
    addSubview(left)
    addSubview(slider0)
    addSubview(slider1)
    addSubview(right)
    noFansLabel.textColor = fanGreen.withAlphaComponent(0.7)
    noFansLabel.font = tuiFont(size: 11)
    noFansLabel.alignment = .center
    noFansLabel.isHidden = true
    addSubview(noFansLabel)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point) else { return nil }
    return super.hitTest(point) ?? self
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
  override func mouseDown(with event: NSEvent) {}

  override func layout() {
    super.layout()
    let b = bounds
    let sliderW: CGFloat = 18
    let gap: CGFloat = 6
    let fanW = max((b.width - sliderW * 2 - gap * 5) / 2, 44)
    let groupW = fanW * 2 + sliderW * 2 + gap * 3
    let groupH = b.height - 4
    // Center the whole fan+slider group in the overlay.
    var x = (b.width - groupW) / 2
    let y: CGFloat = 2
    left.frame = NSRect(x: x, y: y, width: fanW, height: groupH)
    x += fanW + gap
    slider0.frame = NSRect(x: x, y: y + 10, width: sliderW, height: max(groupH - 20, 28))
    x += sliderW + gap
    slider1.frame = NSRect(x: x, y: y + 10, width: sliderW, height: max(groupH - 20, 28))
    x += sliderW + gap
    right.frame = NSRect(x: x, y: y, width: fanW, height: groupH)
    left.layoutSubtreeIfNeeded()
    right.layoutSubtreeIfNeeded()
    noFansLabel.frame = NSRect(x: 0, y: (b.height - 14) / 2, width: b.width, height: 14)
  }

  func update(fans: [FanReading], manual0: Double?, manual1: Double?, tempC: Double = 0) {
    let heat = FanHeat.from(tempC: tempC)
    left.icon.heat = heat
    right.icon.heat = heat
    guard hasFans else { return }
    if fans.count > 0 {
      left.configure(rpm: fans[0].rpm, maxRpm: fans[0].maxRpm, manualLevel: manual0)
      let live = fans[0].maxRpm > 0 ? Double(fans[0].rpm) / Double(fans[0].maxRpm) : 0
      let t = manual0 ?? live
      if abs(slider0.value - t) > 0.02 { slider0.value = t }
    }
    if fans.count > 1 {
      right.configure(rpm: fans[1].rpm, maxRpm: fans[1].maxRpm, manualLevel: manual1)
      let live = fans[1].maxRpm > 0 ? Double(fans[1].rpm) / Double(fans[1].maxRpm) : 0
      let t = manual1 ?? live
      if abs(slider1.value - t) > 0.02 { slider1.value = t }
    } else if fans.count == 1 {
      right.configure(rpm: fans[0].rpm, maxRpm: fans[0].maxRpm, manualLevel: manual1)
    }
  }
}
