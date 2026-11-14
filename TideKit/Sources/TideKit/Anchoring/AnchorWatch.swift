import Foundation

/// One GNSS fix as the phone or an NMEA source reports it.
public struct PositionFix: Sendable, Hashable {
    public var coordinate: GeoCoordinate
    /// Horizontal accuracy (one-sigma-ish radius), metres. Core Location's
    /// `horizontalAccuracy`, or HDOP × ~5 m for NMEA receivers.
    public var horizontalAccuracy: Double
    public var time: Date

    public init(coordinate: GeoCoordinate, horizontalAccuracy: Double, time: Date) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.time = time
    }
}

/// Anchor alarm: decides from a stream of noisy fixes whether the boat has left its swing
/// circle (dragging) or the position has been lost.
///
/// GPS noise on a phone is several metres and comes in bursts, and a single bad fix can
/// jump tens of metres; a naive "distance > radius" alarm goes off all night. So:
/// 1. fixes worse than `maximumAccuracy`, and fixes implying an impossible speed, are dropped;
/// 2. the position is the component-wise median of the fixes in the last `smoothing`
///    seconds, which ignores isolated spikes;
/// 3. the alarm needs that filtered position outside `radius + margin` continuously for
///    `dwell` seconds, where the margin grows with the reported accuracy.
/// A slower check catches an anchor creeping inside the circle: it compares how far from
/// the anchor the boat gets (90th percentile of distance) over the last `trendWindow`
/// with the window before. Swinging, even right round the circle when the tide turns,
/// leaves that reach unchanged; dragging grows it.
public struct AnchorWatch: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Fixes reporting worse accuracy than this are ignored, metres.
        public var maximumAccuracy: Double = 30
        /// Median window, seconds.
        public var smoothing: TimeInterval = 30
        /// How long the filtered position must stay outside before alarming, seconds.
        public var dwell: TimeInterval = 20
        /// Extra margin per metre of median reported accuracy (0.5: half the accuracy).
        public var accuracyMarginFactor: Double = 0.5
        /// Fixed extra margin, metres.
        public var fixedMargin: Double = 0
        /// No usable fix for this long raises `.gpsLost`, seconds.
        public var gpsTimeout: TimeInterval = 60
        /// Fixes implying more than this speed from the filtered position are spikes, m/s.
        public var maximumSpeed: Double = 5
        /// Window for the creep check, seconds.
        public var trendWindow: TimeInterval = 10 * 60
        /// Growth in reach between consecutive trend windows that raises a warning, metres.
        public var trendThreshold: Double = 8

        public init() {}
    }

    public enum Status: Sendable, Hashable {
        /// No fixes yet.
        case waiting
        case holding(distance: Double)
        /// Outside the circle but not yet for `dwell` seconds, or the swing centre is creeping.
        case warning(distance: Double, reason: WarningReason)
        case dragging(distance: Double, since: Date)
        case gpsLost(since: Date)

        public var isAlarm: Bool {
            switch self {
            case .dragging, .gpsLost: return true
            default: return false
            }
        }
    }

    public enum WarningReason: Sendable, Hashable {
        case outsideCircle
        /// The boat's reach from the anchor grew by this much (metres) in one trend window.
        case creeping(meters: Double)
    }

    public var anchor: GeoCoordinate
    /// Alarm radius around the anchor for the GPS antenna, metres (see `AnchorPlan`).
    public var radius: Double
    public var configuration: Configuration
    let plane: LocalTangentPlane

    struct Accepted { let p: ENUVector; let accuracy: Double; let time: Date }
    var recent: [Accepted] = []
    var trend: [Accepted] = []
    var outsideSince: Date?
    var lastAccepted: Date?
    var started: Date?
    var consecutiveSpikes = 0
    /// The creep check is slow-moving; it is recomputed at most every 10 s.
    var creepCache: (time: Date, value: Double?)?
    public private(set) var status: Status = .waiting
    /// Fixes rejected (accuracy or speed) since the watch started.
    public private(set) var rejectedFixes = 0

    public init(anchor: GeoCoordinate, radius: Double, configuration: Configuration = .init()) {
        self.anchor = anchor
        self.radius = radius
        self.configuration = configuration
        plane = LocalTangentPlane(origin: anchor)
    }

    /// The anchor position when it is let go at the bow: `antennaAftOfBow` metres ahead of
    /// the antenna along the heading.
    public static func anchorPosition(antenna: GeoCoordinate, heading: Double, antennaAftOfBow: Double) -> GeoCoordinate {
        Geodesy.direct(from: antenna, bearing: heading, distance: antennaAftOfBow).coordinate
    }

    /// Filtered (median) antenna position, if there are recent fixes.
    public var filteredPosition: GeoCoordinate? { median().map(plane.unproject) }

    func median() -> ENUVector? {
        guard !recent.isEmpty else { return nil }
        func med(_ v: [Double]) -> Double {
            let s = v.sorted(), n = s.count
            return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
        }
        return ENUVector(east: med(recent.map(\.p.east)), north: med(recent.map(\.p.north)))
    }

    /// Feeds a fix and returns the new status.
    @discardableResult
    public mutating func update(with fix: PositionFix) -> Status {
        if started == nil { started = fix.time }
        let c = configuration
        guard fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= c.maximumAccuracy, fix.coordinate.isValid else {
            rejectedFixes += 1
            return evaluate(at: fix.time)
        }
        let p = plane.project(fix.coordinate)
        if let m = median(), let last = recent.last {
            let dt = max(1, fix.time.timeIntervalSince(last.time))
            // Allow for the noise on both sides as well as real motion.
            let allowance = c.maximumSpeed * dt + 2 * max(fix.horizontalAccuracy, last.accuracy)
            if (p - m).magnitude > allowance && recent.count >= 3 && consecutiveSpikes < 5 {
                // Five "spikes" in a row are not spikes: the boat really moved (or the
                // window was stale), so start the window again from here.
                rejectedFixes += 1
                consecutiveSpikes += 1
                return evaluate(at: fix.time)
            }
            if consecutiveSpikes >= 5 { recent.removeAll() }
        }
        consecutiveSpikes = 0
        let a = Accepted(p: p, accuracy: fix.horizontalAccuracy, time: fix.time)
        recent.append(a)
        recent.removeAll { fix.time.timeIntervalSince($0.time) > c.smoothing }
        // The creep check only needs a sample every few seconds.
        if trend.last.map({ fix.time.timeIntervalSince($0.time) >= 5 }) ?? true {
            trend.append(a)
            if let first = trend.first, fix.time.timeIntervalSince(first.time) > 2 * c.trendWindow {
                trend.removeAll { fix.time.timeIntervalSince($0.time) > 2 * c.trendWindow }
            }
        }
        lastAccepted = fix.time
        return evaluate(at: fix.time)
    }

    /// Re-evaluates without a new fix (call on a timer so a silent GPS is noticed).
    @discardableResult
    public mutating func tick(at now: Date) -> Status { evaluate(at: now) }

    mutating func evaluate(at now: Date) -> Status {
        let c = configuration
        let reference = lastAccepted ?? started ?? now
        if now.timeIntervalSince(reference) > c.gpsTimeout {
            if case .gpsLost = status {} else { status = .gpsLost(since: reference) }
            return status
        }
        guard let m = median() else { status = .waiting; return status }
        let distance = m.magnitude
        let accuracies = recent.map(\.accuracy).sorted()
        let typical = accuracies[accuracies.count / 2]
        let limit = radius + c.fixedMargin + c.accuracyMarginFactor * typical
        if distance > limit {
            let since = outsideSince ?? now
            outsideSince = since
            if now.timeIntervalSince(since) >= c.dwell {
                if case let .dragging(_, s) = status { status = .dragging(distance: distance, since: s) } else {
                    status = .dragging(distance: distance, since: now)
                }
            } else {
                status = .warning(distance: distance, reason: .outsideCircle)
            }
            return status
        }
        outsideSince = nil
        if creepCache == nil || now.timeIntervalSince(creepCache!.time) >= 10 || now < creepCache!.time {
            creepCache = (now, reachGrowth(at: now))
        }
        if let creep = creepCache?.value, creep > c.trendThreshold {
            status = .warning(distance: distance, reason: .creeping(meters: creep))
        } else {
            status = .holding(distance: distance)
        }
        return status
    }

    /// Growth of the 90th-percentile distance from the anchor between the last two trend
    /// windows, if both are reasonably full.
    func reachGrowth(at now: Date) -> Double? {
        let w = configuration.trendWindow
        let newer = trend.filter { now.timeIntervalSince($0.time) <= w }
        let older = trend.filter { now.timeIntervalSince($0.time) > w }
        guard newer.count >= 10, older.count >= 10,
              let first = older.first, now.timeIntervalSince(first.time) >= 1.8 * w else { return nil }
        func reach(_ a: [Accepted]) -> Double {
            let d = a.map(\.p.magnitude).sorted()
            return d[min(d.count - 1, Int(0.9 * Double(d.count)))]
        }
        return reach(newer) - reach(older)
    }

    /// Least-squares circle (Kåsa fit) through positions recorded while lying to the
    /// anchor: the centre estimates where the anchor actually is when it wasn't marked,
    /// and the radius how much rode is really out. Needs a well-spread arc (the boat must
    /// have swung through at least ~90°); returns nil when the fit is ill-conditioned.
    public static func estimateAnchor(from positions: [GeoCoordinate]) -> (anchor: GeoCoordinate, radius: Double)? {
        guard positions.count >= 3 else { return nil }
        let plane = LocalTangentPlane(origin: positions[0])
        let pts = positions.map(plane.project)
        // Solve [x y 1]·[A B C]ᵀ = x² + y² in least squares; centre (A/2, B/2).
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0, n = 0.0
        var sxz = 0.0, syz = 0.0, sz = 0.0
        for p in pts {
            let x = p.east, y = p.north, z = x * x + y * y
            sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y; n += 1
            sxz += x * z; syz += y * z; sz += z
        }
        let m: [[Double]] = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        let rhs = [sxz, syz, sz]
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-10 * sxx * syy * n else { return nil } // collinear or coincident
        func replaced(_ col: Int) -> [[Double]] { m.enumerated().map { i, row in row.enumerated().map { j, v in j == col ? rhs[i] : v } } }
        let a = det(replaced(0)) / d, b = det(replaced(1)) / d, c = det(replaced(2)) / d
        let centre = ENUVector(east: a / 2, north: b / 2)
        let r2 = c + centre.dot(centre)
        guard r2 > 0 else { return nil }
        return (plane.unproject(centre), r2.squareRoot())
    }
}
