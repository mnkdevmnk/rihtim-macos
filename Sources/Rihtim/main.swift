import AppKit

/// Make sure the system ⌘⇥ comes back however the app exits, crashes included.
private func installHotKeyRestore() {
    let handler: @convention(c) (Int32) -> Void = { sig in
        SymbolicHotKeys.setCommandTabEnabled(true)
        signal(sig, SIG_DFL)
        raise(sig)
    }
    for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
        signal(sig, handler)
    }
    atexit { SymbolicHotKeys.setCommandTabEnabled(true) }
}

installHotKeyRestore()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
