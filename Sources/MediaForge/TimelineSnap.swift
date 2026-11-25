import Foundation

enum TimelineSnap {
    struct Match {
        let position: Double
        let guide: Double
    }

    static func nearest(position: Double, edges: [Double], anchors: [Double], within range: ClosedRange<Double>,
                        tolerance: Double) -> Match? {
        var best: Match?
        var distance = tolerance
        for edge in edges {
            for anchor in anchors {
                let candidate = anchor - edge
                let delta = abs(candidate - position)
                if range.contains(candidate), delta <= distance {
                    best = Match(position: candidate, guide: anchor)
                    distance = delta
                }
            }
        }
        return best
    }
}
