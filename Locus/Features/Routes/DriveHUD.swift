import SwiftUI

/// Navigation-style card shown while following a route.
struct DriveHUD: View {
    @EnvironmentObject private var session: SpoofSession
    let info: DriveTelemetry

    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                speedometer
                VStack(alignment: .leading, spacing: 4) {
                    Text(stateTitle)
                        .font(.headline)
                        .foregroundStyle(stateColor)
                        .contentTransition(.numericText())
                    Text("\(DriveFormat.distance(info.remaining)) · \(DriveFormat.duration(info.eta))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    if info.state != .arrived {
                        Text("Arrive \(Date().addingTimeInterval(info.eta).formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let limit = info.limit, info.mode == .drive {
                    SpeedLimitSign(value: DriveFormat.speedValue(limit), over: info.speed > limit * 1.02)
                }
            }

            ProgressView(value: min(max(info.progress, 0), 1))
                .tint(LocusTheme.accent)

            HStack(spacing: 10) {
                Button {
                    session.followCamera.toggle()
                } label: {
                    Image(systemName: session.followCamera ? "location.north.line.fill" : "location.north.line")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 40)
                        .background(Capsule().fill(Color.primary.opacity(session.followCamera ? 0.16 : 0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow camera")

                if info.state != .arrived {
                    Button {
                        session.toggleRoutePause()
                    } label: {
                        Label(session.routePaused ? "Resume" : "Pause",
                              systemImage: session.routePaused ? "play.fill" : "pause.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation(.snappy) { session.endRoute() }
                } label: {
                    Label(info.state == .arrived ? "Done" : "End", systemImage: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: info.state == .arrived ? .infinity : nil)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(LocusTheme.danger))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .locusGlass(.regular, in: shape)
        .contentShape(shape)
        .animation(.snappy, value: info.state)
    }

    private var speedometer: some View {
        VStack(spacing: -2) {
            Text("\(DriveFormat.speedValue(info.speed))")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: info.speed))
            Text(DriveFormat.speedUnit)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 74, height: 74)
        .background(Circle().fill(Color.primary.opacity(0.08)))
        .overlay(
            Circle()
                .trim(from: 0, to: speedFraction)
                .stroke(LocusTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        )
        .animation(.easeInOut(duration: 0.8), value: info.speed)
    }

    private var speedFraction: CGFloat {
        let reference = info.limit ?? (info.mode == .drive ? 50 / 3.6 : 6)
        return CGFloat(min(1, max(0, info.speed / max(reference, 0.1))))
    }

    private var stateTitle: String {
        switch info.state {
        case .driving:
            switch info.mode {
            case .drive: return "Driving"
            case .cycle: return "Cycling"
            case .run: return "Running"
            case .walk: return "Walking"
            }
        case .redLight(let left): return "Red light · \(left) s"
        case .stopSign: return "Stop sign"
        case .paused: return "Paused"
        case .arrived: return "Arrived"
        }
    }

    private var stateColor: Color {
        switch info.state {
        case .driving: return .primary
        case .redLight: return LocusTheme.statusBad
        case .stopSign: return LocusTheme.statusWarn
        case .paused: return .secondary
        case .arrived: return LocusTheme.statusGood
        }
    }
}

struct SpeedLimitSign: View {
    let value: Int
    var over: Bool = false

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(Color(red: 0.86, green: 0.1, blue: 0.12), lineWidth: 6)
            Text("\(value)")
                .font(.system(size: value >= 100 ? 17 : 21, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .monospacedDigit()
        }
        .frame(width: 54, height: 54)
        .scaleEffect(over ? 1.08 : 1)
        .shadow(color: over ? .red.opacity(0.6) : .black.opacity(0.2), radius: over ? 8 : 3)
        .animation(.easeInOut(duration: 0.3), value: over)
        .accessibilityLabel("Speed limit \(value)")
    }
}
