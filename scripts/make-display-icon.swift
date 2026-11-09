// Production rendering of the approved D / Ring sun concept.
// swift scripts/make-display-icon.swift <repository-root>
// Reuse the original shell alpha, filling only its enclosed lightning cutout.
// The outer silhouette and framing remain identical to the existing art.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let art = root.appendingPathComponent("Resources/icon-src/menubar")
let resources = root.appendingPathComponent("Resources")

func render(source: URL, destination: URL, white: Bool) throws {
    let data = try Data(contentsOf: source)
    guard let bitmap = NSBitmapImageRep(data: data), let sourceImage = bitmap.cgImage else {
        fatalError("Cannot decode \(source.path)")
    }
    let w = sourceImage.width, h = sourceImage.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    try pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = buffer.bindMemory(to: UInt8.self)
        var exterior = [Bool](repeating: false, count: w * h)
        var queue = [Int]()
        func visit(_ i: Int) {
            if !exterior[i] && bytes[i * 4 + 3] < 128 {
                exterior[i] = true
                queue.append(i)
            }
        }
        for x in 0..<w { visit(x); visit((h - 1) * w + x) }
        for y in 0..<h { visit(y * w); visit(y * w + w - 1) }
        var index = 0
        while index < queue.count {
            let i = queue[index]; index += 1
            let x = i % w, y = i / w
            if x > 0 { visit(i - 1) }; if x + 1 < w { visit(i + 1) }
            if y > 0 { visit(i - w) }; if y + 1 < h { visit(i + w) }
        }
        var minX = w, maxX = 0, minY = h, maxY = 0
        for i in 0..<(w * h) where bytes[i * 4 + 3] >= 128 {
            minX = min(minX, i % w); maxX = max(maxX, i % w)
            minY = min(minY, i / w); maxY = max(maxY, i / w)
        }
        // Keep antialiased outer-edge pixels untouched. Fill only enclosed
        // pixels with no exterior neighbor (the original lightning aperture).
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let touchesOutside = (-1...1).contains { dy in
                    (-1...1).contains { dx in exterior[(y + dy) * w + x + dx] }
                }
                if !exterior[i] && !touchesOutside { bytes[i * 4 + 3] = 255 }
                let value: UInt8 = white ? bytes[i * 4 + 3] : 0
                bytes[i * 4] = value; bytes[i * 4 + 1] = value; bytes[i * 4 + 2] = value
            }
        }
        let width = CGFloat(maxX - minX + 1), height = CGFloat(maxY - minY + 1)
        let cx = CGFloat(minX) + width * 0.5
        // CGContext uses the opposite vertical origin to the bitmap row data.
        let cy = CGFloat(h) - (CGFloat(minY) + height * 0.47)
        let radius = width * 0.14
        context.setBlendMode(.clear)
        context.setLineWidth(width * 0.043)
        context.strokeEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                         width: radius * 2, height: radius * 2))
        context.setLineCap(.round)
        for ray in 0..<8 {
            let angle = CGFloat(ray) * .pi / 4
            let inner = width * 0.215, outer = width * 0.275
            context.move(to: CGPoint(x: cx + cos(angle) * inner, y: cy + sin(angle) * inner))
            context.addLine(to: CGPoint(x: cx + cos(angle) * outer, y: cy + sin(angle) * outer))
            context.strokePath()
        }
        let output = NSBitmapImageRep(cgImage: context.makeImage()!)
        try output.representation(using: .png, properties: [:])!.write(to: destination)
    }
}

for theme in ["light", "dark"] {
    try render(source: art.appendingPathComponent("clam.\(theme).on.bolt.png"),
               destination: art.appendingPathComponent("clam.\(theme).on.sun.png"), white: theme == "dark")
    // Use the already-bundled framing as well, so no existing asset needs
    // regeneration and the fourth glyph has exactly the same dimensions.
    try render(source: resources.appendingPathComponent("clam-bolt-\(theme).png"),
               destination: resources.appendingPathComponent("clam-sun-\(theme).png"), white: theme == "dark")
}
print("Generated D / Ring sun for both themes using the original shell masks")
