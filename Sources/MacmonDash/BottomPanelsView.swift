import AppKit

/// Terminal.app “Clear Dark” — navy field and ANSI green from the reference screenshot.
let tuiBackground = NSColor(srgbRed: 0.09838771145, green: 0.1138777476, blue: 0.152602838, alpha: 1)
let tuiGreen = NSColor(srgbRed: 0.4241566305, green: 0.6672818346, blue: 0.4415227165, alpha: 1)
let tuiText = NSColor(srgbRed: 0.8776108099, green: 0.8776108099, blue: 0.8776108099, alpha: 1)
/// Dark gap between graph bands, as a fraction of one terminal row.
let tuiRowGapFraction: CGFloat = 0.22

/// Mirror of SwiftTerm's cell grid so overlays can sit exactly on TUI cells.
struct TerminalGrid {
  let cols: Int
  let rows: Int
  let cellW: CGFloat
  let cellH: CGFloat
  let font: NSFont
  /// Height of the terminal view (rows are anchored to the top).
  let viewHeight: CGFloat

  init?(cols: Int, rows: Int, font: NSFont, viewHeight: CGFloat, scale: CGFloat) {
    guard cols > 8, rows > 8, viewHeight > 0 else { return nil }
    self.cols = cols
    self.rows = rows
    self.font = font
    self.viewHeight = viewHeight
    let size = TerminalGrid.cellSize(font: font, scale: scale)
    cellW = size.width
    cellH = size.height
  }

  /// Same math as SwiftTerm `computeFontDimensions` (snapped to pixel grid).
  static func cellSize(font: NSFont, scale: CGFloat) -> CGSize {
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)
    let leading = CTFontGetLeading(font)
    let cellHeight = ceil(ascent + descent + leading)
    var chars: [UniChar] = [0x57]
    var glyphs: [CGGlyph] = [0]
    CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
    let cellWidth = font.advancement(forGlyph: NSGlyph(glyphs[0])).width
    let s = max(scale, 1)
    return CGSize(
      width: max(1, (cellWidth * s).rounded() / s),
      height: max(1, ceil(cellHeight * s) / s)
    )
  }

  /// Baseline offset from the cell bottom (SwiftTerm `CellGeometry.baselineOffset`).
  var baselineOffset: CGFloat {
    let descent = CTFontGetDescent(font)
    let leading = CTFontGetLeading(font)
    let natural = ceil(CTFontGetAscent(font) + descent + leading)
    let extra = max(0, cellH - natural)
    return ceil(descent + leading) + floor(extra / 2)
  }

  /// AppKit (non-flipped) rect for a block of cells.
  func rect(col: Int, row: Int, w: Int, h: Int) -> NSRect {
    NSRect(
      x: CGFloat(col) * cellW,
      y: viewHeight - CGFloat(row + h) * cellH,
      width: CGFloat(w) * cellW,
      height: CGFloat(h) * cellH
    )
  }
}

/// Cell rectangle in terminal coordinates (col/row/w/h).
struct CellRect {
  var col: Int
  var row: Int
  var w: Int
  var h: Int
  var inner: CellRect { CellRect(col: col + 1, row: row + 1, w: max(w - 2, 0), h: max(h - 2, 0)) }
}

/// Replicates macmon's ratatui layout for the bottom power band.
struct TuiBottomLayout {
  let outer: CellRect       // rows[1] block (Power/Total title block)
  let cpu: CellRect         // ha[0]
  let gpu: CellRect         // ha[1]  (we draw Temp here)
  let ane: CellRect         // ha[2]  (we draw Power here)

  init(cols: Int, rows: Int) {
    func r(_ v: Double) -> Int { Int(v.rounded()) }
    // Vertical: Fill(2), Fill(1)
    let split = r(Double(rows) * 2.0 / 3.0)
    outer = CellRect(col: 0, row: split, w: cols, h: rows - split)
    let inner = outer.inner
    // Horizontal: Fill(1) ×3 over inner width (boundaries rounded like ratatui).
    let w = Double(inner.w)
    let b1 = inner.col + r(w / 3.0)
    let b2 = inner.col + r(w * 2.0 / 3.0)
    cpu = CellRect(col: inner.col, row: inner.row, w: b1 - inner.col, h: inner.h)
    gpu = CellRect(col: b1, row: inner.row, w: b2 - b1, h: inner.h)
    ane = CellRect(col: b2, row: inner.row, w: inner.col + inner.w - b2, h: inner.h)
  }
}

/// Replicates macmon's ratatui layout for the top band (CPU / RAM / GPU boxes).
struct TuiTopLayout {
  let outer: CellRect   // rows[0]
  let cpuLeft: CellRect  // iarea[0] left half — lowest CPU tier (E on M1–M4)
  let cpuRight: CellRect // iarea[0] right half — highest CPU tier (P on M1–M4)
  let ram: CellRect     // iarea[1] left half (RAM/SWAP box)
  let gpu: CellRect     // iarea[1] right half

