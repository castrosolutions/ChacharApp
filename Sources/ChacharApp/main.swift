import AppKit

// ChacharApp menubar agent entry point. Top-level code in main.swift runs on the main actor
// (Swift 6), so building the AppKit app here is safe.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menubar agent: no Dock icon, no main window
app.run()
