import CoreLocation
import Foundation
import simd

/// Traffic-rule data along a route, fetched from OpenStreetMap (Overpass API).
/// Everything here degrades gracefully: without network the simulator falls back
/// to road-type defaults and curve physics.
struct RoadRules {
    /// Speed limit (m/s) per route point, nil when unknown.
    var limits: [CLLocationSpeed?]
    /// Route point indices with a traffic light.
    var trafficSignals: Set<Int>
    /// Route point indices with a stop sign.
    var stopSigns: Set<Int>
    /// Route point indices with a give-way / yield sign.
    var giveWays: Set<Int>
    /// True when OpenStreetMap data was loaded.
    var fromOSM: Bool

    static func empty(count: Int) -> RoadRules {
        RoadRules(limits: Array(repeating: nil, count: count), trafficSignals: [], stopSigns: [], giveWays: [], fromOSM: false)
    }
}

enum RoadRulesService {
    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Loads speed limits + traffic controls for the given (densely sampled) route.
    static func fetch(for route: [CLLocationCoordinate2D], mode: TravelMode) async -> RoadRules {
        guard route.count >= 2 else { return .empty(count: route.count) }
        do {
            let ways = try await download(route: route)
            return match(route: route, response: ways, mode: mode)
        } catch {
            return .empty(count: route.count)
        }
    }

    // MARK: - Overpass

    private struct OverpassResponse: Decodable {
        struct Element: Decodable {
            struct Point: Decodable { let lat: Double; let lon: Double }
            let type: String
            let id: Int
            let lat: Double?
            let lon: Double?
            let tags: [String: String]?
            let geometry: [Point]?
        }
        let elements: [Element]
    }

    private static func download(route: [CLLocationCoordinate2D]) async throws -> OverpassResponse {
        // Overpass "around" accepts a polyline; keep it short so the query stays fast.
        let thinned = thin(route, maxPoints: 180)
        let line = thinned
            .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
            .joined(separator: ",")
        let query = """
        [out:json][timeout:25];
        way(around:18,\(line))[highway]->.w;
        .w out tags geom;
        node(w.w)[highway~"^(traffic_signals|stop|give_way)$"];
        out;
        """
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Locus-iOS/1.1", forHTTPHeaderField: "User-Agent")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OverpassResponse.self, from: data)
    }

    private static func thin(_ coords: [CLLocationCoordinate2D], maxPoints: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > maxPoints else { return coords }
        let stride = Double(coords.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { coords[min(coords.count - 1, Int((Double($0) * stride).rounded()))] }
    }

    // MARK: - Matching

    private struct Segment {
        let a: SIMD2<Double>
        let b: SIMD2<Double>
        let limit: CLLocationSpeed?
        let bearing: Double
    }

    private static func match(route: [CLLocationCoordinate2D], response: OverpassResponse, mode: TravelMode) -> RoadRules {
        var rules = RoadRules.empty(count: route.count)
        rules.fromOSM = true
        let origin = route[0]
        let project = { (c: CLLocationCoordinate2D) -> SIMD2<Double> in
            LocalProjection.meters(c, origin: origin)
        }

        // Build a coarse spatial grid of way segments.
        let cell = 60.0
        var grid: [SIMD2<Int>: [Segment]] = [:]
        func key(_ p: SIMD2<Double>) -> SIMD2<Int> { SIMD2(Int(floor(p.x / cell)), Int(floor(p.y / cell))) }

        var controlNodes: [(SIMD2<Double>, String)] = []

        for element in response.elements {
            if element.type == "node", let lat = element.lat, let lon = element.lon, let kind = element.tags?["highway"] {
                controlNodes.append((project(CLLocationCoordinate2D(latitude: lat, longitude: lon)), kind))
                continue
            }
            guard element.type == "way", let geometry = element.geometry, geometry.count >= 2 else { continue }
            let tags = element.tags ?? [:]
            let highway = tags["highway"] ?? ""
            if !mode.usesRoad(highway) { continue }
            let limit = SpeedLimitParser.limit(tags: tags, highway: highway, mode: mode)
            let points = geometry.map { project(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
            for (a, b) in zip(points, points.dropFirst()) {
                let d = b - a
                let seg = Segment(a: a, b: b, limit: limit, bearing: atan2(d.x, d.y))
                let k1 = key(a), k2 = key(b)
                for x in min(k1.x, k2.x)...max(k1.x, k2.x) {
                    for y in min(k1.y, k2.y)...max(k1.y, k2.y) {
                        grid[SIMD2(x, y), default: []].append(seg)
                    }
                }
            }
        }

        let projected = route.map(project)
        for i in projected.indices {
            let p = projected[i]
            let j = min(projected.count - 1, i + 1)
            let h = max(0, i - 1)
            let dir = projected[j] - projected[h]
            let routeBearing = atan2(dir.x, dir.y)
            let k = key(p)
            var best: (score: Double, limit: CLLocationSpeed?)?
            for x in (k.x - 1)...(k.x + 1) {
                for y in (k.y - 1)...(k.y + 1) {
                    for seg in grid[SIMD2(x, y)] ?? [] {
                        let dist = distance(p, seg.a, seg.b)
                        guard dist < 25 else { continue }
                        // Prefer ways running the same direction (avoid cross streets at junctions).
                        var diff = abs(routeBearing - seg.bearing).truncatingRemainder(dividingBy: .pi)
                        if diff > .pi / 2 { diff = .pi - diff }
                        let score = dist + diff * 30
                        if best == nil || score < best!.score {
                            best = (score, seg.limit)
                        }
                    }
                }
            }
            rules.limits[i] = best?.limit
        }

        // Snap traffic controls to the nearest route point (within 14 m).
        for (pos, kind) in controlNodes {
            var bestIndex = -1
            var bestDist = 14.0
            for (i, p) in projected.enumerated() {
                let d = simd_length(p - pos)
                if d < bestDist { bestDist = d; bestIndex = i }
            }
            guard bestIndex > 0, bestIndex < projected.count - 1 else { continue }
            switch kind {
            case "traffic_signals": rules.trafficSignals.insert(bestIndex)
            case "stop": rules.stopSigns.insert(bestIndex)
            case "give_way": rules.giveWays.insert(bestIndex)
            default: break
            }
        }
        rules.trafficSignals = dedupe(rules.trafficSignals, minGap: 5)
        return rules
    }

    /// Several signal nodes at one junction → keep one stop.
    private static func dedupe(_ indices: Set<Int>, minGap: Int) -> Set<Int> {
        var result: Set<Int> = []
        var last = Int.min
        for i in indices.sorted() where i - last > minGap {
            result.insert(i)
            last = i
        }
        return result
    }

    private static func distance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 0 else { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / len2))
        return simd_length(p - (a + t * ab))
    }
}

enum LocalProjection {
    /// Equirectangular projection in meters (x = east, y = north). Accurate enough for a few hundred km.
    static func meters(_ c: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> SIMD2<Double> {
        let r = 6_371_000.0
        let x = (c.longitude - origin.longitude) * .pi / 180 * r * cos(origin.latitude * .pi / 180)
        let y = (c.latitude - origin.latitude) * .pi / 180 * r
        return SIMD2(x, y)
    }
}

enum SpeedLimitParser {
    private static let kmh = 1 / 3.6

