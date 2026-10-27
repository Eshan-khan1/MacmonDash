import AppKit

/// Source green tuned so AppKit drawing lands on the same screen pixels as
/// SwiftTerm's macmon green (~#5BB941 / 91,185,65). Raw sRGB of that value
/// renders brighter (~115,183,82) in NSView; this darker source corrects it.
let tuiGreen = NSColor(srgbRed: 45 / 255, green: 187 / 255, blue: 39 / 255, alpha: 1)

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
  let ram: CellRect     // iarea[1] left half (RAM/SWAP box)
  let gpu: CellRect     // iarea[1] right half

  init(cols: Int, rows: Int) {
    func r(_ v: Double) -> Int { Int(v.rounded()) }
    let split = r(Double(rows) * 2.0 / 3.0)
    outer = CellRect(col: 0, row: 0, w: cols, h: split)
    let inner = outer.inner
    // Vertical Fill(1) ×2 inside the outer block
    let mid = inner.row + r(Double(inner.h) / 2.0)
    let row2 = CellRect(col: inner.col, row: mid, w: inner.w, h: inner.row + inner.h - mid)
    // Horizontal Fill(1) ×2
    let b = row2.col + r(Double(row2.w) / 2.0)
    ram = CellRect(col: row2.col, row: row2.row, w: b - row2.col, h: row2.h)
    gpu = CellRect(col: b, row: row2.row, w: row2.col + row2.w - b, h: row2.h)
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
    NSColor.black.setFill()
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
    title = String(format: " Temp %.1f°C (%.1f, %.1f) ", current, avg, maxT)
    push(current, scaleMax: max(maxT, 90))
  }

  func updatePower(watts: Double, avg: Double, maxW: Double) {
    title = String(format: " Power %.2fW (%.2f, %.2f) ", watts, avg, maxW)
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
    NSColor.black.setFill()
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

    // Title on the top border starting at col+1 (ratatui title_top).
    if !title.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: g.font,
        .foregroundColor: tuiGreen,
      ]
      let maxChars = max(cell.w - 2, 0)
      let text = String(title.prefix(maxChars))
      let nchars = CGFloat(text.count)
      let topRowY = b.maxY - ch
      let textRect = NSRect(x: b.minX + cw, y: topRowY, width: nchars * cw, height: ch)
      NSColor.black.setFill()
      textRect.fill()
      // Draw on the exact baseline SwiftTerm uses for this row.
      let baseline = topRowY + g.baselineOffset
      if let ctx = NSGraphicsContext.current?.cgContext {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: textRect.minX, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
      }
    }

    // Sparkline inside the border: one column per sample, right-to-left.
    let innerCols = cell.w - 2
    let innerRows = cell.h - 2
    guard innerCols > 0, innerRows > 0, !history.isEmpty else { return }
    let innerX = b.minX + cw
    let innerY = b.minY + ch
    let innerH = CGFloat(innerRows) * ch
    let innerRight = innerX + CGFloat(innerCols) * cw
    tuiGreen.setFill()
    for (i, v) in history.enumerated() where i < innerCols {
      // Quantize like NINE_LEVELS bar set (1/8 cell steps).
      let eighths = (v * Double(innerRows) * 8).rounded()
      guard eighths > 0 else { continue }
      let h = CGFloat(eighths) / 8 * ch
      let x = innerRight - CGFloat(i + 1) * cw
      NSBezierPath(rect: NSRect(x: x, y: innerY, width: cw, height: min(h, innerH))).fill()
    }
  }
}

/// Temp (middle) + Power (right) panels placed on macmon's GPU/ANE cells.
final class BottomSectionChrome {
  let titleMask = TitleMaskView(frame: .zero)
  let tempPanel = MetricPanelView(kind: .temperature)
  let powerPanel = MetricPanelView(kind: .power)

  private var tempAvg = 0.0
  private var tempMax = 0.0
  private var tempSamples = 0
  private var powerAvg = 0.0
  private var powerMax = 0.0
  private var powerSamples = 0

  private(set) var grid: TerminalGrid?
  private(set) var layout: TuiBottomLayout?

  func install(on root: NSView) {
    root.addSubview(tempPanel)
    root.addSubview(powerPanel)
    root.addSubview(titleMask)
  }

  /// Returns the inner CPU cell rect (for the fan overlay), or nil if unknown.
  @discardableResult
  func relayout(grid: TerminalGrid?) -> NSRect? {
    guard let g = grid else {
      tempPanel.frame = .zero
      powerPanel.frame = .zero
      titleMask.frame = .zero
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

    let inner = l.cpu.inner
    return g.rect(col: inner.col, row: inner.row, w: inner.w, h: inner.h)
  }

  func update(_ m: LiveMetrics) {
    let temp = max(m.cpuTemp, m.gpuTemp)
    tempSamples += 1
    tempAvg += (temp - tempAvg) / Double(tempSamples)
    tempMax = max(tempMax, temp)
    tempPanel.updateTemperature(current: temp, avg: tempAvg, maxT: tempMax)

    let watts = m.sysPower > 0 ? m.sysPower : m.allPower
    powerSamples += 1
    powerAvg += (watts - powerAvg) / Double(powerSamples)
    powerMax = max(powerMax, watts)
    powerPanel.updatePower(watts: watts, avg: powerAvg, maxW: powerMax)
  }
}
