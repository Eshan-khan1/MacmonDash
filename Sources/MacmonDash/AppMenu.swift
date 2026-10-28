import AppKit

/// Builds the standard macOS menu bar programmatically (no storyboard/nib).
/// Without this, ⌘Q / ⌘W / ⌘H and the About panel do not exist.
enum AppMenu {
  static let repoURL = URL(string: "https://github.com/Eshan-khan1/MacmonDash")!

  static func install(target: AnyObject) {
    let main = NSMenu()

    // MacmonDash
    let appItem = NSMenuItem()
    let app = NSMenu(title: "MacmonDash")
    app.addItem(withTitle: "About MacmonDash", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
    app.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
    app.addItem(.separator())
    let helperInstall = NSMenuItem(title: "Install Fan Helper…", action: #selector(AppDelegate.installHelper(_:)), keyEquivalent: "")
    helperInstall.tag = MenuTag.installHelper.rawValue
    app.addItem(helperInstall)
    let helperRemove = NSMenuItem(title: "Remove Fan Helper…", action: #selector(AppDelegate.removeHelper(_:)), keyEquivalent: "")
    helperRemove.tag = MenuTag.removeHelper.rawValue
    app.addItem(helperRemove)
    app.addItem(withTitle: "Fan Helper Status", action: #selector(AppDelegate.helperStatus(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Hide MacmonDash", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    // Parks to the menu-bar temp icon (real Quit is on the status-item menu).
    app.addItem(withTitle: "Quit MacmonDash", action: #selector(AppDelegate.parkToMenuBar(_:)), keyEquivalent: "q")
    appItem.submenu = app
    main.addItem(appItem)

    // Fans
    let fansItem = NSMenuItem()
    let fans = NSMenu(title: "Fans")
    fans.addItem(withTitle: "All Fans Automatic", action: #selector(AppDelegate.allFansAuto(_:)), keyEquivalent: "0")
    fansItem.submenu = fans
    main.addItem(fansItem)

    // Window
    let windowItem = NSMenuItem()
    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Show Dashboard", action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "1")
    window.addItem(.separator())
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = window
    main.addItem(windowItem)
    NSApp.windowsMenu = window

    // Help
    let helpItem = NSMenuItem()
    let help = NSMenu(title: "Help")
    help.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
    help.addItem(.separator())
    help.addItem(withTitle: "MacmonDash on GitHub", action: #selector(AppDelegate.openRepo(_:)), keyEquivalent: "")
    help.addItem(withTitle: "Report an Issue", action: #selector(AppDelegate.openIssues(_:)), keyEquivalent: "")
    helpItem.submenu = help
    main.addItem(helpItem)
    NSApp.helpMenu = help

    app.delegate = target as? NSMenuDelegate
    NSApp.mainMenu = main
  }

  enum MenuTag: Int {
    case installHelper = 101
    case removeHelper = 102
  }
}
