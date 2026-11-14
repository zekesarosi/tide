import Foundation

/// The current (or tidal stream) triangle: water track, ground track and set/drift.
///
/// Conventions: every direction is degrees true. Speeds share whatever unit the caller
/// uses (knots or m/s). A current's **set** is the direction it flows *towards*;
/// **drift** is its speed. Leeway is the angle between heading and water track,
/// positive when the boat is pushed to starboard (wind on the port side).
public enum CurrentTriangle {
    public struct Solution: Sendable, Hashable {
        /// Heading to steer (true).
        public var heading: Double
        /// Resulting speed over the ground along the intended track.
        public var speedOverGround: Double
    }

    /// Heading to steer so that the ground track follows `course`, given speed through
    /// the water and the current. Returns nil when the cross-track component of the
    /// current exceeds the boat speed, or the boat would make no progress along the track.
    public static func courseToSteer(course: Double, speedThroughWater stw: Double,
                                     set: Double, drift: Double, leeway: Double = 0) -> Solution? {
        guard stw > 0 else { return nil }
        let current = ENUVector(direction: set, magnitude: drift)
        let track = ENUVector(direction: course, magnitude: 1)
        let right = ENUVector(direction: course + 90, magnitude: 1)
        let cross = current.dot(right), along = current.dot(track)
        // Water-track vector w (|w| = stw) must cancel the cross component.
        let s = -cross / stw
        guard abs(s) <= 1 else { return nil }
        let wAlong = stw * (1 - s * s).squareRoot()
        let sog = wAlong + along
        guard sog > 0 else { return nil }
        let waterTrack = Navigation.wrap360(course + asin(s) * 180 / .pi)
        return Solution(heading: Navigation.wrap360(waterTrack - leeway), speedOverGround: sog)
    }

    /// Ground track (course and speed over ground) from heading, speed through water
    /// and the current.
    public static func groundTrack(heading: Double, speedThroughWater stw: Double,
                                   set: Double, drift: Double, leeway: Double = 0) -> (course: Double, speed: Double) {
        let v = ENUVector(direction: heading + leeway, magnitude: stw) + ENUVector(direction: set, magnitude: drift)
        return (v.direction, v.magnitude)
    }

    /// Set and drift of the current from the water track (heading, speed through water)
    /// and the ground track (COG, SOG), e.g. from a log and a GPS.
    public static func setAndDrift(heading: Double, speedThroughWater stw: Double,
                                   courseOverGround cog: Double, speedOverGround sog: Double,
                                   leeway: Double = 0) -> (set: Double, drift: Double) {
        let v = ENUVector(direction: cog, magnitude: sog) - ENUVector(direction: heading + leeway, magnitude: stw)
        return (v.direction, v.magnitude)
    }
}

/// Speed made good and timing towards a destination.
public enum Passage {
    /// Velocity made good towards `bearing` (the component of the ground velocity along it).
    public static func velocityMadeGood(courseOverGround cog: Double, speedOverGround sog: Double,
                                        towardBearing bearing: Double) -> Double {
        sog * cos((cog - bearing) * .pi / 180)
    }

    /// Time (seconds) to cover `distance` metres at `speed` m/s; nil if not closing.
    public static func timeToGo(distance: Double, speed: Double) -> TimeInterval? {
        speed > 0 ? distance / speed : nil
    }

    /// Estimated time of arrival from `now`.
    public static func eta(distance: Double, speed: Double, from now: Date) -> Date? {
        timeToGo(distance: distance, speed: speed).map { now + $0 }
    }
}

/// A sequence of waypoints sailed as rhumb-line or great-circle legs.
public struct Route: Sendable, Hashable, Codable {
    public enum LegKind: String, Sendable, Hashable, Codable { case rhumbLine, greatCircle }

    public var waypoints: [GeoCoordinate]
    public var legKind: LegKind

    public init(waypoints: [GeoCoordinate], legKind: LegKind = .rhumbLine) {
        self.waypoints = waypoints
        self.legKind = legKind
    }

    public struct Leg: Sendable, Hashable {
        public var start: GeoCoordinate
        public var end: GeoCoordinate
        /// Metres.
        public var distance: Double
        /// Initial bearing, degrees true (constant along a rhumb-line leg).
        public var bearing: Double
    }

    public var legs: [Leg] {
        zip(waypoints, waypoints.dropFirst()).map { a, b in
            switch legKind {
            case .rhumbLine:
                let r = RhumbLine.inverse(from: a, to: b)
                return Leg(start: a, end: b, distance: r.distance, bearing: r.bearing)
            case .greatCircle:
                let g = Geodesy.inverse(from: a, to: b)
                return Leg(start: a, end: b, distance: g.distance, bearing: g.initialBearing)
            }
        }
    }

    /// Total length, metres.
    public var totalDistance: Double { legs.reduce(0) { $0 + $1.distance } }

    /// Where a boat at `position` is on leg `index`: cross-track error (metres, positive to
    /// starboard of the track), distance along the leg and distance remaining on it.
    public func progress(of position: GeoCoordinate, onLeg index: Int) -> (crossTrack: Double, along: Double, remaining: Double)? {
        let all = legs
        guard all.indices.contains(index) else { return nil }
        let leg = all[index]
        let sphericalXTE = GreatCircle.crossTrackDistance(of: position, from: leg.start, to: leg.end)
        // Scale the spherical along-track figure onto the leg's own (ellipsoidal) length.
        let sphere = GreatCircle.distance(from: leg.start, to: leg.end)
        let scale = sphere > 0 ? leg.distance / sphere : 1
        let along = GreatCircle.alongTrackDistance(of: position, from: leg.start, to: leg.end) * scale
        // The spherical figure is off by up to ~0.5 % (the sphere is not the ellipsoid), so
        // measure the offset on the ellipsoid from the foot of the perpendicular on the leg.
        let foot: GeoCoordinate
        switch legKind {
        case .rhumbLine: foot = RhumbLine.destination(from: leg.start, bearing: leg.bearing, distance: along)
        case .greatCircle: foot = Geodesy.direct(from: leg.start, bearing: leg.bearing, distance: along).coordinate
        }
        let offset = Geodesy.inverse(from: foot, to: position).distance
        let xte = sphericalXTE < 0 ? -offset : offset
        return (xte, along, max(0, leg.distance - along))
    }

    /// Distance remaining (metres) to the final waypoint from `position` on leg `index`.
    public func distanceRemaining(from position: GeoCoordinate, onLeg index: Int) -> Double? {
        guard let p = progress(of: position, onLeg: index) else { return nil }
        return p.remaining + legs.dropFirst(index + 1).reduce(0) { $0 + $1.distance }
    }
}
