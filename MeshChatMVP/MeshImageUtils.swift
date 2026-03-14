import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Resize + JPEG compress so chunked send stays small (BitChat-style processing, tuned for 512B BLE envelopes).
enum MeshImageUtils {
    /// Raw JPEG byte cap after compression (chunked; keep modest for relay latency).
    static let maxJPEGBytes = 12 * 1024
    private static let maxDimension: CGFloat = 320
    private static let maxSourceBytes = 8 * 1024 * 1024

    static func jpegDataForMesh(from image: UIImage) throws -> Data {
        let scaled = scale(image, maxSide: maxDimension)
        guard let cg = scaled.cgImage else { throw MeshImageError.encodeFailed }
        var q: CGFloat = 0.72
        var data = encodeJPEG(cg, quality: q)
        while let d = data, d.count > maxJPEGBytes, q > 0.28 {
            q -= 0.08
            data = encodeJPEG(cg, quality: q)
        }
        guard let final = data, !final.isEmpty, final.count <= maxJPEGBytes else {
            throw MeshImageError.tooLarge
        }
        return final
    }

    static func jpegDataForMesh(at url: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let n = attrs[.size] as? Int, n <= maxSourceBytes else { throw MeshImageError.invalid }
        let raw = try Data(contentsOf: url)
        guard let img = UIImage(data: raw) else { throw MeshImageError.invalid }
        return try jpegDataForMesh(from: img)
    }

    private static func scale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let side = max(w, h)
        guard side > maxSide else { return image }
        let s = maxSide / side
        let newSize = CGSize(width: w * s, height: h * s)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out ?? image
    }

    private static func encodeJPEG(_ cg: CGImage, quality: CGFloat) -> Data? {
        guard let buf = CFDataCreateMutable(nil, 0) else { return nil }
        guard let dest = CGImageDestinationCreateWithData(buf, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buf as Data
    }
}

enum MeshImageError: Error {
    case invalid
    case encodeFailed
    case tooLarge
}
