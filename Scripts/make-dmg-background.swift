#!/usr/bin/env swift
// Renders the DMG drag-install background (Field Instrument dark tokens).
// Usage: swift Scripts/make-dmg-background.swift <output.png>
// 660x420 pt at 2x (1320x840 px, 144 dpi) so Finder renders it Retina-crisp.
// Icon slots in create-dmg coords (top-left origin, icon centers):
//   Saaa.app at (170, 190), Applications drop link at (490, 190).
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let W: CGFloat = 660, H: CGFloat = 420, scale: CGFloat = 2

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

// Field Instrument dark tokens (theme/tokens.js).
let surfaceBase = color("#14171A")
let surfaceInset = color("#0F1114")
let borderHairline = color("#2B2F34")
let textPrimary = color("#E9EBED")
let textSecondary = color("#B6BCC2")
let emberLamp = color("#FF9F0A")
let tideEmphasis = color("#7CC1DB")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H) // 144 dpi
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Converts a design y (measured from the top) to AppKit's bottom-left origin.
func fromTop(_ y: CGFloat) -> CGFloat { H - y }

surfaceBase.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// Inset instrument panel frame.
let frame = NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: W - 24, height: H - 24), xRadius: 10, yRadius: 10)
surfaceInset.setFill()
frame.fill()
borderHairline.setStroke()
frame.lineWidth = 1
frame.stroke()

// Wordmark with the ember REC lamp dot.
let wordmark = NSAttributedString(string: "Saaa", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: textPrimary,
])
let wSize = wordmark.size()
let dotD: CGFloat = 8, gap: CGFloat = 12
let groupW = dotD + gap + wSize.width
let groupX = (W - groupW) / 2
let wordTop: CGFloat = 52
emberLamp.setFill()
NSBezierPath(ovalIn: NSRect(x: groupX, y: fromTop(wordTop + wSize.height / 2 + dotD / 2), width: dotD, height: dotD)).fill()
wordmark.draw(at: NSPoint(x: groupX + dotD + gap, y: fromTop(wordTop + wSize.height)))

// Drag arrow between the two icon slots (tide = interactive).
let arrowY = fromTop(190)
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 252, y: arrowY))
arrow.line(to: NSPoint(x: 404, y: arrowY))
arrow.move(to: NSPoint(x: 390, y: arrowY + 10))
arrow.line(to: NSPoint(x: 406, y: arrowY))
arrow.line(to: NSPoint(x: 390, y: arrowY - 10))
tideEmphasis.setStroke()
arrow.stroke()

// Caption.
let caption = NSAttributedString(string: "Drag Saaa into Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: textSecondary,
])
let cSize = caption.size()
caption.draw(at: NSPoint(x: (W - cSize.width) / 2, y: fromTop(338 + cSize.height)))

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(Int(W * scale))x\(Int(H * scale)) @144dpi)")
