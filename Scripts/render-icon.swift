// Renders Packaging/AppIcon.svg into a macOS app icon: the artwork clipped to the standard rounded shape on a
// 1024 canvas with the usual margin and a soft shadow. Usage: render-icon <svg> <out.png> <pixels>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let art = NSImage(contentsOf: URL(fileURLWithPath: args[1])), let px = Int(args[3]) else {
    print("usage: render-icon <svg> <out.png> <pixels>"); exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let s = CGFloat(px) / 1024
let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

ctx.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 18 * s
shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
shadow.set()
NSColor(white: 0.03, alpha: 1).setFill()
shape.fill()
ctx.restoreGraphicsState()

ctx.saveGraphicsState()
shape.addClip()
art.draw(in: body)
ctx.restoreGraphicsState()

// A hairline so the dark icon stays visible on a dark Dock.
NSColor.white.withAlphaComponent(0.10).setStroke()
shape.lineWidth = max(1, 2 * s)
shape.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
