import SwiftUI
import UIKit

fileprivate enum LyricsInputField {
    case spotifyClientId
    case musixmatchEmail
    case musixmatchPassword
    case title
    case artist
    case album
    case duration
}

struct ContentView: View {
    @EnvironmentObject private var store: LyricsRuntimeStore
    @FocusState private var focusedField: LyricsInputField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                spotifyPanel
                providerPanel
                lookupPanel
                lyricsPanel
                timelinePanel
                statusPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(Color.phosphorBackground.ignoresSafeArea())
        .foregroundStyle(Color.phosphorTextBright)
        .onReceive(store.ticker) { _ in
            store.tick()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("RokidLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("Rokid Lyrics")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.phosphorTextBright)
                Text("iOS runtime")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.phosphorDim)
            }

            Spacer()

            Badge(text: store.providerBadge, highlighted: store.snapshot.synced)
        }
    }

    private var lookupPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "TRACK")
                Spacer()
                Button {
                    store.sampleTrack()
                    focusedField = nil
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(store.isLookingUp)
            }

            VStack(spacing: 10) {
                FieldRow(label: "TITLE", text: $store.title, focusedField: $focusedField, field: .title)
                FieldRow(label: "ARTIST", text: $store.artist, focusedField: $focusedField, field: .artist)
                FieldRow(label: "ALBUM", text: $store.album, focusedField: $focusedField, field: .album)
                FieldRow(label: "DURATION", text: $store.durationSecondsText, focusedField: $focusedField, field: .duration, keyboardType: .numberPad)
            }

            Button {
                focusedField = nil
                Task { await store.lookup() }
            } label: {
                Label(store.isLookingUp ? "SEARCHING" : "LOOKUP", systemImage: store.isLookingUp ? "hourglass" : "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!store.canLookup)
        }
        .padding(14)
        .surface()
    }

    private var spotifyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "SPOTIFY")
                Spacer()
                Badge(text: store.spotifyAuthStatus.label.uppercased(), highlighted: store.spotifyConnected)
            }

            FieldRow(
                label: "CLIENT ID",
                text: $store.spotifyClientId,
                focusedField: $focusedField,
                field: .spotifyClientId,
                capitalization: .never
            )

            HStack(spacing: 10) {
                Button {
                    focusedField = nil
                    store.connectOrDisconnectSpotify()
                } label: {
                    Label(store.spotifyButtonTitle, systemImage: store.spotifyConnected ? "xmark.circle" : "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle())

                Button {
                    focusedField = nil
                    store.refreshSpotifyNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!store.spotifyConnected)
            }

            Toggle(isOn: $store.spotifyMonitoringEnabled) {
                Text("MONITOR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.phosphorDim)
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.phosphorPrimary))

            Text(store.spotifyNowPlayingLabel)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.phosphorTextMid)
                .lineLimit(2)
        }
        .padding(14)
        .surface()
    }

    private var providerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "PROVIDERS")
                Spacer()
                Text("MXM -> NETEASE -> LRCLIB")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.phosphorDim)
            }

            FieldRow(
                label: "MUSIXMATCH EMAIL",
                text: $store.musixmatchEmail,
                focusedField: $focusedField,
                field: .musixmatchEmail,
                capitalization: .never,
                keyboardType: .emailAddress
            )
            SecureFieldRow(
                label: "MUSIXMATCH PASSWORD",
                text: $store.musixmatchPassword,
                focusedField: $focusedField,
                field: .musixmatchPassword
            )

            Text(store.providerStatusLabel)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.phosphorTextMid)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .surface()
    }

    private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "LYRICS")
                Spacer()
                Text(timeText(store.snapshot.progressMs))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.phosphorTextMid)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(store.snapshot.trackTitle.isEmpty ? "Waiting for music..." : store.snapshot.trackTitle)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.phosphorTextBright)
                    .lineLimit(2)

                Text(store.snapshot.artistName.isEmpty ? "Enter a track above" : store.snapshot.artistName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.phosphorTextMid)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(store.visibleLines) { line in
                    LyricLineView(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .padding(14)
        .surface()
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    store.togglePlayback()
                } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(RoundButtonStyle(highlighted: store.hasLyrics))
                .disabled(!store.canUseLocalControls)

                Button {
                    store.restart()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(RoundButtonStyle(highlighted: false))
                .disabled(!store.canUseLocalControls)

                Slider(
                    value: Binding(
                        get: { store.progressFraction },
                        set: { store.seek(to: $0) }
                    ),
                    in: 0...1
                )
                .tint(Color.phosphorPrimary)
                .disabled(!store.canUseLocalControls)
            }

            HStack {
                Text(store.snapshot.sessionState.rawValue)
                Spacer()
                Text(timeText(store.timelineDurationMs))
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.phosphorDim)
        }
        .padding(14)
        .surface()
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "STATUS")
                Spacer()
                Circle()
                    .fill(store.snapshot.errorMessage == nil ? Color.phosphorPrimary : Color.phosphorWarning)
                    .frame(width: 8, height: 8)
            }

            Text(store.statusLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(store.snapshot.errorMessage == nil ? Color.phosphorTextMid : Color.phosphorWarning)
                .fixedSize(horizontal: false, vertical: true)

            Text(store.snapshot.sourceSummary)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.phosphorTextGhost)
                .fixedSize(horizontal: false, vertical: true)

            Text(store.deviceStatus.statusLabel)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.phosphorTextGhost)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .surface()
    }

    private func timeText(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", Int(minutes), Int(seconds))
    }
}