  init(cols: Int, rows: Int) {
    func r(_ v: Double) -> Int { Int(v.rounded()) }
    let split = r(Double(rows) * 2.0 / 3.0)
    outer = CellRect(col: 0, row: 0, w: cols, h: split)
    let inner = outer.inner
    // Vertical Fill(1) ×2 inside the outer block
    let mid = inner.row + r(Double(inner.h) / 2.0)
    let row1 = CellRect(col: inner.col, row: inner.row, w: inner.w, h: mid - inner.row)
    let row2 = CellRect(col: inner.col, row: mid, w: inner.w, h: inner.row + inner.h - mid)
    // Horizontal Fill(1) ×2
    let b1 = row1.col + r(Double(row1.w) / 2.0)
    cpuLeft = CellRect(col: row1.col, row: row1.row, w: b1 - row1.col, h: row1.h)
    cpuRight = CellRect(col: b1, row: row1.row, w: row1.col + row1.w - b1, h: row1.h)
    let b2 = row2.col + r(Double(row2.w) / 2.0)
    ram = CellRect(col: row2.col, row: row2.row, w: b2 - row2.col, h: row2.h)
    gpu = CellRect(col: b2, row: row2.row, w: row2.col + row2.w - b2, h: row2.h)
  }
}

/// Cuts the same horizontal gaps into macmon's E-CPU, P-CPU, RAM, and GPU graphs.
final class GraphStripeOverlay: NSView {
  private var grid: TerminalGrid?
  private var cells: [CellRect] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = false
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func place(grid: TerminalGrid?, cells: [CellRect]) {
    self.grid = grid
    self.cells = cells
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let g = grid else { return }
    let gap = max(1, (g.cellH * tuiRowGapFraction).rounded())
    tuiBackground.setFill()
    for cell in cells {
      let inner = cell.inner
      guard inner.w > 0, inner.h > 0 else { continue }
      for row in 0..<inner.h {
        let band = g.rect(col: inner.col, row: inner.row + row, w: inner.w, h: 1)
        NSRect(x: band.minX, y: band.maxY - gap, width: band.width, height: gap).fill()
      }
    }
  }
}

/// Covers "Power: … / Total …" text but keeps the outer box's top border line.
final class TitleMaskView: NSView {
  var lineY: CGFloat = 0
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = false
    autoresizingMask = []
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    tuiBackground.setFill()
    bounds.fill()
    guard bounds.width > 2 else { return }
    tuiGreen.setStroke()
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 0, y: lineY))
    p.line(to: NSPoint(x: bounds.width, y: lineY))
    p.lineWidth = 1
    p.stroke()
  }
}

/// One bottom cell drawn like ratatui `Block::bordered().border_type(Rounded)`
/// + `Sparkline` on the terminal grid.
final class MetricPanelView: NSView {
  enum Kind { case temperature, power }

  private let kind: Kind
  private var title = ""
  /// Optional right-aligned title on the top border (e.g. battery on the Power panel).
  private var titleRight = ""
  private var history: [Double] = []
  private var rawHistory: [Double] = []
  private let maxPoints = 128
  private var grid: TerminalGrid?
  private var cell = CellRect(col: 0, row: 0, w: 0, h: 0)

  init(kind: Kind) {
    self.kind = kind
    super.init(frame: .zero)
    wantsLayer = false
    autoresizingMask = []
  }

  required init?(coder: NSCoder) { fatalError() }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

  func place(grid: TerminalGrid, cell: CellRect) {
    self.grid = grid
    self.cell = cell
    frame = grid.rect(col: cell.col, row: cell.row, w: cell.w, h: cell.h)
    needsDisplay = true
  }

  func updateTemperature(current: Double, avg: Double, maxT: Double) {
    let currentF = fahrenheit(fromCelsius: current)
    let avgF = fahrenheit(fromCelsius: avg)
    let maxF = fahrenheit(fromCelsius: maxT)
    title = String(format: " Temp %.1f°F (%.1f, %.1f) ", currentF, avgF, maxF)
    // 194°F is the old 90°C floor, so the graph doesn't sit at full height.
    push(currentF, scaleMax: max(maxF, 194))
  }

  func updatePower(watts: Double, avg: Double, maxW: Double, batteryC: Double = 0) {
    title = String(format: " Power %.2fW (%.2f, %.2f) ", watts, avg, maxW)
    if batteryC > 1 {
      titleRight = String(format: " Bat %.1f°F ", fahrenheit(fromCelsius: batteryC))
    } else {
      titleRight = ""
    }
    push(watts, scaleMax: max(maxW, watts, 0.5))
  }

