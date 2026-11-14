import Foundation

/// Position, velocity and the time they were valid: own ship or an AIS target.
public struct KinematicState: Sendable, Hashable {
    public var position: GeoCoordinate
    /// Knots.
    public var speedOverGround: Double
    /// Degrees true.
    public var courseOverGround: Double
    public var time: Date

    public init(position: GeoCoordinate, speedOverGround: Double, courseOverGround: Double, time: Date) {
        self.position = position
        self.speedOverGround = speedOverGround
        self.courseOverGround = courseOverGround
        self.time = time
    }

    /// Ground velocity, m/s east/north.
    public var velocity: ENUVector {
        ENUVector(direction: courseOverGround, magnitude: Navigation.metersPerSecond(fromKnots: speedOverGround))
    }

    /// Dead-reckoned along the ground track to `date` (rhumb line, constant course and speed).
    public func extrapolated(to date: Date) -> KinematicState {
        let dt = date.timeIntervalSince(time)
        guard dt != 0, speedOverGround > 0 else { return KinematicState(position: position, speedOverGround: speedOverGround, courseOverGround: courseOverGround, time: date) }
        let d = Navigation.metersPerSecond(fromKnots: speedOverGround) * dt
        let p = RhumbLine.destination(from: position, bearing: courseOverGround, distance: d)
        return KinematicState(position: p, speedOverGround: speedOverGround, courseOverGround: courseOverGround, time: date)
    }
}

/// Closest point of approach between two vessels holding course and speed.
public struct ClosestApproach: Sendable, Hashable {
    /// Seconds from `time` to the closest approach. Negative when the vessels are opening
    /// (the closest point is in the past); zero when there is no relative motion.
    public var timeToCPA: TimeInterval
    /// Distance at closest approach, metres (the current range when opening).
    public var distanceAtCPA: Double
    /// Range and true bearing from own ship to the target now, metres and degrees.
    public var range: Double
    public var bearing: Double
    /// The instant the geometry refers to.
    public var time: Date
    /// Positions of own ship and target at CPA (now, when opening).
    public var ownPositionAtCPA: GeoCoordinate
    public var targetPositionAtCPA: GeoCoordinate

    public var isClosing: Bool { timeToCPA > 0 }
}

/// CPA/TCPA in a local tangent plane centred on own ship.
///
/// With relative position r and relative velocity v (target minus own), the separation
/// |r + v t| is smallest at t* = −(r·v)/|v|². The plane is accurate to well under 0.1 %
/// over the 20–30 nm a collision assessment ever looks at.
public enum CollisionAvoidance {
    public static func closestApproach(own: KinematicState, target: KinematicState, at time: Date? = nil) -> ClosestApproach {
        let now = time ?? max(own.time, target.time)
        let o = own.extrapolated(to: now), t = target.extrapolated(to: now)
        let plane = LocalTangentPlane(origin: o.position)
        let r = plane.project(t.position)
        let v = t.velocity - o.velocity
        let v2 = v.dot(v)
        let tcpa = v2 < 1e-12 ? 0 : -r.dot(v) / v2
        let effective = max(0, tcpa)
        let sep = r + v * effective
        let ownAt = o.extrapolated(to: now + effective).position
        let tgtAt = t.extrapolated(to: now + effective).position
        return ClosestApproach(timeToCPA: tcpa, distanceAtCPA: sep.magnitude, range: r.magnitude,
                               bearing: r.direction, time: now, ownPositionAtCPA: ownAt, targetPositionAtCPA: tgtAt)
    }

    /// Alarm thresholds: a target is dangerous when it will pass within `cpaLimit` metres
    /// within `tcpaLimit` seconds.
    public struct Thresholds: Sendable, Hashable {
        public var cpaLimit: Double
        public var tcpaLimit: TimeInterval
        /// Targets farther than this are ignored, metres.
        public var maxRange: Double

        public init(cpaLimit: Double = Navigation.meters(fromNauticalMiles: 0.5),
                    tcpaLimit: TimeInterval = 20 * 60,
                    maxRange: Double = Navigation.meters(fromNauticalMiles: 20)) {
            self.cpaLimit = cpaLimit
            self.tcpaLimit = tcpaLimit
            self.maxRange = maxRange
        }
    }

    public enum Threat: Int, Sendable, Hashable, Comparable {
        case none = 0, distant, closing, dangerous
        public static func < (a: Threat, b: Threat) -> Bool { a.rawValue < b.rawValue }
    }