    static func limit(tags: [String: String], highway: String, mode: TravelMode) -> CLLocationSpeed? {
        if mode == .drive {
            if let raw = tags["maxspeed:forward"] ?? tags["maxspeed"], let parsed = parse(raw) {
                return parsed
            }
            return defaultLimit(highway: highway)
        }
        return nil
    }

    static func parse(_ raw: String) -> CLLocationSpeed? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" { return 130 * kmh }
        if value == "walk" { return 7 * kmh }
        if value.hasSuffix(":urban") { return 50 * kmh }
        if value.hasSuffix(":rural") { return 100 * kmh }
        if value.hasSuffix(":motorway") { return 130 * kmh }
        if value.hasSuffix(":living_street") { return 7 * kmh }
        if value.hasSuffix(":bicycle_road") { return 30 * kmh }
        if value.hasSuffix(":zone30") || value.hasSuffix(":zone:30") { return 30 * kmh }
        let digits = value.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number > 0 else { return nil }
        if value.contains("mph") { return number * 0.44704 }
        if value.contains("knots") { return number * 0.514444 }
        return number * kmh
    }

    static func defaultLimit(highway: String) -> CLLocationSpeed? {
        switch highway {
        case "motorway": return 130 * kmh
        case "trunk": return 100 * kmh
        case "motorway_link", "trunk_link": return 60 * kmh
        case "primary", "secondary": return 70 * kmh
        case "primary_link", "secondary_link", "tertiary_link": return 50 * kmh
        case "tertiary", "unclassified": return 50 * kmh
        case "residential": return 30 * kmh
        case "living_street": return 7 * kmh
        case "service": return 20 * kmh
        default: return nil
        }
    }
}

extension TravelMode {
    /// Which OSM highway types this mode can be on (used for matching speed limits).
    func usesRoad(_ highway: String) -> Bool {
        let footOnly: Set<String> = ["footway", "path", "steps", "pedestrian", "track", "bridleway", "corridor"]
        let motorOnly: Set<String> = ["motorway", "motorway_link", "trunk", "trunk_link"]
        switch self {
        case .drive: return !footOnly.contains(highway) && highway != "cycleway"
        case .cycle: return !motorOnly.contains(highway) && highway != "steps"
        case .walk, .run: return !motorOnly.contains(highway)
        }
    }
}
