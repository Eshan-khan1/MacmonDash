import AppKit
import SwiftTerm
import os.log

private let log = Logger(subsystem: "com.local.macmondash", category: "App")

/// Clear Dark’s 16 ANSI colors, so macmon’s green matches the overlays.
private let tuiAnsiColors: [Color] = [
  Color(red8: 53, green8: 66, blue8: 76),
  Color(red8: 180, green8: 86, blue8: 72),
  Color(red8: 108, green8: 170, blue8: 113),
  Color(red8: 196, green8: 172, blue8: 98),
  Color(red8: 109, green8: 150, blue8: 180),
  Color(red8: 189, green8: 123, blue8: 205),
  Color(red8: 124, green8: 203, blue8: 205),
  Color(red8: 222, green8: 229, blue8: 235),
  Color(red8: 70, green8: 92, blue8: 109),
  Color(red8: 223, green8: 108, blue8: 90),
  Color(red8: 121, green8: 190, blue8: 126),
  Color(red8: 229, green8: 200, blue8: 114),
  Color(red8: 103, green8: 181, blue8: 237),
  Color(red8: 211, green8: 137, blue8: 229),
  Color(red8: 132, green8: 221, blue8: 224),
  Color(red8: 229, green8: 239, blue8: 245),
]

/// Allows free horizontal/vertical resize (no cell snapping).
final class ResizableMacmonWindow: NSWindow {
  override var resizeIncrements: NSSize {
    get { NSSize(width: 1, height: 1) }
    set {}
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    var r = super.constrainFrameRect(frameRect, to: screen)
    // Never clamp width to a fixed value — only keep a small minimum.
    if r.width < 500 { r.size.width = 500 }
    if r.height < 320 { r.size.height = 320 }
    return r
  }
}

