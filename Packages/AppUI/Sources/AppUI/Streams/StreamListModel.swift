import Foundation
import MediaCore
import Observation

/// The streams for one video: asks every installed add-on that offers streams, all at once,
/// and lists the answers as they arrive.
@MainActor
@Observable
public final class StreamListModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case finished
    }

    public private(set) var phase = Phase.idle
    public private(set) var groups: [StreamGroup] = []
    /// Whether any installed add-on offers streams for this kind of video at all.
    public private(set) var hasProviders = false
    /// Add-ons that did not answer.
    public private(set) var failedAddonNames: [String] = []
    /// The streams that can be played by pressing Play, most suitable first (`StreamPicker`).
    public private(set) var picks: [StreamPick] = []
    /// The stream the full list shows first: the picker's choice, when it has one worth pointing out.
    public private(set) var suggested: StreamChoice?
    /// Why it is shown first.
    public private(set) var suggestionTitle = "Recommended"
    /// A Play button that chooses, or the whole list.
    public var presentation = StreamListStyle.playButton
    /// Whether the whole list is showing under the Play button.
    public var showsAllStreams = false
    public var sort: StreamSort = .quality {
        didSet {
            if sort != oldValue {
                arrange()
            }
        }
    }

    /// Everything that has arrived, add-on by add-on in install order.
    public private(set) var choices: [StreamChoice] = []
    /// The video the list is for.
    public private(set) var videoID: String?

    /// What the picker goes by, apart from what was played last time (which this model looks up itself).
    @ObservationIgnored public private(set) var context = StreamPicker.Context()
    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private let memory: (any StreamChoiceMemory)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastChoice: LastStreamChoice?
    @ObservationIgnored private var titleID = ""

    public init(client: AddonClient, memory: (any StreamChoiceMemory)? = nil) {
        self.client = client
        self.memory = memory
    }

    /// Looks for streams of a video.
    /// - Parameters:
    ///   - videoID: The title's id for a film; the episode's id for a series.
    ///   - titleID: The film or series, under which the last-used source is remembered.
    public func load(type: MediaType, videoID: String, titleID: String, addons: [InstalledAddon]) {
        loadTask?.cancel()
        generation += 1
        let current = generation
        self.videoID = videoID
        self.titleID = titleID
        choices = []
        groups = []
        failedAddonNames = []
        suggested = nil
        picks = []
        showsAllStreams = false

        let providers = addons.serving(resource: ManifestResource.stream, type: type, id: videoID)
        hasProviders = !providers.isEmpty
        guard hasProviders else {
            phase = .finished
            return
        }
        phase = .loading
        loadTask = Task { [client, memory] in
            lastChoice = await memory?.lastChoice(for: titleID)
            var answers: [Int: [StreamChoice]] = [:]
            await withTaskGroup(of: (Int, Result<[StreamItem], AddonError>).self) { group in
                for (index, addon) in providers.enumerated() {
                    group.addTask {
                        do throws(AddonError) {
                            return try await (index, .success(client.streams(type: type, videoID: videoID, from: addon.address)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                for await (index, answer) in group {
                    guard current == generation else { continue }
                    let addon = providers[index]
                    switch answer {
                    case let .success(streams):
                        answers[index] = streams.enumerated().map { position, stream in
                            StreamChoice(stream: stream, addonID: addon.id, addonName: addon.manifest.name, position: position)
                        }
                        choices = answers.keys.sorted().flatMap { answers[$0] ?? [] }
                        arrange()
                    case let .failure(error) where !error.isCancellation:
                        failedAddonNames.append(addon.manifest.name)
                    case .failure:
                        break
                    }
                }
            }
            guard current == generation else { return }
            phase = .finished
        }
    }

    /// What the picker should go by: the user's limits and languages, and the connection's speed.
    public func configure(_ context: StreamPicker.Context) {
        let runtime = self.context.runtime
        self.context = context
        self.context.runtime = context.runtime ?? runtime
        arrange()
    }

    /// How long the title runs, once the catalog has said: it decides what each stream needs.
    public func setRuntime(_ seconds: Double?) {
        guard let seconds, seconds != context.runtime else { return }
        context.runtime = seconds
        arrange()
    }

    /// Forgets the list (the page moved on to another video, or away).
    public func clear() {
        loadTask?.cancel()
        generation += 1
        videoID = nil
        choices = []
        groups = []
        failedAddonNames = []
        suggested = nil
        picks = []
        showsAllStreams = false
        phase = .idle
    }

    /// Notes which stream was played, so the like of it is offered first next time.
    public func didChoose(_ choice: StreamChoice) {
        let last = LastStreamChoice(choice)
        lastChoice = last
        suggested = choice
        suggestionTitle = "Like Last Time"
        let titleID = titleID
        Task { [memory] in
            await memory?.remember(last, for: titleID)
        }
    }

    /// Waits for the answers in flight. For tests.
    func waitForLoad() async {
        await loadTask?.value
    }

    private func arrange() {
        groups = StreamGroup.groups(of: choices, by: sort)
        var context = context
        context.lastChoice = lastChoice
        picks = StreamPicker.picks(from: choices, context: context)
        // Worth pointing out in the full list only if it should simply play; and only when
        // there is a choice to make.
        if let best = picks.first, best.standing <= .fewPeers, choices.count > 1 {
            suggested = best.choice
            suggestionTitle = lastChoice?.bestMatch(in: choices)?.id == best.id ? "Like Last Time" : "Recommended"
        } else {
            suggested = nil
        }
    }
}
