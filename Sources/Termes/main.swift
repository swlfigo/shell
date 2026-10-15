import AppKit

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate  // NSApplication.delegate is weak; `delegate` stays alive because run() never returns
  app.setActivationPolicy(.regular)
  app.activate(ignoringOtherApps: true)
  app.run()
}
