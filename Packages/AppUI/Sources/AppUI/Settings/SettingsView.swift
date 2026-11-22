import AppKit
import PlayerKit
import SwiftUI
import WatchParty

/// Content of the Settings window (⌘,).
public struct SettingsView: View {
    @Bindable private var model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        TabView(selection: $model.selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                pane(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbolName) }
                    .tag(tab)
            }
        }
        .frame(width: 640, height: 540)
        // Until the stored settings have been read there is nothing true to show or to edit.
        .disabled(!model.hasLoaded)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsPane(model: model)
        case .playback: PlaybackSettingsPane(model: model)
        case .streaming: StreamingSettingsPane(model: model)
        case .shortcuts: ShortcutsSettingsPane(model: model.shortcuts)
        case .advanced: AdvancedSettingsPane(model: model)
        }
    }
}

extension AppSettings.Appearance {
    /// `nil` follows the system.
    var systemAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct GeneralSettingsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Appearance")
            }
            Section("Home") {
                Picker("Open on", selection: $model.settings.startSection) {
                    ForEach(AppSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                Toggle("Show Featured Titles", isOn: $model.settings.showsFeatured)
                Toggle("Show Continue Watching", isOn: $model.settings.showsContinueWatching)
            }
            Section {
                TextField("Your name", text: $model.settings.partyName, prompt: Text(PartyCenter.defaultName))
                TextField("Party server", text: $model.settings.partyServer, prompt: Text("https://…"))
                    .autocorrectionDisabled()
            } header: {
                Text("Watch Party")
            } footer: {
                Text(partyFootnote)
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralSettingsPane {
    /// What the party server is, and whether what was typed can be used as one.
    var partyFootnote: String {
        let typed = model.settings.partyServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, PartyServer(typed) == nil {
            return "That is not an address that can be used: it has to start with https://."
        }
        return """
        The party server lets the apps in a party find each other; what they say then goes directly between them. \
        Leave it empty to use the one this app came with, if it came with one. An invitation link always names its own.
        """
    }
}

struct PlaybackSettingsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LanguageSetting(title: "Sound", languages: $model.settings.audioLanguages)
                LanguageSetting(title: "Subtitles", languages: $model.settings.subtitleLanguages)
                Picker("Show subtitles", selection: $model.settings.subtitleMode) {
                    ForEach(TrackPreferences.SubtitleMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("A choice you make for one video is remembered for it and for the rest of its series.")
            }

            Section("Watching") {
                Toggle("Carry on where I left off", isOn: $model.settings.resumesPlayback)
                Toggle("Play the next episode automatically", isOn: $model.settings.autoplaysNextEpisode)
                StepperRow(
                    title: "Wait before the next episode",
                    valueText: "\(model.settings.nextEpisodeCountdown) seconds",
                    value: $model.settings.nextEpisodeCountdown,
                    range: AppSettings.countdownRange
                )
                .disabled(!model.settings.autoplaysNextEpisode)
            }

            Section {
                Picker("Rendering", selection: $model.settings.renderQuality) {
                    ForEach([PlayerConfiguration.RenderQuality.efficient, .high], id: \.self) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
            } header: {
                Text("Picture")
            } footer: {
                Text("""
                Efficient uses less power and memory, and is hard to tell apart on most video. High Quality uses the \
                playback engine's best scaling. Applies to the next video you open.
                """)
            }

            Section {
                Text("""
                Subtitle style, the equaliser, loudness, HDR and hardware decoding are set in the player's own panels \
                and stay as you leave them.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One row of "which languages": the system's, or the user's own list.
private struct LanguageSetting: View {
    let title: String
    @Binding var languages: [String]?
    @State private var text = ""

    private var systemLanguages: [String] {
        TrackPreferences.system().audioLanguages
    }

    var body: some View {
        Picker(title, selection: followsSystem) {
            Text("Same as the System (\(LanguageList.names(of: systemLanguages)))").tag(true)
            Text("My Own List").tag(false)
        }
        if let languages {
            TextField("Languages", text: $text, prompt: Text("English, Japanese"))
                .labelsHidden()
                .accessibilityLabel("\(title) languages, most wanted first")
                .onAppear { text = LanguageList.names(of: languages) }
                .onChange(of: text) { _, text in
                    // What is typed is left alone; only the understood list is stored.
                    let parsed = LanguageList.parse(text)
                    if parsed != languages {
                        self.languages = parsed
                    }
                }
            Text(languages.isEmpty
                ? "Type languages by name or code, most wanted first, with commas between them."
                : "In this order: \(LanguageList.names(of: languages)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var followsSystem: Binding<Bool> {
        Binding {
            languages == nil
        } set: { follows in
            languages = follows ? nil : systemLanguages
            text = LanguageList.names(of: systemLanguages)
        }
    }
}

struct StreamingSettingsPane: View {
    @Bindable var model: SettingsModel
    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section {
                Picker("On a title's page, show", selection: $model.settings.streamListStyle) {
                    ForEach(StreamListStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Picker("Highest quality", selection: $model.settings.preferredQualityHeight) {
                    Text("No Limit").tag(Int?.none)
                    ForEach(StreamQuality.allCases.reversed(), id: \.self) { quality in
                        Text(quality.label).tag(Int?.some(quality.rawValue))
                    }
                }
                Picker("Largest size", selection: $model.settings.maximumStreamGigabytes) {
                    Text("No Limit").tag(Int?.none)
                    ForEach([2, 5, 10, 20, 40], id: \.self) { gigabytes in
                        Text("\(gigabytes) GB").tag(Int?.some(gigabytes))
                    }
                }
                LabeledContent("This connection") {
                    HStack {
                        Text(Self.speedText(model.measuredSpeed))
                            .monospacedDigit()
                        Button("Forget") { model.forgetMeasuredSpeed() }
                            .disabled(model.measuredSpeed == nil)
                            .help("Forget the measured speed, after changing connection for example")
                    }
                }
                Picker("Sort streams by", selection: $model.settings.streamSort) {
                    ForEach(StreamSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
            } header: {
                Text("Choosing a Stream")
            } footer: {
                Text("""
                Play chooses the best picture that should play without stopping: in your languages, within these \
                limits, shared by enough people, and needing no more than this connection has been seen to manage. \
                The speed is learned from the streams you play; nothing is tested behind your back.
                """)
            }

            Section("Cache") {
                StepperRow(
                    title: "Keep up to",
                    valueText: "\(Int(model.settings.cacheLimitGigabytes)) GB",
                    value: $model.settings.cacheLimitGigabytes,
                    range: AppSettings.cacheLimitRange
                )
                LabeledContent("On disk now") {
                    HStack {
                        Text(model.cacheBytes.formatted(.byteCount(style: .file)))
                            .monospacedDigit()
                        Button("Clear…") { isConfirmingClear = true }
                            .disabled(model.cacheBytes == 0)
                    }
                }
            }

            Section {
                StepperRow(
                    title: "Connections at most",
                    valueText: "\(model.settings.connectionsLimit)",
                    value: $model.settings.connectionsLimit,
                    range: AppSettings.connectionsRange,
                    step: 10
                )
                RateLimitField(title: "Download limit", rate: $model.settings.downloadLimit)
                RateLimitField(title: "Upload limit", rate: $model.settings.uploadLimit)
                Toggle("Find peers without a tracker (DHT)", isOn: $model.settings.usesDHT)
                Toggle("Find peers on the local network", isOn: $model.settings.usesLocalDiscovery)
                Toggle("Ask the router to forward a port", isOn: $model.settings.mapsPorts)
            } header: {
                Text("Torrent Streams")
            } footer: {
                Text("These only matter for torrent streams, which come from add-ons you have installed.")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshCacheSize() }
        .confirmationDialog("Clear the stream cache?", isPresented: $isConfirmingClear) {
            Button("Clear Cache", role: .destructive) {
                Task { await model.clearCache() }
            }
        } message: {
            Text("Streams you watch again will be fetched again. What is playing now is kept.")
        }
    }
}

/// A number with its unit on the right, next to the arrows that change it.
private struct StepperRow<Value: Strideable>: View {
    let title: String
    let valueText: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    var step: Value.Stride = 1

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(valueText)
                    .monospacedDigit()
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityValue(valueText)
            }
        }
    }
}

extension StreamingSettingsPane {
    /// "38 Mbit/s", as connections are advertised; or that nothing is known yet.
    nonisolated static func speedText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "Not measured yet" }
        let megabits = bytesPerSecond * 8 / 1_000_000
        return megabits >= 10 ? "\(Int(megabits.rounded())) Mbit/s" : String(format: "%.1f Mbit/s", megabits)
    }
}

/// Kilobytes per second, where nothing typed means no limit.
private struct RateLimitField: View {
    let title: String
    @Binding var rate: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: optionalRate, format: .number, prompt: Text("No limit"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .accessibilityLabel("\(title), in kilobytes per second; empty for no limit")
                Text("KB/s")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var optionalRate: Binding<Int?> {
        Binding {
            rate > 0 ? rate : nil
        } set: { value in
            rate = max(value ?? 0, 0)
        }
    }
}

struct AdvancedSettingsPane: View {
    @Bindable var model: SettingsModel
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Read mpv.conf and input.conf", isOn: $model.settings.readsEngineConfigFiles)
                if model.settings.readsEngineConfigFiles {
                    if let file = model.configReport.optionsFile {
                        ConfigFileRow(name: EngineConfigFolder.optionsFileName, noun: "option", file: file)
                    }
                    if let file = model.configReport.bindingsFile {
                        ConfigFileRow(name: EngineConfigFolder.bindingsFileName, noun: "shortcut", file: file)
                    }
                }
                HStack {
                    Button("Show Folder") { showFolder() }
                    Button("Read Again") {
                        Task { await model.reloadConfigFiles() }
                    }
                    .disabled(!model.settings.readsEngineConfigFiles)
                }
                .disabled(model.configFolder == nil)
            } header: {
                Text("Player Config Files")
            } footer: {
                Text("""
                For settings the app has no control for, put an mpv.conf in the app's folder; an input.conf there \
                adds keyboard shortcuts. Options take effect with the next video. What the app has to control itself, \
                and anything that would run programs or write files, is left out and listed here.
                """)
            }

            Section {
                Button("Reset All Settings…", role: .destructive) { isConfirmingReset = true }
            } footer: {
                Text("Your library, history, add-ons and keyboard shortcuts are not touched.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $isConfirmingReset) {
            Button("Reset Settings", role: .destructive) { model.resetToDefaults() }
        }
    }

    private func showFolder() {
        guard let folder = model.configFolder else { return }
        try? folder.create()
        NSWorkspace.shared.open(folder.directory)
    }
}

private struct ConfigFileRow: View {
    let name: String
    let noun: String
    let file: EngineConfigReport.File

    var body: some View {
        if file.ignored.isEmpty {
            LabeledContent(name, value: file.summary(noun: noun))
        } else {
            DisclosureGroup {
                ForEach(file.ignored) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Line \(line.number): \(line.text)")
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(line.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } label: {
                LabeledContent(name, value: file.summary(noun: noun))
            }
        }
    }
}
