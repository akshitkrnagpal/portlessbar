import AppKit
import CoreText

// Outline actual monospace glyphs so the SVG never depends on installed fonts.
func lettering(_ text: String, size: CGFloat) -> CGPath {
    let font = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    let path = CGMutablePath()
    var x: CGFloat = 0
    for (glyph, advance) in zip(glyphs, advances) {
        if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
            path.addPath(outline, transform: CGAffineTransform(translationX: x, y: 0))
        }
        x += advance.width
    }
    return path
}

func export(_ text: String, width: Int, height: Int, size: CGFloat, name: String) throws {
    let glyphs = lettering(text, size: size)
    let bounds = glyphs.boundingBoxOfPath
    let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                      tx: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                                      ty: (CGFloat(height) + bounds.height) / 2 + bounds.minY)
    let path = CGMutablePath()
    path.addPath(glyphs, transform: transform)
    func n(_ number: CGFloat) -> String { String(format: "%.3f", Double(number)) }
    func point(_ p: CGPoint) -> String { "\(n(p.x)) \(n(p.y))" }
    var commands = ""
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: commands += "M\(point(e.points[0]))"
        case .addLineToPoint: commands += "L\(point(e.points[0]))"
        case .addQuadCurveToPoint: commands += "Q\(point(e.points[0])) \(point(e.points[1]))"
        case .addCurveToPoint: commands += "C\(point(e.points[0])) \(point(e.points[1])) \(point(e.points[2]))"
        case .closeSubpath: commands += "Z"
        @unknown default: break
        }
    }
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
      <title>PortlessBar — \(text)</title>
      <desc>White Menlo monospace lettering on a full square-edged black canvas.</desc>
      <rect width="\(width)" height="\(height)" fill="#000"/>
      <path d="\(commands)" fill="#fff"/>
    </svg>
    """
    try svg.write(toFile: "Assets/\(name).svg", atomically: true, encoding: .utf8)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: width * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create canvas") }
    let cg = context.cgContext
    cg.setFillColor(NSColor.black.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
    cg.translateBy(x: 0, y: CGFloat(height))
    cg.scaleBy(x: 1, y: -1)
    cg.setFillColor(NSColor.white.cgColor)
    cg.addPath(path)
    cg.fillPath()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Assets/\(name).png"))
}

try export("p_", width: 1024, height: 1024, size: 570, name: "AppIcon")
try export("portlessbar", width: 1200, height: 260, size: 160, name: "Wordmark")
