// Renders the app icon master PNG. Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: size - 200, height: size - 200)
let clip = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
clip.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor(red: 0.13, green: 0.16, blue: 0.30, alpha: 1),
                    NSColor(red: 0.36, green: 0.22, blue: 0.62, alpha: 1)])!.draw(in: clip, angle: -60)

// Dashed "sandbox" boundary
let inset = rect.insetBy(dx: 70, dy: 70)
let dash = NSBezierPath(roundedRect: inset, xRadius: 110, yRadius: 110)
dash.lineWidth = 14
dash.setLineDash([46, 30], count: 2, phase: 0)
NSColor.white.withAlphaComponent(0.45).setStroke()
dash.stroke()

// pi glyph
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 520, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para,
]
let str = NSAttributedString(string: "π", attributes: attrs)
let h = str.size().height
str.draw(in: NSRect(x: rect.minX, y: rect.midY - h / 2 - 10, width: rect.width, height: h))
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
