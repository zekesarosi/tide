import Foundation

/// Source of the tidal stream along a passage: anything that gives a current vector
/// (knots east/north) at a position and time. A harmonic station, a mesh model
/// (`TideMesh`) or a constant all qualify.
public protocol CurrentField: Sendable {
    func current(at position: GeoCoordinate, time: Date) -> ENUVector
}

/// No current.
public struct NoCurrent: CurrentField {
    public init() {}
    public func current(at position: GeoCoordinate, time: Date) -> ENUVector { .zero }
}

/// One harmonic current station applied to everything (fine for a single gate such
/// as a strait or a harbour entrance).
public struct StationCurrentField: CurrentField {
    public let predictor: TidalCurrentPredictor
    public init(_ predictor: TidalCurrentPredictor) { self.predictor = predictor }
    public func current(at position: GeoCoordinate, time: Date) -> ENUVector { predictor.vector(at: time) }
}

/// Plans when to leave so that tidal gates are passed with a fair stream, and how long a
/// passage takes for a given departure.
///
/// The boat holds `speedThroughWater` and steers the course-to-steer that keeps it on
/// each rhumb-line leg (`CurrentTriangle`). Each leg can take its stream from its own
/// `CurrentField` (e.g. the station that governs that stretch).
public struct TidalGatePlanner: Sendable {
    public struct Leg: Sendable {
        public var start: GeoCoordinate
        public var end: GeoCoordinate
        public var current: any CurrentField
        public init(from start: GeoCoordinate, to end: GeoCoordinate, current: any CurrentField) {
            self.start = start; self.end = end; self.current = current
        }
    }

    /// A constraint on the moment the boat passes a waypoint (the end of a leg).
    public struct Gate: Sendable {
        public enum Rule: Sendable {
            /// Current at the gate, along the leg arriving there, must be at least this
            /// many knots (0: not foul; negative: tolerate that much foul stream).
            case minimumFairCurrent(Double)
            /// Speed of the stream at the gate must not exceed this (knots), e.g. near slack.
            case maximumStream(Double)
            /// Arrive inside this window (e.g. daylight, a bridge opening, a lock).
            case window(DateInterval)
        }
        /// Index of the leg whose end is the gate.
        public var legIndex: Int
        public var rule: Rule
        public var name: String?
        public init(atEndOfLeg legIndex: Int, _ rule: Rule, name: String? = nil) {
            self.legIndex = legIndex; self.rule = rule; self.name = name
        }
    }

    public struct LegResult: Sendable, Hashable {
        public var start: Date
        public var end: Date
        /// Metres.
        public var distance: Double
        /// Mean speed over ground, knots.
        public var averageSpeedOverGround: Double { Navigation.knots(fromMetersPerSecond: distance / end.timeIntervalSince(start)) }
        /// Stream along the leg at its end, knots (positive fair).
        public var currentAlongAtEnd: Double
        /// Speed of the stream at the end, knots.
        public var streamAtEnd: Double
        /// Heading steered at the start of the leg, degrees true.
        public var initialHeading: Double
    }

    public struct Plan: Sendable, Hashable {
        public var departure: Date
        public var arrival: Date
        public var legs: [LegResult]
        /// Indices into `gates` of the gates this plan fails.
        public var violatedGates: [Int]
        public var duration: TimeInterval { arrival.timeIntervalSince(departure) }
        public var isFeasible: Bool { violatedGates.isEmpty }
    }

    public enum PlanError: Error, Sendable, Hashable {
        /// The stream stops the boat (or sets it off a leg it can't hold) on this leg.
        case cannotMakeGood(legIndex: Int, at: Date)
        case noLegs
    }

    public var legs: [Leg]
    public var gates: [Gate]
    /// Knots.
    public var speedThroughWater: Double
    /// Integration step, seconds.
    public var step: TimeInterval = 60

    public init(legs: [Leg], gates: [Gate] = [], speedThroughWater: Double) {
        self.legs = legs
        self.gates = gates
        self.speedThroughWater = speedThroughWater
    }

