import AppKit

@MainActor
enum FinderTagPaletteImage {
  static func make(color: FinderTagColor, isSelected: Bool) -> NSImage {
    let fillColor = FinderTagPalette.nsColor(for: color)
    let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { bounds in
      fillColor.setFill()
      NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
      if isSelected {
        NSColor.white.setStroke()
        let check = NSBezierPath()
        check.lineWidth = 2
        check.move(to: NSPoint(x: 5, y: 10))
        check.line(to: NSPoint(x: 9, y: 6))
        check.line(to: NSPoint(x: 15, y: 14))
        check.stroke()
      }
      return true
    }
    image.isTemplate = false
    return image
  }
}
