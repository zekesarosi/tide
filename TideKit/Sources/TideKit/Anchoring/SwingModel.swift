import Foundation

/// The anchor rode and where the GPS antenna sits relative to the bow.
public struct AnchorSetup: Sendable, Hashable, Codable {
    /// Rode paid out from the bow roller to the anchor shackle, metres.
    public var rodeLength: Double
    /// Height of the bow roller above the waterline, metres.
    public var bowHeight: Double
    /// Horizontal distance from the bow roller aft to the GPS antenna, metres.
    public var antennaAftOfBow: Double
    /// Boat's draught, metres.
    public var draught: Double
    /// Submerged weight of the chain, newtons per metre (≈ 0.87 × 9.81 × mass per metre
    /// for steel). Nil for rope or when unknown: the model then assumes a straight rode.
    public var chainWeightPerMeter: Double?

    public init(rodeLength: Double, bowHeight: Double = 1, antennaAftOfBow: Double = 0, draught: Double = 1.8,
                chainWeightPerMeter: Double? = nil) {
        self.rodeLength = rodeLength
        self.bowHeight = bowHeight
        self.antennaAftOfBow = antennaAftOfBow
        self.draught = draught
        self.chainWeightPerMeter = chainWeightPerMeter
    }
}

/// Geometry of a boat lying to its anchor.
public enum SwingModel {
    /// Horizontal reach (metres) from the anchor to the bow roller with the rode straight
    /// and taut: √(L² − h²), where h is the drop from the roller to the seabed. This is the
    /// largest distance the bow can ever be from the anchor, so it sets the alarm circle.
    public static func tautReach(rodeLength l: Double, verticalDrop h: Double) -> Double {
        l > h ? (l * l - h * h).squareRoot() : 0
    }

    /// Horizontal reach of an all-chain rode as a catenary under horizontal load `force`
    /// (newtons) with submerged weight `weight` (N/m). Chain lying on the seabed counts in
    /// full; the suspended part follows y = a(cosh(x/a) − 1) with a = H/w.
    ///
    /// Returns the reach and whether the chain lifts off at the anchor (the pull is no
    /// longer horizontal there and the anchor may break out).
    public static func catenaryReach(rodeLength l: Double, verticalDrop h: Double,
                                     horizontalForce force: Double, weightPerMeter weight: Double) -> (reach: Double, liftsAnchor: Bool) {
        guard h > 0, weight > 0 else { return (l, false) }
        guard force > 0 else { return (max(0, l - h), false) }
        let a = force / weight
        let suspended = (h * h + 2 * a * h).squareRoot()
        if suspended <= l {
            return ((l - suspended) + a * asinh(suspended / a), false)
        }
        // All chain is off the bottom; past this point the line approaches straight. Use the
        // taut reach as the conservative bound.
        return (tautReach(rodeLength: l, verticalDrop: h), true)
    }

    /// Scope: rode length over the drop from bow roller to the seabed.
    public static func scope(rodeLength: Double, verticalDrop: Double) -> Double {
        verticalDrop > 0 ? rodeLength / verticalDrop : .infinity
    }
}

/// An anchoring over a tidal window: depths, swing radius and scope through the tide.
///
/// Depth is charted depth plus the predicted tide above chart datum, so the predictor
/// must output heights above the same datum the chart uses (MLLW on NOAA charts, LAT
/// elsewhere): build it with `meanLevel` = MSL above that datum.
public struct AnchorPlan: Sendable {
    public var anchor: GeoCoordinate
    public var setup: AnchorSetup
    /// Charted depth at the anchor, metres below chart datum (negative for drying heights).
    public var chartedDepth: Double
    public var window: DateInterval

    public struct Sample: Sendable, Hashable {
        public var date: Date
        /// Water depth at the anchor, metres.
        public var depth: Double
        /// Radius of the circle the GPS antenna can reach (taut rode), metres.
        public var swingRadius: Double
        public var scope: Double
    }

    /// Samples every 10 minutes over the window (a single sample when there is no tide).
    public let samples: [Sample]

    public init(anchor: GeoCoordinate, setup: AnchorSetup, chartedDepth: Double, window: DateInterval,
                tide: HarmonicPredictor?, interval: TimeInterval = 600) {
        self.anchor = anchor
        self.setup = setup
        self.chartedDepth = chartedDepth
        self.window = window
        func sample(_ t: Date, _ tide: Double) -> Sample {
            let depth = chartedDepth + tide
            let drop = depth + setup.bowHeight
            return Sample(date: t, depth: depth,
                          swingRadius: SwingModel.tautReach(rodeLength: setup.rodeLength, verticalDrop: drop) + setup.antennaAftOfBow,
                          scope: SwingModel.scope(rodeLength: setup.rodeLength, verticalDrop: drop))
        }
        if let tide {
            var pts = tide.heights(from: window.start, to: window.end, interval: interval).points.map { sample($0.date, $0.value) }
            // Include the exact high and low waters, where the extremes of depth occur.
            for e in tide.extrema(from: window.start, to: window.end) { pts.append(sample(e.date, e.height)) }
            samples = pts.sorted { $0.date < $1.date }
        } else {
            samples = [sample(window.start, 0)]
        }
    }

    public var minimumDepth: Double { samples.map(\.depth).min() ?? chartedDepth }
    public var maximumDepth: Double { samples.map(\.depth).max() ?? chartedDepth }
    /// Largest swing radius (at low water), metres: the radius to watch.
    public var maximumSwingRadius: Double { samples.map(\.swingRadius).max() ?? 0 }
    /// Smallest scope (at high water).
    public var minimumScope: Double { samples.map(\.scope).min() ?? .infinity }

    /// Water under the keel at the shallowest moment, metres. Negative means aground.
    public var minimumClearance: Double { minimumDepth - setup.draught }

    public enum Advisory: Sendable, Hashable {
        /// Scope at high water below the recommended minimum.
        case shortScope(minimum: Double, recommended: Double)
        /// Under-keel clearance at low water below the margin (metres).
        case shallowAtLowWater(clearance: Double)
    }

    /// Advisories for this anchoring: by default 5:1 scope for chain (7:1 rope) and 0.5 m
    /// under the keel. Swing room against other boats and hazards is the caller's job.
    public func advisories(recommendedScope: Double? = nil, minimumClearance margin: Double = 0.5) -> [Advisory] {
        var out: [Advisory] = []
        let recommended = recommendedScope ?? (setup.chainWeightPerMeter != nil ? 5 : 7)
        if minimumScope < recommended { out.append(.shortScope(minimum: minimumScope, recommended: recommended)) }
        if minimumClearance < margin { out.append(.shallowAtLowWater(clearance: minimumClearance)) }
        return out
    }
}
