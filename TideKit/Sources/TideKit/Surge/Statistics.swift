import Foundation

enum LinearAlgebra {
    /// Solve A·x = b for symmetric positive (semi)definite A using Gaussian
    /// elimination with partial pivoting. Returns nil if singular.
    static func solve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard A.count == n, A.allSatisfy({ $0.count == n }) else { return nil }
        var m = A
        var y = b
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<max(n, col + 1) where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { m.swapAt(pivot, col); y.swapAt(pivot, col) }
            for r in (col + 1)..<max(n, col + 1) {
                let f = m[r][col] / m[col][col]
                if f == 0 { continue }
                for c in col..<n { m[r][c] -= f * m[col][c] }
                y[r] -= f * y[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = y[r]
            for c in (r + 1)..<max(n, r + 1) { s -= m[r][c] * x[c] }
            x[r] = s / m[r][r]
        }
        return x
    }

    /// Ridge regression on rows of features. Column 0 is assumed to be the
    /// intercept and is not penalised. Features are standardised internally.
    static func ridge(_ X: [[Double]], _ y: [Double], lambda: Double) -> [Double]? {
        guard let p = X.first?.count, !X.isEmpty, X.count == y.count else { return nil }
        let n = Double(X.count)
        var mean = [Double](repeating: 0, count: p), sd = [Double](repeating: 1, count: p)
        for j in 1..<max(p, 1) {
            let col = X.map { $0[j] }
            let m = col.reduce(0, +) / n
            let v = col.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n
            mean[j] = m
            sd[j] = v > 1e-18 ? v.squareRoot() : 1
        }
        var XtX = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var Xty = [Double](repeating: 0, count: p)
        var z = [Double](repeating: 0, count: p)
        for (row, target) in zip(X, y) {
            z[0] = 1
            for j in 1..<max(p, 1) { z[j] = (row[j] - mean[j]) / sd[j] }
            for a in 0..<p {
                Xty[a] += z[a] * target
                for b in a..<p { XtX[a][b] += z[a] * z[b] }
            }
        }
        for a in 0..<p { for b in 0..<a { XtX[a][b] = XtX[b][a] } }
        for j in 1..<max(p, 1) { XtX[j][j] += lambda * n }
        guard let w = solve(XtX, Xty) else { return nil }
        // Back-transform to raw feature space.
        var beta = [Double](repeating: 0, count: p)
        beta[0] = w[0]
        for j in 1..<max(p, 1) {
            beta[j] = w[j] / sd[j]
            beta[0] -= w[j] * mean[j] / sd[j]
        }
        return beta
    }
}

public enum Stats {
    public static func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }

    public static func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return .nan }
        let m = mean(x)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)
    }

    public static func rms(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
    }

    public static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    /// Lag-1 autocorrelation.
    public static func autocorrelation(_ x: [Double]) -> Double {
        guard x.count > 2 else { return 0 }
        let m = mean(x)
        var num = 0.0, den = 0.0
        for i in x.indices {
            den += (x[i] - m) * (x[i] - m)
            if i > 0 { num += (x[i] - m) * (x[i - 1] - m) }
        }
        return den > 0 ? num / den : 0
    }

    /// Standard normal CDF.
    public static func normalCDF(_ z: Double) -> Double { 0.5 * erfc(-z / 2.0.squareRoot()) }

    /// z-score for a central interval (e.g. 0.8 → 1.2816).
    public static func zForCentralInterval(_ p: Double) -> Double {
        // Bisection on the CDF; plenty accurate for display bands.
        let target = 0.5 + p / 2
        var lo = 0.0, hi = 6.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if normalCDF(mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

extension TimeSeries {
    /// Typical sample spacing (median), seconds.
    public var typicalSpacing: TimeInterval? {
        guard points.count > 2 else { return nil }
        return Stats.median(zip(points, points.dropFirst()).map { $1.date.timeIntervalSince($0.date) })
    }

    /// Hourly means centred on each whole hour (±30 min); requires at least
    /// `minSamples` samples per hour (default: half the expected count, so
    /// 5 for 6-minute data and 2 for 15-minute data).
    public func hourlyMeans(minSamples: Int? = nil) -> TimeSeries {
        let minSamples = minSamples ?? max(1, Int((0.5 * 3_600 / max(typicalSpacing ?? 360, 60)).rounded(.down)))
        var buckets: [Double: (sum: Double, n: Int)] = [:]
        for p in points {
            let hour = (p.date.timeIntervalSince1970 / 3_600).rounded() * 3_600
            var b = buckets[hour] ?? (0, 0)
            b.sum += p.value
            b.n += 1
            buckets[hour] = b
        }
        return TimeSeries(points: buckets.compactMap { k, v in
            v.n >= minSamples ? TimeSeriesPoint(date: Date(timeIntervalSince1970: k), value: v.sum / Double(v.n)) : nil
        })
    }
}
