import AppKit

@main
enum MacmonDashMain {
  static func main() {
    let args = CommandLine.arguments

    // Root LaunchDaemon: listen for fan commands forever (no more password prompts).
    if args.count >= 2, args[1] == "--fan-daemon" {
      FanDaemon.run()
    }

    // One-time installer (run via osascript admin). Copies helper + starts daemon.
    if args.count >= 2, args[1] == "--install-fan-helper" {
      let src = Bundle.main.executablePath ?? args[0]
      exit(FanDaemon.install(fromExecutable: src))
    }

    // Uninstaller (run via osascript admin). Fans → auto, daemon + files removed.
    if args.count >= 2, args[1] == "--uninstall-fan-helper" {
      exit(FanDaemon.uninstall())
    }

    // Direct privileged SMC write (used by the daemon internally).
    if args.count >= 4, args[1] == "--smc-fan" {
      exit(FanHelperCLI.run(Array(args[2...])))
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }
}