    /// Simulates the passage leaving at `departure`.
    public func simulate(departure: Date) throws -> Plan {
        guard !legs.isEmpty else { throw PlanError.noLegs }
        var t = departure
        var results: [LegResult] = []
        for (i, leg) in legs.enumerated() {
            let rl = RhumbLine.inverse(from: leg.start, to: leg.end)
            let course = rl.bearing
            var done = 0.0
            let legStart = t
            var firstHeading: Double?
            var stalled: TimeInterval = 0
            while done < rl.distance {
                let here = RhumbLine.destination(from: leg.start, bearing: course, distance: done)
                let c = leg.current.current(at: here, time: t)
                guard let s = CurrentTriangle.courseToSteer(course: course, speedThroughWater: speedThroughWater,
                                                            set: c.direction, drift: c.magnitude) else {
                    // Foul stream stronger than the boat: wait it out (anchor or stem it),
                    // up to a tidal half-cycle; beyond that the leg can't be made good.
                    stalled += step
                    if stalled > 7 * 3_600 { throw PlanError.cannotMakeGood(legIndex: i, at: t) }
                    t += step
                    continue
                }
                if firstHeading == nil { firstHeading = s.heading }
                let v = Navigation.metersPerSecond(fromKnots: s.speedOverGround)
                let remaining = rl.distance - done
                if v * step >= remaining {
                    t += remaining / v
                    done = rl.distance
                } else {
                    done += v * step
                    t += step
                }
            }
            let c = leg.current.current(at: leg.end, time: t)
            results.append(LegResult(start: legStart, end: t, distance: rl.distance,
                                     currentAlongAtEnd: c.dot(ENUVector(direction: course, magnitude: 1)),
                                     streamAtEnd: c.magnitude, initialHeading: firstHeading ?? course))
        }
        let violated = gates.indices.filter { !satisfies(gates[$0], results) }
        return Plan(departure: departure, arrival: t, legs: results, violatedGates: violated)
    }

    func satisfies(_ g: Gate, _ legs: [LegResult]) -> Bool {
        guard legs.indices.contains(g.legIndex) else { return false }
        let l = legs[g.legIndex]
        switch g.rule {
        case .minimumFairCurrent(let v): return l.currentAlongAtEnd >= v
        case .maximumStream(let v): return l.streamAtEnd <= v
        case .window(let w): return w.contains(l.end)
        }
    }

    public enum Objective: Sendable, Hashable {
        /// Shortest time under way.
        case shortestPassage
        /// Earliest arrival.
        case earliestArrival
    }

    /// Departures every `interval` across `window`, best first: feasible plans before
    /// infeasible ones, then by the objective. Legs that can't be made good are skipped.
    public func departures(in window: DateInterval, every interval: TimeInterval = 15 * 60,
                           objective: Objective = .shortestPassage) -> [Plan] {
        var plans: [Plan] = []
        var t = window.start
        while t <= window.end {
            if let p = try? simulate(departure: t) { plans.append(p) }
            t += interval
        }
        return plans.sorted { a, b in
            if a.isFeasible != b.isFeasible { return a.isFeasible }
            switch objective {
            case .shortestPassage: return a.duration != b.duration ? a.duration < b.duration : a.departure < b.departure
            case .earliestArrival: return a.arrival < b.arrival
            }
        }
    }

    /// The best departure in `window`, refined to within a minute around the best
    /// coarse candidate.
    public func bestDeparture(in window: DateInterval, objective: Objective = .shortestPassage) -> Plan? {
        guard let coarse = departures(in: window, every: 15 * 60, objective: objective).first else { return nil }
        let lo = max(window.start, coarse.departure - 15 * 60), hi = min(window.end, coarse.departure + 15 * 60)
        return departures(in: DateInterval(start: lo, end: hi), every: 60, objective: objective).first ?? coarse
    }
}
