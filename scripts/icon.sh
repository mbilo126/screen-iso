#!/usr/bin/env bash
# Renders assets/logo.svg into Resources/AppIcon.icns. The .icns is committed, so a normal build does not run this:
# run `make icon` again only when the logo changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/assets/logo.svg"
TARGET="${ROOT}/Resources/AppIcon.icns"

[[ -f "${SOURCE}" ]] || { echo "error: ${SOURCE} not found" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
iconset="${work}/AppIcon.iconset"
mkdir -p "${iconset}"

cat > "${work}/render.swift" <<'SWIFT'
import AppKit

// macOS icon grid: the artwork fills an 824 pt square centered on a 1024 pt canvas. An icon drawn edge to edge
// looks bigger than every other icon in the Finder.
let canvas: CGFloat = 1024
let artwork: CGFloat = 824

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: render <logo.svg> <iconset directory>") }
guard let image = NSImage(contentsOfFile: arguments[1]) else { fail("cannot read \(arguments[1])") }
let output = URL(fileURLWithPath: arguments[2])

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let side = CGFloat(variant.pixels)
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: variant.pixels, pixelsHigh: variant.pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { fail("cannot create a \(variant.pixels) px bitmap") }

    let inset = side * (canvas - artwork) / canvas / 2
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fail("cannot encode \(variant.name)")
    }
    do {
        try png.write(to: output.appendingPathComponent("\(variant.name).png"))
    } catch {
        fail("cannot write \(variant.name): \(error.localizedDescription)")
    }
}
SWIFT

swift "${work}/render.swift" "${SOURCE}" "${iconset}"
iconutil --convert icns --output "${TARGET}" "${iconset}"
echo "wrote ${TARGET}"