/// macmon TUI + small fan overlay in the CPU power box only.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, LocalProcessTerminalViewDelegate {
  private var window: ResizableMacmonWindow?
  private var terminal: LocalProcessTerminalView?
  private var fanOverlay: CPUFanOverlayView?
  private let fanMenu = FanMenuBar()
  private var bottomChrome = BottomSectionChrome()
  private let graphStripes = GraphStripeOverlay(frame: .zero)
  private var metricsPipe = MetricsPipe()
  private let helperSetup = HelperSetup()
  private var pingTimer: Timer?
  private var sawFirstSample = false
  private var lastMetrics = LiveMetrics()
  private let ramButton = RamCleanButton(frame: .zero)
  private let ramStatus = RamStatusLabel(frame: .zero)
  private let cpuLeftTitle = GridTextPatch(frame: .zero)
  private let cpuRightTitle = GridTextPatch(frame: .zero)
  private let cpuHeaderPatch = GridTextPatch(frame: .zero)
  private var clusterFix = ClusterCorrection.none
  /// User slider targets (0…1). When > 0.05, SMC manual mode is active.
  private var level0: Double = 0
  private var level1: Double = 0
  private var manual0 = false
  private var manual1 = false
  private var maxRpm0 = 4000
  private var maxRpm1 = 4000
  private var writeWork0: DispatchWorkItem?
  private var writeWork1: DispatchWorkItem?
  private var started = false
  private var startAttempts = 0
  private var termCols = 0
  private var termRows = 0
  private var keyMonitor: Any?
  /// When false, Quit / ⌘Q parks to the menu bar instead of exiting.
  private var allowTerminate = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame MacmonDashMain")
    AppMenu.install(target: self)

    let content = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 580))
    content.wantsLayer = true
    content.layer?.backgroundColor = tuiBackground.cgColor
    content.autoresizesSubviews = true

    let term = LocalProcessTerminalView(frame: content.bounds)
    term.autoresizingMask = [.width, .height]
    term.processDelegate = self
    term.nativeBackgroundColor = tuiBackground
    term.nativeForegroundColor = tuiText
    term.installColors(tuiAnsiColors)
    term.font = NSFont(name: "SF Mono", size: 12)
      ?? NSFont(name: "Menlo", size: 12)
      ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    content.addSubview(term)
    self.terminal = term
    graphStripes.frame = content.bounds
    graphStripes.autoresizingMask = [.width, .height]
    content.addSubview(graphStripes)

    // Frame-based overlay (no Auto Layout) so it cannot lock window width.
    let overlay = CPUFanOverlayView(frame: .zero)
    overlay.autoresizingMask = []
    overlay.onSlider0 = { [weak self] v in self?.userMovedSlider(index: 0, level: v) }
    overlay.onSlider1 = { [weak self] v in self?.userMovedSlider(index: 1, level: v) }
    self.fanOverlay = overlay
    fanMenu.install()
    fanMenu.onShowDashboard = { [weak self] in self?.showMainWindow(nil) }
    fanMenu.onQuit = { [weak self] in self?.quitFully(nil) }
    fanMenu.overlay.onSlider0 = { [weak self] v in self?.userMovedSlider(index: 0, level: v) }
    fanMenu.overlay.onSlider1 = { [weak self] v in self?.userMovedSlider(index: 1, level: v) }
    // Temp (middle) + Power (right) over macmon; fans in the CPU cell on top.
    bottomChrome.install(on: content)
    content.addSubview(overlay, positioned: .above, relativeTo: bottomChrome.powerPanel)

    // RAM box: small "free RAM" broom button + transient status text.
    ramButton.onClick = { [weak self] in self?.freeRam() }
    content.addSubview(ramStatus)
    content.addSubview(ramButton)
    content.addSubview(cpuLeftTitle)
    content.addSubview(cpuRightTitle)
    content.addSubview(cpuHeaderPatch)

    let window = ResizableMacmonWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "MacmonDash"
    window.contentView = content
    window.backgroundColor = tuiBackground
    // Force free pixel resize (terminals often snap to cell size).
    window.resizeIncrements = NSSize(width: 1, height: 1)
    window.aspectRatio = .zero
    window.contentAspectRatio = .zero
    window.minSize = NSSize(width: 500, height: 320)
    window.maxSize = NSSize(width: 50_000, height: 50_000)
    window.contentMinSize = NSSize(width: 500, height: 320)
    window.contentMaxSize = NSSize(width: 50_000, height: 50_000)
    window.isReleasedWhenClosed = false
    window.styleMask.insert(.resizable)
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(relayoutOverlay),
      name: NSWindow.didResizeNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidEndLiveResize),
      name: NSWindow.didEndLiveResizeNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(mainWindowWillClose),
      name: NSWindow.willCloseNotification,
      object: window
    )

    NSApp.activate(ignoringOtherApps: true)
    // Match overlays to macmon’s saved color/interval before the TUI starts
    // (macmon persists `~/.config/macmon.json`; we used to always start on Green).
    applyMacmonConfigSync(restartPipe: false)
    installMacmonKeySync()
    scheduleStart()
    startMetricsPipe()
    DispatchQueue.main.async { [weak self] in self?.relayoutOverlay() }

    // While any fan is manual, keep the helper's watchdog fed.
    pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.manual0 || self.manual1 else { return }
        FanPrivileged.ping()
      }
    }

    // First launch: explain the app + offer the privileged helper (after the
    // window is up so the dialog has something to sit on).
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self else { return }
      self.helperSetup.showWelcomeIfNeeded(window: self.window)
    }
    // Optional GitHub Releases check (one GET). Silent unless a newer tag exists.
    UpdateChecker.checkOnLaunch(window: window)

    ClusterLabels.load { [weak self] fix in
      guard let self else { return }
      self.clusterFix = fix
      self.relayoutOverlay()
    }
  }

  // MARK: - Menu actions

  @objc func checkForUpdates(_ sender: Any?) {
    UpdateChecker.check(manual: true, window: window)
  }

  @objc func showAbout(_ sender: Any?) {
    let credits = NSMutableAttributedString(string: """
      Live Apple Silicon monitor built on macmon by vladkens (TUI) \
      and SwiftTerm by Miguel de Icaza.

      Fan control + cache purge via a LaunchDaemon helper (SMC).
      """)
    credits.addAttributes(
      [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor],
      range: NSRange(location: 0, length: credits.length)
    )
    NSApp.orderFrontStandardAboutPanel(options: [
      .credits: credits,
      .applicationName: "MacmonDash",
    ])
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc func installHelper(_ sender: Any?) {
    helperSetup.ensureReady(reason: .menu, window: window) { _ in }
  }

  @objc func removeHelper(_ sender: Any?) {
    // Hand fans back before the daemon disappears.
    allFansAuto(nil)
    helperSetup.removeHelper(window: window) { ok in
      log.info("remove helper ok=\(ok)")
    }
  }

  @objc func helperStatus(_ sender: Any?) {
    helperSetup.showHelperStatus(window: window)
  }

  @objc func allFansAuto(_ sender: Any?) {
    let wasManual = manual0 || manual1
    level0 = 0; level1 = 0
    manual0 = false; manual1 = false
    fanOverlay?.slider0.value = 0
    fanOverlay?.slider1.value = 0
    fanMenu.overlay.slider0.value = 0
    fanMenu.overlay.slider1.value = 0
    guard wasManual else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      FanPrivileged.setAutoSilently(fanIndex: 0)
      FanPrivileged.setAutoSilently(fanIndex: 1)
    }
  }

  @objc func openRepo(_ sender: Any?) {
    NSWorkspace.shared.open(AppMenu.repoURL)
  }

  @objc func openIssues(_ sender: Any?) {
    NSWorkspace.shared.open(AppMenu.repoURL.appendingPathComponent("issues"))
  }

  /// Keep the helper items honest: Install / Update / Remove per current state.
  func menuNeedsUpdate(_ menu: NSMenu) {
    let installed = FanPrivileged.filesInstalled
    if let item = menu.item(withTag: AppMenu.MenuTag.installHelper.rawValue) {
      item.title = installed ? "Update Fan Helper…" : "Install Fan Helper…"
      item.isHidden = installed && helperSetup.isReady
    }
    if let item = menu.item(withTag: AppMenu.MenuTag.removeHelper.rawValue) {
      item.isHidden = !installed
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(allFansAuto(_:)) { return fanOverlay?.hasFans ?? false }
    return true
  }

  @objc private func windowDidEndLiveResize() {
    relayoutOverlay()
  }

  /// Closing the window parks the dashboard; metrics + menu-bar fans keep running.
  @objc private func mainWindowWillClose(_ note: Notification) {
    if started {
      terminal?.terminate()
      started = false
    }
    fanOverlay?.animationsEnabled = false
    // Slow the metrics pipe — menu bar only needs a light pulse.
    metricsPipe.setIntervalMs(MetricsCadence.backgroundMs)
    // Drop the Dock icon; the ° status item stays in the menu bar.
    NSApp.setActivationPolicy(.accessory)
  }

  /// App menu Quit / ⌘Q — leave the menu-bar temp control running.
  @objc func parkToMenuBar(_ sender: Any?) {
    guard let window else {
      NSApp.setActivationPolicy(.accessory)
      return
    }
    if window.isVisible {
      window.close()
    } else {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  /// Status-item menu Quit — actually exit the process.
  @objc func quitFully(_ sender: Any?) {
    allowTerminate = true
    NSApp.terminate(nil)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if allowTerminate { return .terminateNow }
    parkToMenuBar(nil)
    return .terminateCancel
  }

  @objc func showMainWindow(_ sender: Any?) {
    guard let window else { return }
    NSApp.setActivationPolicy(.regular)
    metricsPipe.setIntervalMs(MetricsCadence.dashboardMs)
    fanOverlay?.animationsEnabled = true
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if !started {
      startAttempts = 0
      scheduleStart()
    }
    relayoutOverlay()
  }

  /// Fans in the CPU cell + Temp/Power panels on the terminal grid.
  @objc private func relayoutOverlay() {
    guard let root = window?.contentView, let overlay = fanOverlay, let term = terminal else { return }
    let scale = window?.backingScaleFactor ?? 2
    let font = term.font
    let grid = TerminalGrid(
      cols: termCols, rows: termRows, font: font,
      viewHeight: term.bounds.height, scale: scale
    )
    let cpuInner = bottomChrome.relayout(grid: grid)
    overlay.isHidden = false
    if let cell = cpuInner {
      overlay.frame = cell.insetBy(dx: 2, dy: 2)
    } else {
      overlay.frame = .zero
    }
    overlay.needsLayout = true
    overlay.layoutSubtreeIfNeeded()

    if let g = grid {
      let top = TuiTopLayout(cols: g.cols, rows: g.rows)
      graphStripes.place(grid: g, cells: [top.cpuLeft, top.cpuRight, top.ram, top.gpu])
      // Text button on the RAM box title row, just left of the right-aligned
      // " SWAP x.xx / y.y GB " title (20 cells, ends 1 cell before the corner).
      let ram = top.ram
      let swapStart = ram.col + ram.w - 1 - 20
      let bw = ramButton.widthInCells
      let bcol = swapStart - 1 - bw
      ramButton.font = g.font
      ramButton.baselineOffset = g.baselineOffset
      ramButton.cellW = g.cellW
      ramButton.frame = g.rect(col: bcol, row: ram.row, w: bw, h: 1)
      // Status text on the first row inside the box, right-aligned.
      let inner = ram.inner
      ramStatus.frame = g.rect(col: inner.col, row: inner.row, w: inner.w, h: 1)
      ramStatus.font = g.font
      ramStatus.baselineOffset = g.baselineOffset

      // macmon 0.7.2 mislabels clusters on macOS 27. Titles sit on the box
      // border: one leading space, then "X-CPU".
      placePatch(
        cpuLeftTitle, text: clusterFix.leftTitle, width: ClusterCorrection.boxTitleWidth,
        col: top.cpuLeft.col + 2, row: top.cpuLeft.row, grid: g
      )
      placePatch(
        cpuRightTitle, text: clusterFix.rightTitle, width: ClusterCorrection.boxTitleWidth,
        col: top.cpuRight.col + 2, row: top.cpuRight.row, grid: g
      )
      placePatch(
        cpuHeaderPatch, text: clusterFix.headerText, width: clusterFix.headerWidth,
        col: clusterFix.headerCol, row: top.outer.row, grid: g
      )
    } else {
      graphStripes.place(grid: nil, cells: [])
      ramButton.frame = .zero
      ramStatus.frame = .zero
      cpuLeftTitle.frame = .zero
      cpuRightTitle.frame = .zero
      cpuHeaderPatch.frame = .zero
    }
    _ = root
  }

  private func placePatch(_ patch: GridTextPatch, text: String?, width: Int, col: Int, row: Int, grid g: TerminalGrid) {
    guard let text, width > 0 else {
      patch.frame = .zero
      return
    }
    patch.font = g.font
    patch.baselineOffset = g.baselineOffset
    patch.text = text
    patch.frame = g.rect(col: col, row: row, w: width, h: 1)
  }

  private func freeRam() {
    guard !ramButton.busy else { return }
    ramButton.busy = true
    // Purge needs root: ask (once) for the helper; if declined, clean without it.
    helperSetup.ensureReady(reason: .purge, window: window) { [weak self] outcome in
      guard let self else { return }
      self.ramStatus.show("cleaning…", for: 30)
      RamCleaner.clean(purge: outcome == .ready) { [weak self] r in
        guard let self else { return }
        self.ramButton.busy = false
        let gb = Double(r.freedBytes) / 1_073_741_824
        var parts: [String] = []
        parts.append(gb >= 0.1 ? String(format: "freed %.1f GB", gb)
                                : String(format: "freed %.0f MB", Double(r.freedBytes) / 1_048_576))
        if !r.stopped.isEmpty {
          parts.append("\(r.stopped.count) background task\(r.stopped.count == 1 ? "" : "s") stopped")
        }
        if r.purged { parts.append("cache purged") }
        else if outcome != .ready { parts.append("purge skipped (no helper)") }
        self.ramStatus.show(parts.joined(separator: " · "))
      }
    }
  }

  private func startMetricsPipe() {
    guard let path = resourcePath("macmon10") else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    // Each callback is one full tick: fans + power + package/battery temps together.
    metricsPipe.onUpdate = { [weak self] m in
      guard let self else { return }
      // Drop identical samples (common when idle) to avoid needless AppKit work.
      if m == self.lastMetrics { return }
      self.lastMetrics = m
      let fans = m.fans
      if !self.sawFirstSample {
        self.sawFirstSample = true
        // Fanless Macs (MacBook Air): hide sliders, say so.
        let present = !fans.isEmpty
        self.fanOverlay?.hasFans = present
        self.fanMenu.overlay.hasFans = present
      }
      if fans.count > 0, fans[0].maxRpm > 0 { self.maxRpm0 = fans[0].maxRpm }
      if fans.count > 1, fans[1].maxRpm > 0 {
        self.maxRpm1 = fans[1].maxRpm
      } else if fans.count == 1, fans[0].maxRpm > 0 {
        self.maxRpm1 = fans[0].maxRpm
      }
      let manual0 = self.manual0 ? self.level0 : nil
      let manual1 = self.manual1 ? self.level1 : nil
      let tempC = m.displayTemp
      let dashboardUp = self.window?.isVisible == true
      // Skip heavy dashboard redraws when only the menu bar is alive.
      if dashboardUp {
        self.fanOverlay?.update(fans: fans, manual0: manual0, manual1: manual1, tempC: tempC)
        self.bottomChrome.update(m)
      }
      self.fanMenu.update(fans: fans, manual0: manual0, manual1: manual1, tempC: tempC)
    }
    metricsPipe.start(macmon10Path: path, intervalMs: MetricsCadence.dashboardMs)
  }

  /// After macmon handles `c` / `-` / `+`, re-read its config so overlays stay aligned.
  private func installMacmonKeySync() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      guard self.window?.isKeyWindow == true, self.window?.isVisible == true else { return event }
      let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      // Ctrl+C quits macmon; ⌘ shortcuts belong to the menu.
      if mods.contains(.control) || mods.contains(.command) || mods.contains(.option) {
        return event
      }
      guard let ch = event.charactersIgnoringModifiers, ch.count == 1 else { return event }
      switch ch {
      case "c", "C", "-", "+", "=":
        // macmon saves ~/.config/macmon.json after handling the key — sync after it writes.
        let bumpPipe = (ch == "-" || ch == "+" || ch == "=")
        for delay in [0.05, 0.15, 0.35] as [Double] {
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.applyMacmonConfigSync(restartPipe: bumpPipe)
          }
        }
      default:
        break
      }
      return event
    }
  }

  private func applyMacmonConfigSync(restartPipe: Bool) {
    let (colorChanged, interval) = OverlayTheme.syncFromMacmonConfig()
    if let interval {
      let prev = MetricsCadence.dashboardMs
      MetricsCadence.dashboardMs = interval
      let changed = interval != prev || MetricsCadence.intervalMs != interval
      if changed, window?.isVisible == true || restartPipe {
        bottomChrome.resetHistory()
        metricsPipe.setIntervalMs(interval)
      }
    }
    if colorChanged { refreshOverlayTheme() }
  }

  private func refreshOverlayTheme() {
    bottomChrome.applyTheme()
    fanOverlay?.applyTheme()
    fanMenu.overlay.applyTheme()
    ramButton.needsDisplay = true
    ramStatus.needsDisplay = true
    cpuLeftTitle.needsDisplay = true
    cpuRightTitle.needsDisplay = true
    cpuHeaderPatch.needsDisplay = true
  }

  /// Either surface (window or menu bar) moved a fan slider.
  private func userMovedSlider(index: Int, level: Double) {
    if index == 0 {
      level0 = level
      manual0 = level > 0.05
      fanOverlay?.slider0.applyExternal(level)
      fanMenu.overlay.slider0.applyExternal(level)
    } else {
      level1 = level
      manual1 = level > 0.05
      fanOverlay?.slider1.applyExternal(level)
      fanMenu.overlay.slider1.applyExternal(level)
    }
    scheduleFanWrite(index: index, level: level)
  }

  /// Debounced SMC write via the root fan helper. The first manual move asks
  /// the user to allow (install) the helper; declining snaps the slider back.
  private func scheduleFanWrite(index: Int, level: Double) {
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if level > 0.05, !self.helperSetup.isReady {
        self.helperSetup.ensureReady(reason: .fans, window: self.window) { [weak self] outcome in
          guard let self else { return }
          if outcome == .ready { self.performFanWrite(index: index, level: level) }
          else { self.revertSlider(index: index) }
        }
        return
      }
      self.performFanWrite(index: index, level: level)
    }
    if index == 0 {
      writeWork0?.cancel()
      writeWork0 = work
    } else {
      writeWork1?.cancel()
      writeWork1 = work
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }

  /// Main thread in, blocking socket work on a background queue.
  private func performFanWrite(index: Int, level: Double) {
    let maxR = Double(max(index == 0 ? maxRpm0 : maxRpm1, 1))
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      if level <= 0.05 {
        let ok = FanPrivileged.setAuto(fanIndex: index)
        log.info("fan\(index) auto ok=\(ok)")
        return
      }
      // Floor ~25% so Apple Silicon fans actually leave 0 RPM.
      let rpm = max(maxR * 0.25, min(maxR, level * maxR))
      let ok = FanPrivileged.setSpeed(fanIndex: index, rpm: rpm)
      log.info("fan\(index) set \(Int(rpm)) rpm ok=\(ok)")
      guard !ok else { return }
      // Helper vanished (removed / stopped)? Re-check and give the slider back.
      DispatchQueue.main.async {
        guard let self else { return }
        self.helperSetup.refreshState()
        self.revertSlider(index: index)
      }
    }
  }

  private func revertSlider(index: Int) {
    if index == 0 {
      level0 = 0; manual0 = false
      fanOverlay?.slider0.value = 0
      fanMenu.overlay.slider0.value = 0
    } else {
      level1 = 0; manual1 = false
      fanOverlay?.slider1.value = 0
      fanMenu.overlay.slider1.value = 0
    }
  }

  private func scheduleStart() {
    startAttempts += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self, let term = self.terminal else { return }
      if term.bounds.width < 80 || term.bounds.height < 40 {
        if self.startAttempts < 30 { self.scheduleStart() }
        return
      }
      self.startMacmon()
      self.relayoutOverlay()
    }
  }

  private func resourcePath(_ name: String) -> String? {
    let fm = FileManager.default
    let candidates: [URL?] = [
      Bundle.main.resourceURL?.appendingPathComponent(name),
      Bundle.module.url(forResource: name, withExtension: nil),
      Bundle.main.resourceURL?
        .appendingPathComponent("MacmonDash_MacmonDash.bundle")
        .appendingPathComponent(name),
    ]
    for case let url? in candidates where fm.fileExists(atPath: url.path) {
      return url.path
    }
    return nil
  }

  private func startMacmon() {
    guard let term = terminal, !started else { return }
    guard let path = resourcePath("macmon") else {
      term.feed(text: "\r\nmacmon binary missing\r\n")
      return
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

    var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
    env.removeAll { $0.hasPrefix("PATH=") || $0.hasPrefix("HOME=") }
    env.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
    env.append("HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)")
    env.append("TERM_PROGRAM=Apple_Terminal")
    env.append("COLORTERM=truecolor")

    started = true
    // Re-arm the metrics pipe with the TUI so Temp/Power share macmon’s clock
    // (same -i and a fresh start — avoids the pipe running ahead of the graphs).
    bottomChrome.resetHistory()
    metricsPipe.realign(intervalMs: MetricsCadence.dashboardMs)
    term.startProcess(
      executable: path,
      args: ["-i", "\(MetricsCadence.dashboardMs)"],
      environment: env,
      execName: "macmon"
    )
  }

  /// Keep the process alive for the menu-bar fan / temp when the dashboard closes.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showMainWindow(nil) }
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    pingTimer?.invalidate()
    if manual0 { FanPrivileged.setAutoSilently(fanIndex: 0) }
    if manual1 { FanPrivileged.setAutoSilently(fanIndex: 1) }
    terminal?.terminate()
    metricsPipe.stop()
  }

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
    // Never snap/resize the NSWindow to terminal cell size — that locked width.
    termCols = newCols
    termRows = newRows
    relayoutOverlay()
  }

  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    window?.title = title.isEmpty ? "MacmonDash" : title
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    started = false
    // 'q' in the TUI: hide the dashboard; menu-bar fans stay. Abnormal exit: show message.
    if exitCode == 0 || exitCode == nil {
      if window?.isVisible == true { window?.close() }
    } else if window?.isVisible == true {
      terminal?.feed(text: "\r\n\r\n[macmon exited (\(exitCode!))]\r\n")
    }
  }

  func processFailedToStart(source: TerminalView, error: LocalProcessError) {
    started = false
    terminal?.feed(text: "\r\nFailed to start macmon: \(error)\r\n")
  }
}
