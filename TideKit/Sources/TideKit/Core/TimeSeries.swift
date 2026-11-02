import Foundation

public struct TimeSeriesPoint: Sendable, Hashable, Codable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// A time-ordered series of scalar samples (water level in metres, pressure
/// in hPa, etc.). Points are kept sorted by date.
public struct TimeSeries: Sendable, Hashable, Codable {
    public private(set) var points: [TimeSeriesPoint]

    public init(points: [TimeSeriesPoint]) {
        self.points = points.sorted { $0.date < $1.date }
    }

    public init(dates: [Date], values: [Double]) {
        self.init(points: zip(dates, values).map(TimeSeriesPoint.init))
    }

    public static let empty = TimeSeries(points: [])

    public var isEmpty: Bool { points.isEmpty }
    public var count: Int { points.count }
    public var first: TimeSeriesPoint? { points.first }
    public var last: TimeSeriesPoint? { points.last }
    public var dates: [Date] { points.map(\.date) }
    public var values: [Double] { points.map(\.value) }

    public var range: ClosedRange<Date>? {
        guard let a = points.first?.date, let b = points.last?.date else { return nil }
        return a...b
    }

    /// Linear interpolation. Returns nil outside the series or across gaps
    /// longer than `maxGap`.
    public func value(at date: Date, maxGap: TimeInterval = 3 * 3_600) -> Double? {
        guard let firstDate = points.first?.date, let lastDate = points.last?.date,
              date >= firstDate, date <= lastDate else { return nil }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].date <= date { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        if a.date == date { return a.value }
        if b.date == date { return b.value }
        let span = b.date.timeIntervalSince(a.date)
        guard span > 0, span <= maxGap else { return nil }
        let w = date.timeIntervalSince(a.date) / span
        return a.value + w * (b.value - a.value)
    }

    public func sliced(from start: Date, to end: Date) -> TimeSeries {
        TimeSeries(points: points.filter { $0.date >= start && $0.date <= end })
    }

    public func mapValues(_ transform: (Double) -> Double) -> TimeSeries {
        TimeSeries(points: points.map { TimeSeriesPoint(date: $0.date, value: transform($0.value)) })
    }

    /// Sample onto a regular grid (aligned to `step` boundaries since 1970).
    public func resampled(step: TimeInterval, from start: Date? = nil, to end: Date? = nil,
                          maxGap: TimeInterval = 3 * 3_600) -> TimeSeries {
        guard let r = range else { return .empty }
        let s = start ?? r.lowerBound, e = end ?? r.upperBound
        var t = Date(timeIntervalSince1970: (s.timeIntervalSince1970 / step).rounded(.up) * step)
        var out: [TimeSeriesPoint] = []
        while t <= e {
            if let v = value(at: t, maxGap: maxGap) { out.append(.init(date: t, value: v)) }
            t += step
        }
        return TimeSeries(points: out)
    }

    /// Pointwise `self - other` on the dates of `self` (where `other` can be interpolated).
    public func subtracting(_ other: TimeSeries, maxGap: TimeInterval = 3 * 3_600) -> TimeSeries {
        TimeSeries(points: points.compactMap { p in
            other.value(at: p.date, maxGap: maxGap).map { TimeSeriesPoint(date: p.date, value: p.value - $0) }
        })
    }

    public func adding(_ other: TimeSeries, maxGap: TimeInterval = 3 * 3_600) -> TimeSeries {
        TimeSeries(points: points.compactMap { p in
            other.value(at: p.date, maxGap: maxGap).map { TimeSeriesPoint(date: p.date, value: p.value + $0) }
        })
    }

    public var maximum: TimeSeriesPoint? { points.max { $0.value < $1.value } }
    public var minimum: TimeSeriesPoint? { points.min { $0.value < $1.value } }
}

public enum TideExtremeKind: String, Sendable, Codable, Hashable {
    case high, low
}

public struct TideExtreme: Sendable, Hashable, Codable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var height: Double
    public var kind: TideExtremeKind

    public init(date: Date, height: Double, kind: TideExtremeKind) {
        self.date = date
        self.height = height
        self.kind = kind
    }
}

extension TimeSeries {
    /// Build a smooth curve from high/low events using cosine interpolation
    /// (the standard "rule of twelfths"-style approximation). Used for
    /// sources that publish only tidal events.
    public static func interpolating(extremes: [TideExtreme], step: TimeInterval = 600) -> TimeSeries {
        let ex = extremes.sorted { $0.date < $1.date }
        guard ex.count >= 2 else { return .empty }
        var out: [TimeSeriesPoint] = []
        for (a, b) in zip(ex, ex.dropFirst()) {
            let span = b.date.timeIntervalSince(a.date)
            guard span > 0 else { continue }
            var t = a.date
            while t < b.date {
                let x = t.timeIntervalSince(a.date) / span
                let v = a.height + (b.height - a.height) * (1 - cos(.pi * x)) / 2
                out.append(.init(date: t, value: v))
                t += step
            }
        }
        if let lastEx = ex.last { out.append(.init(date: lastEx.date, value: lastEx.height)) }
        return TimeSeries(points: out)
    }

    /// Local extrema of a regularly sampled curve, refined by parabolic fit.
    public func extrema(minimumSeparation: TimeInterval = 2 * 3_600) -> [TideExtreme] {
        guard points.count >= 3 else { return [] }
        var out: [TideExtreme] = []
        for i in 1..<(points.count - 1) {
            let a = points[i - 1], b = points[i], c = points[i + 1]
            let isMax = b.value > a.value && b.value >= c.value
            let isMin = b.value < a.value && b.value <= c.value
            guard isMax || isMin else { continue }
            // Parabolic refinement assuming equal spacing.
            let h = b.date.timeIntervalSince(a.date)
            let denom = a.value - 2 * b.value + c.value
            var dt = 0.0, v = b.value
            if denom != 0, abs(c.date.timeIntervalSince(b.date) - h) < 1 {
                let x = 0.5 * (a.value - c.value) / denom
                dt = x * h
                v = b.value - 0.25 * (a.value - c.value) * x
            }
            let e = TideExtreme(date: b.date + dt, height: v, kind: isMax ? .high : .low)
            if let prev = out.last, prev.kind == e.kind || e.date.timeIntervalSince(prev.date) < minimumSeparation {
                // Keep the more extreme of two close/duplicate extrema.
                if prev.kind == e.kind {
                    let better = (e.kind == .high) ? (e.height > prev.height) : (e.height < prev.height)
                    if better { out[out.count - 1] = e }
                }
                continue
            }
            out.append(e)
        }
        return out
    }
}
