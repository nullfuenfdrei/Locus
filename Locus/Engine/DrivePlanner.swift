import CoreLocation
import Foundation

/// A route turned into a realistic speed profile: speed limits, slowing for curves,
/// accelerating / braking smoothly, and stopping at traffic lights and stop signs.
struct DrivePlan {
    enum Stop: Equatable {
        case redLight(wait: TimeInterval)
        case stopSign(wait: TimeInterval)
    }

    let mode: TravelMode
    let points: [CLLocationCoordinate2D]
    /// Distance (m) from the start to each point.
    let cumulative: [Double]
    /// Target speed (m/s) at each point after physics.
    let speeds: [Double]
    /// Posted limit (m/s) at each point, if known.
    let limits: [CLLocationSpeed?]
    /// Planned stops by point index.
    let stops: [Int: Stop]
    /// Traffic lights on the route (red or green).
    let signalCount: Int
    let stopSignCount: Int
    let usedRoadData: Bool
    /// Seconds remaining from each point to the end (incl. stop waits).
    let timeToEnd: [TimeInterval]

    var totalDistance: Double { cumulative.last ?? 0 }
    var estimatedDuration: TimeInterval { timeToEnd.first ?? 0 }

    /// Index of the last point at or before `distance`.
    func index(at distance: Double) -> Int {
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func coordinate(at distance: Double) -> CLLocationCoordinate2D {
        let i = index(at: distance)
        guard i < points.count - 1 else { return points[points.count - 1] }
        let span = cumulative[i + 1] - cumulative[i]
        let t = span > 0 ? (distance - cumulative[i]) / span : 0
        let a = points[i], b = points[i + 1]
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    func speed(at distance: Double) -> Double {
        let i = index(at: distance)
        guard i < points.count - 1 else { return speeds[speeds.count - 1] }
        let span = cumulative[i + 1] - cumulative[i]
        let t = span > 0 ? (distance - cumulative[i]) / span : 0
        return speeds[i] + (speeds[i + 1] - speeds[i]) * t
    }

    func heading(at distance: Double) -> Double {
        let i = min(index(at: distance), points.count - 2)
        let j = min(points.count - 1, i + 3)
        return DrivePlanner.bearing(points[i], points[max(j, i + 1)])
    }

    func timeRemaining(from distance: Double) -> TimeInterval {
        let i = index(at: distance)
        guard i < points.count - 1 else { return 0 }
        let span = cumulative[i + 1] - cumulative[i]
        let t = span > 0 ? (distance - cumulative[i]) / span : 0
        return timeToEnd[i] + (timeToEnd[i + 1] - timeToEnd[i]) * t
    }
}

enum DrivePlanner {
    static let spacing: Double = 5

    /// Builds a plan. With `followRules`, speed limits and traffic controls come from OpenStreetMap.
    static func plan(route: [CLLocationCoordinate2D], mode: TravelMode, followRules: Bool) async -> DrivePlan {
        let points = RouteBuilder.sample(coordinates: dedupe(route), every: spacing)
        let rules: RoadRules
        if followRules && points.count >= 2 {
            rules = await RoadRulesService.fetch(for: points, mode: mode)
        } else {
            rules = .empty(count: points.count)
        }
        return build(points: points, mode: mode, rules: rules, followRules: followRules)
    }

    static func build(points: [CLLocationCoordinate2D], mode: TravelMode, rules: RoadRules, followRules: Bool) -> DrivePlan {
        let n = points.count
        var cumulative = [Double](repeating: 0, count: n)
        for i in 1..<max(n, 1) {
            cumulative[i] = cumulative[i - 1] + distance(points[i - 1], points[i])
        }

        let physics = Physics(mode: mode)
        // Each trip gets its own "driver": slightly under the limit, never over it.
        let driverFactor = Double.random(in: 0.92...0.99)
        let wobblePhase = Double.random(in: 0...(2 * .pi))
        let wobbleLength = Double.random(in: 300...600)

        var speeds = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var target: Double
            if mode == .drive {
                let limit = (followRules ? rules.limits[i] : nil) ?? physics.cruise
                target = limit * driverFactor
            } else {
                target = physics.cruise * Double.random(in: 0.97...1.03)
                if let limit = rules.limits[i] { target = min(target, limit) }
            }
            // Gentle natural speed changes on straight roads.
            target *= 1 + 0.025 * sin(cumulative[i] / wobbleLength * 2 * .pi + wobblePhase)
            if mode == .drive, followRules, let limit = rules.limits[i] {
                target = min(target, limit)
            }
            target = min(target, curveLimit(points: points, at: i, lateral: physics.lateral))
            speeds[i] = max(target, 0.5)
        }

        // Traffic controls.
        var stops: [Int: DrivePlan.Stop] = [:]
        if followRules {
            for i in rules.trafficSignals {
                if Double.random(in: 0...1) < 0.45 {
                    stops[i] = .redLight(wait: Double.random(in: 8...40))
                } else if mode == .drive {
                    // Green light: no stop, but no full speed through the junction either.
                    speeds[i] = min(speeds[i], 50 / 3.6)
                }
            }
            if mode == .drive || mode == .cycle {
                for i in rules.stopSigns {
                    stops[i] = .stopSign(wait: Double.random(in: 2...4))
                }
                for i in rules.giveWays {
                    speeds[i] = min(speeds[i], (mode == .drive ? 15 : 10) / 3.6)
                }
            }
        }
        for i in stops.keys { speeds[i] = 0 }
        if n > 0 {
            speeds[0] = 0
            speeds[n - 1] = 0
        }

        // Smooth acceleration (forward) and braking (backward).
        if n > 1 {
            for i in 1..<n where speeds[i] > speeds[i - 1] {
                let ds = cumulative[i] - cumulative[i - 1]
                speeds[i] = min(speeds[i], sqrt(speeds[i - 1] * speeds[i - 1] + 2 * physics.accel * ds))
            }
            for i in stride(from: n - 2, through: 0, by: -1) where speeds[i] > speeds[i + 1] {
                let ds = cumulative[i + 1] - cumulative[i]
                speeds[i] = min(speeds[i], sqrt(speeds[i + 1] * speeds[i + 1] + 2 * physics.decel * ds))
            }
        }

        // Time to the end from each point (used for ETA).
        var timeToEnd = [TimeInterval](repeating: 0, count: n)
        if n > 1 {
            for i in stride(from: n - 2, through: 0, by: -1) {
                let ds = cumulative[i + 1] - cumulative[i]
                let v = max(0.7, (speeds[i] + speeds[i + 1]) / 2)
                var wait: TimeInterval = 0
                switch stops[i + 1] {
                case .redLight(let w)?, .stopSign(let w)?: wait = w
                case nil: break
                }
                timeToEnd[i] = timeToEnd[i + 1] + ds / v + wait
            }
        }

        return DrivePlan(
            mode: mode,
            points: points,
            cumulative: cumulative,
            speeds: speeds,
            limits: rules.limits,
            stops: stops,
            signalCount: rules.trafficSignals.count,
            stopSignCount: rules.stopSigns.count,
            usedRoadData: rules.fromOSM,
            timeToEnd: timeToEnd
        )
    }

    private struct Physics {
        let cruise: Double   // m/s when no limit is known
        let accel: Double    // m/s²
        let decel: Double    // m/s²
        let lateral: Double  // max sideways accel in curves, m/s²

        init(mode: TravelMode) {
            let values: (Double, Double, Double, Double)
            switch mode {
            case .walk: values = (1.4, 0.6, 0.9, .infinity)
            case .run: values = (3.1, 0.8, 1.2, 6)
            case .cycle: values = (5.6, 0.7, 1.5, 1.8)
            case .drive: values = (50 / 3.6, 1.8, 2.3, 2.2)
            }
            cruise = values.0
            accel = values.1
            decel = values.2
            lateral = values.3
        }
    }

    /// Max speed for the curve around point i: v = sqrt(a_lat * radius).
    private static func curveLimit(points: [CLLocationCoordinate2D], at i: Int, lateral: Double) -> Double {
        guard lateral.isFinite else { return .infinity }
        let k = 3
        guard i - k >= 0, i + k < points.count else { return .infinity }
        let h1 = bearing(points[i - k], points[i])
        let h2 = bearing(points[i], points[i + k])
        var delta = abs(h2 - h1)
        if delta > .pi { delta = 2 * .pi - delta }
        guard delta > 0.02 else { return .infinity }
        let arc = Double(2 * k) * spacing
        let radius = arc / delta
        return max(2.5, sqrt(lateral * radius))
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func dedupe(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for c in coords {
            if let last = out.last, distance(last, c) < 0.5 { continue }
            out.append(c)
        }
        return out
    }
}

/// Live state while following a route, shown in the drive HUD.
struct DriveTelemetry: Equatable {
    enum State: Equatable {
        case driving
        case redLight(secondsLeft: Int)
        case stopSign
        case paused
        case arrived
    }

    var state: State = .driving
    var speed: Double = 0
    var limit: Double?
    var remaining: Double = 0
    var eta: TimeInterval = 0
    var progress: Double = 0
    /// Heading in radians (0 = north), for the follow camera.
    var heading: Double = 0
    var mode: TravelMode = .drive
}