  private func push(_ value: Double, scaleMax: Double) {
    rawHistory.insert(value, at: 0)
    if rawHistory.count > maxPoints { rawHistory.removeLast(rawHistory.count - maxPoints) }
    let denom = max(scaleMax, 0.001)
    history = rawHistory.map { min(max($0 / denom, 0), 1) }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    tuiBackground.setFill()
    bounds.fill()
    guard let g = grid, cell.w >= 3, cell.h >= 2 else { return }

    let cw = g.cellW
    let ch = g.cellH
    let b = bounds

    // Border path runs through cell centers, like box-drawing glyphs.
    let border = NSRect(
      x: b.minX + cw / 2,
      y: b.minY + ch / 2,
      width: b.width - cw,
      height: b.height - ch
    )
    let radius = min(cw, ch) / 2
    let path = NSBezierPath(roundedRect: border, xRadius: radius, yRadius: radius)
    path.lineWidth = 1
    tuiGreen.setStroke()
    path.stroke()

    // Titles on the top border (ratatui title_top left / right).
    let attrs: [NSAttributedString.Key: Any] = [
      .font: g.font,
      .foregroundColor: tuiGreen,
    ]
    let topRowY = b.maxY - ch
    let baseline = topRowY + g.baselineOffset
    let innerChars = max(cell.w - 2, 0)
    let rightText: String = {
      guard !titleRight.isEmpty else { return "" }
      return String(titleRight.prefix(innerChars))
    }()
    let leftBudget = max(innerChars - rightText.count, 0)
    let leftText = String(title.prefix(leftBudget))

    func drawTitle(_ text: String, rightAligned: Bool) {
      guard !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
      let nchars = CGFloat(text.count)
      let x = rightAligned
        ? b.maxX - cw - nchars * cw
        : b.minX + cw
      let textRect = NSRect(x: x, y: topRowY, width: nchars * cw, height: ch)
      tuiBackground.setFill()
      textRect.fill()
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
      ctx.saveGState()
      ctx.textMatrix = .identity
      ctx.textPosition = CGPoint(x: textRect.minX, y: baseline)
      CTLineDraw(line, ctx)
      ctx.restoreGState()
    }
    drawTitle(leftText, rightAligned: false)
    drawTitle(rightText, rightAligned: true)

    // Sparkline inside the border: one column per sample, right-to-left.
    let innerCols = cell.w - 2
    let innerRows = cell.h - 2
    guard innerCols > 0, innerRows > 0, !history.isEmpty else { return }
    let innerX = b.minX + cw
    let innerY = b.minY + ch
    let innerH = CGFloat(innerRows) * ch
    let innerRight = innerX + CGFloat(innerCols) * cw
    // One band per terminal row, with a gap so the graph reads as macmon's striped blocks.
    let rowGap = max(1, (ch * tuiRowGapFraction).rounded())
    let band = max(ch - rowGap, 1)
    tuiGreen.setFill()
    for (i, v) in history.enumerated() where i < innerCols {
      let eighths = (v * Double(innerRows) * 8).rounded()
      guard eighths > 0 else { continue }
      let fullRows = min(Int(eighths) / 8, innerRows)
      let partial = CGFloat(Int(eighths) % 8) / 8
      let x = innerRight - CGFloat(i + 1) * cw
      for row in 0..<fullRows {
        let y = innerY + CGFloat(row) * ch
        NSBezierPath(rect: NSRect(x: x, y: y, width: cw, height: band)).fill()
      }
      if partial > 0.01, fullRows < innerRows {
        let y = innerY + CGFloat(fullRows) * ch
        NSBezierPath(rect: NSRect(x: x, y: y, width: cw, height: max(band * partial, 1))).fill()
      }
    }
  }
}

/// Temp (middle) + Power (right) panels placed on macmon's GPU/ANE cells.
final class BottomSectionChrome {
  let titleMask = TitleMaskView(frame: .zero)
  let tempPanel = MetricPanelView(kind: .temperature)
  let powerPanel = MetricPanelView(kind: .power)
  /// Covers macmon's stuck "CPU 0.00W …" on the CPU box (fans hide that sparkline).
  let cpuPowerPatch = GridTextPatch(frame: .zero)
  /// Covers macmon's right-aligned "54.2°C" on the CPU box.
  let cpuTempPatch = GridTextPatch(frame: .zero)
  private let cpuTempWidth = 10
  private var cpuPowerWidth = 28

  private var tempAvg = 0.0
  private var tempMax = 0.0
  private var tempSamples = 0
  private var powerAvg = 0.0
  private var powerMax = 0.0
  private var powerSamples = 0
  private var cpuPowerAvg = 0.0
  private var cpuPowerMax = 0.0
  private var cpuPowerSamples = 0

