import CoreGraphics
import Foundation
import Vision

/// The 6 geometry channels shared with python/lipspike/geometry.py. Keep the
/// definitions identical: templates recorded here are evaluated there.
///
///   width, outer_h, inner_h, outer_area, inner_area, jaw
///
/// Lengths are divided by the inter-ocular distance, areas by its square.
enum LipGeometry {
    static func polygonArea(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var s = 0.0
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }

    static func center(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
    }

    /// Returns nil when the observation lacks the regions we need.
    static func frame(from face: VNFaceObservation, imageSize: CGSize) -> [Double]? {
        guard let lm = face.landmarks,
              let outer = lm.outerLips?.pointsInImage(imageSize: imageSize),
              let inner = lm.innerLips?.pointsInImage(imageSize: imageSize),
              let leftEye = lm.leftEye?.pointsInImage(imageSize: imageSize),
              let rightEye = lm.rightEye?.pointsInImage(imageSize: imageSize),
              let contour = lm.faceContour?.pointsInImage(imageSize: imageSize),
              outer.count >= 3, inner.count >= 3, !leftEye.isEmpty, !rightEye.isEmpty, !contour.isEmpty
        else { return nil }

        let le = center(leftEye), re = center(rightEye)
        let iod = distance(le, re)
        guard iod > 1e-6 else { return nil }
        let eyeMid = CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
        // Chin = contour point farthest from the eye midpoint. Orientation-independent,
        // so Vision's bottom-left image origin does not matter.
        let chin = contour.max { distance(eyeMid, $0) < distance(eyeMid, $1) }!

        let xs = outer.map(\.x), ys = outer.map(\.y), iys = inner.map(\.y)
        return [
            Double(xs.max()! - xs.min()!) / iod,
            Double(ys.max()! - ys.min()!) / iod,
            Double(iys.max()! - iys.min()!) / iod,
            polygonArea(outer) / (iod * iod),
            polygonArea(inner) / (iod * iod),
            distance(eyeMid, chin) / iod,
        ]
    }
}