    public static func threat(of a: ClosestApproach, thresholds: Thresholds) -> Threat {
        guard a.range <= thresholds.maxRange else { return .distant }
        // Already inside the CPA ring counts as dangerous even if opening.
        if a.range <= thresholds.cpaLimit { return .dangerous }
        guard a.isClosing else { return .none }
        if a.distanceAtCPA <= thresholds.cpaLimit && a.timeToCPA <= thresholds.tcpaLimit { return .dangerous }
        return .closing
    }
}

/// Live AIS picture: merges position and static reports per MMSI and expires stale targets.
public struct AISTargetTable: Sendable {
    public struct Target: Sendable, Hashable, Identifiable {
        public var id: Int { mmsi }
        public var mmsi: Int
        public var name: String?
        public var callSign: String?
        public var imo: Int?
        public var shipType: Int?
        public var dimensions: AISMessage.Dimensions?
        public var destination: String?
        public var draught: Double?
        public var navigationStatus: AISMessage.NavigationStatus?
        public var isClassB: Bool = false
        public var isAidToNavigation: Bool = false
        public var isBaseStation: Bool = false
        public var isEmergencyDevice: Bool = false
        public var lastReport: AISMessage.PositionReport?
        public var position: GeoCoordinate?
        /// When the last position was received.
        public var positionTime: Date?
        public var lastHeard: Date

        /// Kinematics for CPA, if position, speed and course are all known.
        public var kinematics: KinematicState? {
            guard let p = position, let t = positionTime, let r = lastReport, let sog = r.speedOverGround else { return nil }
            let cog = r.courseOverGround ?? (sog < 0.1 ? 0 : nil)
            return cog.map { KinematicState(position: p, speedOverGround: sog, courseOverGround: $0, time: t) }
        }
    }

    public private(set) var targets: [Int: Target] = [:]
    /// Targets not heard from in this long are dropped (IMO: Class B at anchor reports
    /// every 3 minutes, static data every 6).
    public var expiry: TimeInterval = 10 * 60
    /// Positions older than this are not used for collision assessment.
    public var positionStaleAfter: TimeInterval = 3 * 60

    public init() {}

    public mutating func ingest(_ m: AISMessage, at now: Date) {
        var t = targets[m.mmsi] ?? Target(mmsi: m.mmsi, lastHeard: now)
        t.lastHeard = now
        t.isEmergencyDevice = m.isEmergencyDevice
        func merge(_ s: AISMessage.StaticData) {
            if let v = s.name, !v.isEmpty { t.name = v }
            if let v = s.callSign, !v.isEmpty { t.callSign = v }
            if let v = s.imo { t.imo = v }
            if let v = s.shipType, v != 0 { t.shipType = v }
            if let v = s.dimensions, v.isKnown { t.dimensions = v }
        }
        switch m.body {
        case let .position(r, staticData):
            t.lastReport = r
            t.isClassB = r.isClassB
            if let s = r.navigationStatus { t.navigationStatus = s }
            if let p = r.position { t.position = p; t.positionTime = now }
            if let s = staticData { merge(s) }
        case let .staticAndVoyage(s, v):
            merge(s)
            t.destination = v.destination
            t.draught = v.draught
        case let .staticDataReport(s):
            merge(s)
            t.isClassB = true
        case let .aidToNavigation(a):
            t.isAidToNavigation = true
            t.name = a.name
            if let p = a.position { t.position = p; t.positionTime = now }
            t.dimensions = a.dimensions
        case let .baseStation(_, p):
            t.isBaseStation = true
            if let p { t.position = p; t.positionTime = now }
        case .unsupported:
            break
        }
        targets[m.mmsi] = t
    }

    public mutating func expire(at now: Date) {
        targets = targets.filter { now.timeIntervalSince($0.value.lastHeard) <= expiry }
    }

    /// Moving targets with fresh positions, with their CPA against own ship, most
    /// threatening first (then by time to CPA).
    public func assess(own: KinematicState, at now: Date,
                       thresholds: CollisionAvoidance.Thresholds = .init()) -> [(target: Target, approach: ClosestApproach, threat: CollisionAvoidance.Threat)] {
        targets.values.compactMap { t -> (Target, ClosestApproach, CollisionAvoidance.Threat)? in
            guard !t.isAidToNavigation, !t.isBaseStation, let k = t.kinematics,
                  now.timeIntervalSince(k.time) <= positionStaleAfter else { return nil }
            let a = CollisionAvoidance.closestApproach(own: own, target: k, at: now)
            return (t, a, CollisionAvoidance.threat(of: a, thresholds: thresholds))
        }
        .sorted { a, b in
            if a.2 != b.2 { return a.2 > b.2 }
            return (a.1.isClosing ? a.1.timeToCPA : .infinity) < (b.1.isClosing ? b.1.timeToCPA : .infinity)
        }
        .map { (target: $0.0, approach: $0.1, threat: $0.2) }
    }
}
