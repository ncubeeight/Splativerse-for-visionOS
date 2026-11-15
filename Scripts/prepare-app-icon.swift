// Repackage the supplied flattened logo without redrawing or changing its artwork.
// Run from the repository root: swift Scripts/prepare-app-icon.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Distribution/Branding/SplativerseLogo.jpg")
let catalog = root.appendingPathComponent("Splativerse/Assets.xcassets/AppIcon.solidimagestack")
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func context() -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Cannot read Distribution/Branding/SplativerseLogo.jpg. Run from the repository root.\n", stderr)
    exit(1)
}
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let back = context()
back.interpolationQuality = .high
back.draw(original, in: bounds)
write(back.makeImage()!, to: catalog.appendingPathComponent("Back.solidimagestacklayer/Content.imageset/Back.png"))
// A flattened supplied logo has no separate depth artwork. Keep the upper
// catalog layers clear instead of retaining any of the previous placeholder.
for layer in ["Middle", "Front"] {
    write(context().makeImage()!, to: catalog.appendingPathComponent("\(layer).solidimagestacklayer/Content.imageset/\(layer).png"))
}
// Preview only: visionOS applies the circular mask to the actual icon itself.
let preview = context()
preview.addEllipse(in: bounds)
preview.clip()
preview.draw(back.makeImage()!, in: bounds)
write(preview.makeImage()!, to: root.appendingPathComponent("Distribution/Branding/AppIcon-preview.png"))
print("Prepared 1024px icon layers and circular preview from the supplied logo.")
