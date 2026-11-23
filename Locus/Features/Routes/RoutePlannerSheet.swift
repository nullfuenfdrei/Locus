import CoreLocation
import MapKit
import SwiftUI

struct RouteDestination: Equatable {
    var name: String
    var coordinate: CLLocationCoordinate2D

    static func == (lhs: RouteDestination, rhs: RouteDestination) -> Bool {
        lhs.name == rhs.name
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

struct RoutePlannerSheet: View {
    @Binding var destination: RouteDestination?
    @Binding var plan: DrivePlan?
    @Binding var isRouting: Bool
    @Binding var followRules: Bool
    var hasDrawnPath: Bool
    var onBuild: () -> Void
    var onStart: () -> Void
    var onImportGPX: () -> Void
    var onExportGPX: () -> Void
    var onUseDrawn: () -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearchCompleter()
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modePicker
                    endpoints
                    rulesCard
                    if let plan {
                        summary(plan)
                    }
                    actionButtons
                    moreOptions
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Plan a Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: session.travelMode) { _, _ in plan = nil }
            .onChange(of: followRules) { _, _ in plan = nil }
        }
    }

    // MARK: Mode

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(TravelMode.allCases) { mode in
                let selected = session.travelMode == mode
                Button {
                    withAnimation(.snappy) { session.travelMode = mode }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.title3.weight(.semibold))
                        Text(mode.title)
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(selected ? .black : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selected ? LocusTheme.accent : Color.primary.opacity(0.07))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    // MARK: From / To

    private var endpoints: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                endpointDot(color: LocusTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("From").font(.caption).foregroundStyle(.secondary)
                    Text(startLabel).font(.subheadline.weight(.semibold))
                }
                Spacer()
            }
            .padding(14)

            Divider().padding(.leading, 40)

            HStack(spacing: 12) {
                endpointDot(color: LocusTheme.accentSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("To").font(.caption).foregroundStyle(.secondary)
                    if let destination, query.isEmpty {
                        Text(destination.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    TextField(destination == nil ? "Search destination" : "Change destination", text: $query)
                        .font(.subheadline)
                        .focused($searchFocused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onChange(of: query) { _, value in search.query = value }
                }
                if session.pin != nil {
                    Button {
                        if let pin = session.pin {
                            setDestination(RouteDestination(name: "Dropped pin", coordinate: pin))
                        }
                    } label: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LocusTheme.accentSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use dropped pin as destination")
                }
            }
            .padding(14)

            if !query.isEmpty && !search.results.isEmpty {
                Divider()
                ForEach(search.results.prefix(5), id: \.self) { item in
                    Button {
                        select(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var startLabel: String {
        if session.simulated != nil { return "Current spoofed position" }
        if session.realCoordinate != nil { return "My location" }
        return "Set a pin or teleport first"
    }

    private func endpointDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
            .frame(width: 16)
    }

    // MARK: Rules

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $followRules) {
                Label("Follow traffic rules", systemImage: "light.beacon.max")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(LocusTheme.accent)
            Text(followRules
                 ? "Keeps to speed limits, slows down for curves and junctions, stops at red lights and stop signs. Road data from OpenStreetMap."
                 : "Constant speed with light variation — no limits or stops.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    // MARK: Summary

    private func summary(_ plan: DrivePlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(DriveFormat.duration(plan.estimatedDuration))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(DriveFormat.distance(plan.totalDistance))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Arrive \(Date().addingTimeInterval(plan.estimatedDuration).formatted(date: .omitted, time: .shortened))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if followRules {
                    chip("light.beacon.max.fill", "\(plan.signalCount) lights")
                    if plan.stopSignCount > 0 {
                        chip("octagon.fill", "\(plan.stopSignCount) stop")
                    }
                    let average = plan.estimatedDuration > 0 ? plan.totalDistance / plan.estimatedDuration : 0
                    chip("speedometer", "Ø " + DriveFormat.speed(average))
                }
                Spacer(minLength: 0)
            }
            if followRules && !plan.usedRoadData {
                Label("Road data unavailable — using typical limits.", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(LocusTheme.statusWarn)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LocusTheme.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(LocusTheme.accent.opacity(0.35), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    // MARK: Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if plan == nil {
                Button(action: onBuild) {
                    HStack {
                        if isRouting {
                            ProgressView().tint(.black)
                            Text(followRules ? "Loading roads & limits…" : "Calculating…")
                        } else {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            Text("Calculate Route")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(destination == nil ? LocusTheme.accent.opacity(0.4) : LocusTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(destination == nil || isRouting)
            } else {
                Button(action: onStart) {
                    Label("Start", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(LocusTheme.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var moreOptions: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                if hasDrawnPath {
                    Button(action: onUseDrawn) {
                        Label("Use drawn path from map", systemImage: "pencil.tip")
                    }
                }
                Button(action: onImportGPX) {
                    Label("Import GPX", systemImage: "square.and.arrow.down")
                }
                Button(action: onExportGPX) {
                    Label("Export route as GPX", systemImage: "square.and.arrow.up")
                }
                Text("Tip: turn on the pencil on the map to draw your own path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Draw & GPX").font(.subheadline.weight(.semibold))
        }
        .tint(.primary)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            if let response = try? await MKLocalSearch(request: request).start(),
               let item = response.mapItems.first {
                setDestination(RouteDestination(name: item.name ?? completion.title, coordinate: item.placemark.coordinate))
            }
        }
    }

    private func setDestination(_ value: RouteDestination) {
        destination = value
        plan = nil
        query = ""
        search.query = ""
        searchFocused = false
        onBuild()
    }
}

enum DriveFormat {
    static var usesImperial: Bool { Locale.current.measurementSystem == .us }

    static func speed(_ metersPerSecond: Double) -> String {
        "\(speedValue(metersPerSecond)) \(speedUnit)"
    }

    static func speedValue(_ metersPerSecond: Double) -> Int {
        Int((metersPerSecond * (usesImperial ? 2.23694 : 3.6)).rounded())
    }

    static var speedUnit: String { usesImperial ? "mph" : "km/h" }

    static func distance(_ meters: Double) -> String {
        if usesImperial {
            let miles = meters / 1609.34
            return miles < 0.2 ? "\(Int((meters * 3.28084).rounded())) ft" : String(format: "%.1f mi", miles)
        }
        return meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