private struct FieldRow: View {
    let label: String
    @Binding var text: String
    var focusedField: FocusState<LyricsInputField?>.Binding
    let field: LyricsInputField
    var capitalization: TextInputAutocapitalization = .words
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            TextField(label, text: $text)
                .focused(focusedField, equals: field)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.phosphorTextBright)
                .tint(Color.phosphorPrimary)
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.phosphorInput)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.phosphorDivider, lineWidth: 1)
                        )
                )
        }
    }
}

private struct SecureFieldRow: View {
    let label: String
    @Binding var text: String
    var focusedField: FocusState<LyricsInputField?>.Binding
    let field: LyricsInputField

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            SecureField(label, text: $text)
                .focused(focusedField, equals: field)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.phosphorTextBright)
                .tint(Color.phosphorPrimary)
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.phosphorInput)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.phosphorDivider, lineWidth: 1)
                        )
                )
        }
    }
}

private struct LyricLineView: View {
    let line: LyricDisplayLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: line.role == .current ? 48 : 28, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: line.text)
    }

    private var font: Font {
        switch line.role {
        case .current:
            return .system(size: 23, weight: .bold, design: .rounded)
        case .previous, .next:
            return .system(size: 15, weight: .semibold, design: .rounded)
        case .empty:
            return .system(size: 17, weight: .semibold, design: .rounded)
        }
    }

    private var color: Color {
        switch line.role {
        case .current:
            return .phosphorPrimary
        case .previous:
            return .phosphorTextGhost
        case .next:
            return .phosphorTextMid
        case .empty:
            return .phosphorTextGhost
        }
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(Color.phosphorDim)
    }
}

private struct Badge: View {
    let text: String
    var highlighted: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(highlighted ? Color.phosphorBackground : Color.phosphorDim)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(highlighted ? Color.phosphorPrimary : Color.phosphorBadge)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(highlighted ? Color.phosphorPrimary : Color.phosphorBadgeStroke, lineWidth: 1)
                    )
            )
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .tracking(1.3)
            .foregroundStyle(Color.phosphorBackground)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.phosphorMid : Color.phosphorPrimary)
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(Color.phosphorDim)
            .padding(.vertical, 11)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.phosphorPressed : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.phosphorDim.opacity(0.75), lineWidth: 1)
                    )
            )
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.phosphorDim)
            .frame(width: 34, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(configuration.isPressed ? Color.phosphorPressed : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.phosphorDim.opacity(0.7), lineWidth: 1)
                    )
            )
    }
}

private struct RoundButtonStyle: ButtonStyle {
    var highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(highlighted ? Color.phosphorBackground : Color.phosphorDim)
            .frame(width: 42, height: 42)
            .background(
                Circle()
                    .fill(highlighted ? (configuration.isPressed ? Color.phosphorMid : Color.phosphorPrimary) : Color.phosphorPressed)
                    .overlay(
                        Circle()
                            .stroke(highlighted ? Color.phosphorPrimary : Color.phosphorDim.opacity(0.45), lineWidth: 1)
                    )
            )
    }
}

private extension View {
    func surface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.phosphorCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.phosphorStroke, lineWidth: 1)
                )
        )
    }
}

private extension Color {
    static let phosphorBackground = Color(red: 0.021, green: 0.038, blue: 0.023)
    static let phosphorPrimary = Color(red: 0.251, green: 0.941, blue: 0.149)
    static let phosphorMid = Color(red: 0.165, green: 0.702, blue: 0.102)
    static let phosphorDim = Color(red: 0.118, green: 0.537, blue: 0.118)
    static let phosphorCard = Color(red: 0.04, green: 0.094, blue: 0.045)
    static let phosphorInput = Color(red: 0.025, green: 0.064, blue: 0.029)
    static let phosphorTextBright = Color(red: 0.849, green: 0.986, blue: 0.831)
    static let phosphorTextMid = Color(red: 0.388, green: 0.627, blue: 0.341)
    static let phosphorTextGhost = Color(red: 0.161, green: 0.286, blue: 0.149)
    static let phosphorDivider = Color(red: 0.075, green: 0.149, blue: 0.075)
    static let phosphorStroke = Color(red: 0.153, green: 0.235, blue: 0.141)
    static let phosphorBadge = Color(red: 0.052, green: 0.123, blue: 0.052)
    static let phosphorBadgeStroke = Color(red: 0.149, green: 0.345, blue: 0.125)
    static let phosphorPressed = Color(red: 0.059, green: 0.169, blue: 0.061)
    static let phosphorWarning = Color(red: 0.843, green: 0.631, blue: 0.188)
}
