import Foundation

/// Optional diagnostics: appends to ~/chachar-diag.log only when the env var CHACHARAPP_DEBUG is
/// set (off by default, so no disk writes during normal use).
public func chacharLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CHACHARAPP_DEBUG"] != nil else { return }
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("chachar-diag.log")
    guard let data = "\(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } else {
        try? data.write(to: url)
    }
}
