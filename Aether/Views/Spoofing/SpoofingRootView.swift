import SwiftUI

struct SpoofingRootView: View {
    @EnvironmentObject private var session: SpoofSession
	@Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPlaces = false

    var body: some View {
        // Bottom chrome is a sibling overlay aligned to the bottom — no full-screen
        // Spacer layer that can steal / pass map taps through the tray.
        ZStack(alignment: .bottom) {
			MapHomeView(onClose: { dismiss() })

            BottomControlsView(
                showPlaces: $showPlaces
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
		.alert("Spoofing", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.stopJoystick() }
        }
        .task(id: scenePhase) {
			if scenePhase == .active { await session.refreshAfterForeground() }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var session: SpoofSession
	@ObservedObject private var connection = DeviceConnectionManager.shared

    private enum Display {
        case notSpoofing
		case connectTunnel
        case status(String)
    }

    private var display: Display {
        switch session.status {
        case .idle:
			return connection.isConnected ? .notSpoofing : .connectTunnel
        case .connecting:
            return .status(session.connectionDetail ?? "Preparing location…")
        case .active:
            return .status("Spoofing")
        case .reconnecting:
            return .status(session.connectionDetail ?? "Reconnecting…")
        case .stopping:
            return .status("Stopping…")
        case .dropped:
            return .status("Location unverified")
        }
    }

    private var color: Color {
        switch display {
        case .notSpoofing:
            return Color.primary.opacity(0.55)
		case .connectTunnel:
            return LocusTheme.statusWarn
        case .status:
            switch session.status {
            case .active: return LocusTheme.statusGood
            case .connecting, .reconnecting, .stopping: return LocusTheme.statusWarn
            case .dropped: return LocusTheme.statusBad
            case .idle: return Color.primary.opacity(0.55)
            }
        }
    }

    private var title: String {
        switch display {
        case .notSpoofing: return "Not Spoofing"
		case .connectTunnel: return "Connect \(connection.tunnelMethod.displayName)"
        case .status(let text): return text
        }
    }

    var body: some View {
        Group {
            statusContent
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

			if case .connectTunnel = display {
                Image(systemName: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            } else if case .active = session.status, let sim = session.simulated {
                Text(String(format: "%.4f, %.4f", sim.latitude, sim.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @Binding var showPlaces: Bool

    private let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

			compactControls
			primaryAction
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        // Whole tray absorbs taps so near-misses don't fall through to the map.
        .contentShape(trayShape)
    }

	private var compactControls: some View {
		GeometryReader { proxy in
			let spacing: CGFloat = 8
			let diameter = min(44, (proxy.size.width - (spacing * 5)) / 6)

			HStack(spacing: spacing) {
				ForEach(TravelMode.allCases) { mode in
					trayIcon(
						mode.icon,
						selected: session.travelMode == mode,
						accessibilityLabel: mode.title,
						diameter: diameter
					) {
						session.travelMode = mode
					}
				}

				trayIcon(
					"star.fill",
					accessibilityLabel: "Favorites",
					diameter: diameter
				) {
					showPlaces = true
				}

				trayIcon(
					"dot.circle.and.hand.point.up.left.fill",
					selected: session.joystickActive,
					selectedColor: LocusTheme.accentSecondary,
					accessibilityLabel: session.joystickActive ? "Stop joystick" : "Joystick",
					diameter: diameter
				) {
					if session.joystickActive {
						session.stopJoystick()
					} else {
						Task { await session.startJoystick() }
					}
				}
				.disabled(session.isBusy && !session.joystickActive)
				.opacity(session.isBusy && !session.joystickActive ? 0.55 : 1)
			}
			.frame(maxWidth: .infinity)
		}
		.frame(height: 44)
	}

	@ViewBuilder
	private var primaryAction: some View {
		if session.isSpoofing || session.simulated != nil || session.status.isDropped {
			Button {
				Task { await session.stop() }
			} label: {
				Text("Stop")
					.font(.subheadline.weight(.bold))
					.foregroundStyle(.white)
					.frame(minWidth: 96)
					.padding(.vertical, 12)
					.padding(.horizontal, 10)
					.background(Capsule().fill(LocusTheme.danger))
					.contentShape(Capsule())
			}
			.buttonStyle(.plain)
			.disabled(session.status == .stopping)
			.opacity(session.status == .stopping ? 0.55 : 1)
			.frame(maxWidth: .infinity)
		} else {
			Button {
				guard let pin = session.pin else {
					session.lastError = "Tap the map to drop a pin first."
					return
				}
				Task { await session.teleport(to: pin) }
			} label: {
				Text("Teleport")
					.font(.subheadline.weight(.bold))
					.foregroundStyle(.white)
					.frame(minWidth: 120)
					.padding(.vertical, 12)
					.padding(.horizontal, 12)
					.background(Capsule().fill(LocusTheme.accent))
					.contentShape(Capsule())
			}
			.buttonStyle(.plain)
			.disabled(session.isBusy)
			.opacity(session.isBusy ? 0.55 : 1)
			.frame(maxWidth: .infinity)
		}
	}

	private func trayIcon(
		_ systemName: String,
		selected: Bool = false,
		selectedColor: Color = LocusTheme.accent,
		accessibilityLabel: String,
		diameter: CGFloat,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.body.weight(.semibold))
				.foregroundStyle(selected ? .white : .primary)
				.frame(width: diameter, height: diameter)
				.background(Circle().fill(selected ? selectedColor : Color.primary.opacity(0.08)))
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(accessibilityLabel)
	}
}
