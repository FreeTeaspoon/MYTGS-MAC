#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0-alpha.1}"
APP_PATH="${APP_PATH:-$ROOT_DIR/build/unsigned/Build/Products/Release/MYTGS.app}"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/build/dmg"
VOLNAME="MYTGS ${VERSION}"
RW_IMAGE="$WORK_DIR/MYTGS-${VERSION}.sparseimage"
DMG_PATH="$DIST_DIR/MYTGS-${VERSION}.dmg"
MOUNT_DIR="$WORK_DIR/mount"
BACKGROUND_PATH="$WORK_DIR/background.png"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
command -v hdiutil >/dev/null || fail "hdiutil is required."
command -v osascript >/dev/null || fail "osascript is required."
command -v swift >/dev/null || fail "swift is required."

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR" "$MOUNT_DIR"

swift - "$BACKGROUND_PATH" <<'SWIFT'
import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 720, height: 440)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
defer { NSGraphicsContext.restoreGraphicsState() }

let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
rect.fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.0, alpha: 1),
    NSColor.white
])!
gradient.draw(in: rect, angle: -18)

let topBand = NSBezierPath(roundedRect: NSRect(x: 34, y: 326, width: 652, height: 76), xRadius: 18, yRadius: 18)
NSColor.white.withAlphaComponent(0.72).setFill()
topBand.fill()
NSColor.black.withAlphaComponent(0.08).setStroke()
topBand.lineWidth = 1
topBand.stroke()

let title = "MYTGS"
let subtitle = "Drag MYTGS to Applications"
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

title.draw(
    in: NSRect(x: 0, y: 364, width: size.width, height: 28),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph
    ]
)

subtitle.draw(
    in: NSRect(x: 0, y: 338, width: size.width, height: 22),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph
    ]
)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 294, y: 218))
arrow.line(to: NSPoint(x: 426, y: 218))
arrow.lineWidth = 8
arrow.lineCapStyle = .round
NSColor.controlAccentColor.withAlphaComponent(0.88).setStroke()
arrow.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 426, y: 218))
head.line(to: NSPoint(x: 398, y: 238))
head.move(to: NSPoint(x: 426, y: 218))
head.line(to: NSPoint(x: 398, y: 198))
head.lineWidth = 8
head.lineCapStyle = .round
NSColor.controlAccentColor.withAlphaComponent(0.88).setStroke()
head.stroke()

let leftLabel = "1"
let rightLabel = "2"
for (label, x) in [(leftLabel, 178.0), (rightLabel, 542.0)] {
    let badge = NSBezierPath(ovalIn: NSRect(x: x - 12, y: 106, width: 24, height: 24))
    NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
    badge.fill()
    label.draw(
        in: NSRect(x: x - 12, y: 109, width: 24, height: 18),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
            .paragraphStyle: paragraph
        ]
    )
}

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to render DMG background")
}

try png.write(to: URL(fileURLWithPath: output))
SWIFT

hdiutil create \
    -size 96m \
    -fs APFS \
    -volname "$VOLNAME" \
    -type SPARSE \
    -ov \
    "$RW_IMAGE" >/dev/null

hdiutil attach "$RW_IMAGE" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
cleanup() {
    if mount | grep -q "$MOUNT_DIR"; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
}
trap cleanup EXIT

cp -R "$APP_PATH" "$MOUNT_DIR/MYTGS.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND_PATH" "$MOUNT_DIR/.background/background.png"

osascript <<APPLESCRIPT &
tell application "Finder"
    set dmgFolder to POSIX file "$MOUNT_DIR" as alias
    open dmgFolder
    set current view of container window of dmgFolder to icon view
    set toolbar visible of container window of dmgFolder to false
    set statusbar visible of container window of dmgFolder to false
    set bounds of container window of dmgFolder to {120, 120, 840, 560}
    set viewOptions to icon view options of container window of dmgFolder
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set background picture of viewOptions to POSIX file "$MOUNT_DIR/.background/background.png"
    set position of item "MYTGS.app" of dmgFolder to {180, 224}
    set position of item "Applications" of dmgFolder to {540, 224}
    update dmgFolder without registering applications
    delay 1
end tell
APPLESCRIPT
OSA_PID=$!
for _ in {1..20}; do
    if ! kill -0 "$OSA_PID" 2>/dev/null; then
        wait "$OSA_PID" || true
        break
    fi
    sleep 0.5
done
if kill -0 "$OSA_PID" 2>/dev/null; then
    kill "$OSA_PID" 2>/dev/null || true
    wait "$OSA_PID" 2>/dev/null || true
fi

SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || true
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force
trap - EXIT

rm -f "$DMG_PATH"
hdiutil convert "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