  private(set) var grid: TerminalGrid?
  private(set) var layout: TuiBottomLayout?

  func install(on root: NSView) {
    root.addSubview(tempPanel)
    root.addSubview(powerPanel)
    root.addSubview(titleMask)
    root.addSubview(cpuPowerPatch)
    root.addSubview(cpuTempPatch)
  }

  /// When false, macmon's own Power / CPU / GPU / ANE band stays visible.
  func setVisible(_ visible: Bool) {
    tempPanel.isHidden = !visible
    powerPanel.isHidden = !visible
    titleMask.isHidden = !visible
    cpuPowerPatch.isHidden = !visible
    cpuTempPatch.isHidden = !visible
  }

  /// Returns the inner CPU cell rect (for the fan overlay), or nil if unknown.
  @discardableResult
  func relayout(grid: TerminalGrid?) -> NSRect? {
    guard let g = grid else {
      tempPanel.frame = .zero
      powerPanel.frame = .zero
      titleMask.frame = .zero
      cpuPowerPatch.frame = .zero
      cpuTempPatch.frame = .zero
      self.grid = nil
      self.layout = nil
      return nil
    }
    self.grid = g
    let l = TuiBottomLayout(cols: g.cols, rows: g.rows)
    self.layout = l

    tempPanel.place(grid: g, cell: l.gpu)
    powerPanel.place(grid: g, cell: l.ane)

    // Hide "Power: … / Total …" on the outer top border, keep the line.
    let titleCols = max(l.outer.w - 4, 0)
    titleMask.frame = g.rect(col: l.outer.col + 2, row: l.outer.row, w: titleCols, h: 1)
    titleMask.lineY = g.cellH / 2
    titleMask.needsDisplay = true

    // Left title: live CPU watts from metrics pipe (macmon 0.7.2 often sticks at 0).
    cpuPowerWidth = max(min(l.cpu.w - 2 - cpuTempWidth - 1, 30), 12)
    cpuPowerPatch.font = g.font
    cpuPowerPatch.baselineOffset = g.baselineOffset
    cpuPowerPatch.frame = g.rect(col: l.cpu.col + 1, row: l.cpu.row, w: cpuPowerWidth, h: 1)

    // Right-aligned on the CPU box top border, ending one cell before the corner.
    cpuTempPatch.font = g.font
    cpuTempPatch.baselineOffset = g.baselineOffset
    let tempCol = l.cpu.col + l.cpu.w - 1 - cpuTempWidth
    cpuTempPatch.frame = g.rect(col: tempCol, row: l.cpu.row, w: cpuTempWidth, h: 1)

    let inner = l.cpu.inner
    return g.rect(col: inner.col, row: inner.row, w: inner.w, h: inner.h)
  }

  func update(_ m: LiveMetrics) {
    // Package probes: TP*s (CPU/system) + TP*g (GPU). Panel shows the hotter one.
    let temp = m.displayTemp
    if temp > 1 {
      tempSamples += 1
      tempAvg += (temp - tempAvg) / Double(tempSamples)
      tempMax = max(tempMax, temp)
      tempPanel.updateTemperature(current: temp, avg: tempAvg, maxT: tempMax)
      // CPU box corner: TP*s (falls back to hottest if only GPU-side is present).
      let corner = m.packageS > 1 ? m.packageS : temp
      let label = String(format: " %.1f°F ", fahrenheit(fromCelsius: corner))
      let pad = String(repeating: " ", count: max(0, cpuTempWidth - label.count))
      cpuTempPatch.text = pad + label
    }

    // Fan cell left title: real CPU package watts (pipe), not macmon's stuck 0.00W.
    let cpuW = m.cpuPower
    cpuPowerSamples += 1
    cpuPowerAvg += (cpuW - cpuPowerAvg) / Double(cpuPowerSamples)
    cpuPowerMax = max(cpuPowerMax, cpuW)
    var powerLabel = String(format: " CPU %.2fW (%.2f, %.2f) ", cpuW, cpuPowerAvg, cpuPowerMax)
    if powerLabel.count > cpuPowerWidth {
      powerLabel = String(format: " CPU %.2fW ", cpuW)
    }
    if powerLabel.count < cpuPowerWidth {
      powerLabel += String(repeating: " ", count: cpuPowerWidth - powerLabel.count)
    }
    cpuPowerPatch.text = String(powerLabel.prefix(cpuPowerWidth))

    let watts = m.sysPower > 0 ? m.sysPower : m.allPower
    powerSamples += 1
    powerAvg += (watts - powerAvg) / Double(powerSamples)
    powerMax = max(powerMax, watts)
    powerPanel.updatePower(watts: watts, avg: powerAvg, maxW: powerMax, batteryC: m.batteryTemp)
  }
}
