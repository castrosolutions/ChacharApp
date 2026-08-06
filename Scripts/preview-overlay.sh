#!/usr/bin/env bash
# Render every state of the floating status overlay to PNGs, without launching the app.
#
# The overlay is the one piece of UI you can't inspect from a unit test and can't reach without
# dictating: `StatusOverlayView` is a pure function of (content, levels) precisely so it can be
# rendered offscreen like this. Use it when iterating on the pill's look.
#
# Usage: Scripts/preview-overlay.sh [outputDir]   (defaults to .build/overlay-preview)
#
# Caveat: SwiftUI materials have no backdrop to blur offscreen, so the pill's background renders
# flatter here than on screen. Layout, type, colour and the level meter are faithful.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.build/overlay-preview}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit
import SwiftUI

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])

/// A plausible speech envelope, so the meter is shown doing what it does in real use.
let speechLevels: [CGFloat] = (0..<27).map { i in
    let t = Double(i) / 26
    let syllables = abs(sin(t * 7)) * 0.75 + abs(sin(t * 17)) * 0.2
    return CGFloat(min(syllables * (0.35 + t * 0.65), 1))
}

let states: [(String, OverlayContent, [CGFloat])] = [
    ("1-listening", .listening, speechLevels),
    ("2-listening-quiet", .listening, Array(repeating: 0.02, count: 27)),
    ("3-transcribing", .working("Transcribing…"), []),
    ("4-cleaning-up", .working("Cleaning up…"), []),
    ("5-model-loading", .working("Loading the speech model…"), []),
    ("6-model-downloading", .progress("Downloading the speech model… 42%", 0.42), []),
    ("7-inserted", .notice("Inserted", .success), []),
    ("8-no-speech", .notice("No speech detected", .info), []),
    ("9-error", .notice("Could not open the microphone: no usable input device (it may still be switching — try again)", .failure), []),
]

// `ImageRenderer` is main-actor-isolated; top-level code runs on the main thread but the compiler
// can't see that, so state the fact once here.
@MainActor func renderAll() throws {
for (name, content, levels) in states {
    // A stand-in for "some app underneath", so contrast can be judged rather than guessed.
    let scene = ZStack {
        LinearGradient(colors: [Color(white: 0.97), Color(red: 0.83, green: 0.88, blue: 0.95)],
                       startPoint: .top, endPoint: .bottom)
        StatusOverlayView(content: content, levels: levels)
    }
    .frame(width: 560, height: 140)
    .environment(\.colorScheme, .dark)

    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    let url = outputDir.appending(path: "\(name).png")
    try png.write(to: url)
    print("wrote \(url.path)")
}
}

try MainActor.assumeIsolated { try renderAll() }
SWIFT

swiftc -swift-version 5 -O \
    "$ROOT/Sources/ChacharApp/Overlay/StatusOverlayView.swift" \
    "$WORK/main.swift" \
    -o "$WORK/preview"

"$WORK/preview" "$OUT"
