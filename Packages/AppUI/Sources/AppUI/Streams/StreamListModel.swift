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
    /// The stream to offer first: the one most like what was played last time for this title,
    /// else the first of the preferred quality, if there is either.
    public private(set) var suggested: StreamChoice?
    /// Why it is offered first.
    public private(set) var suggestionTitle = "Like Last Time"
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

    /// The quality to suggest when nothing was played for this title before; `nil` suggests nothing.
    @ObservationIgnored public var preferredQuality: StreamQuality?
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

    /// Forgets the list (the page moved on to another video, or away).
    public func clear() {
        loadTask?.cancel()
        generation += 1
        videoID = nil
        choices = []
        groups = []
        failedAddonNames = []
        suggested = nil
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

    /// The first stream of the preferred quality, in the order the add-ons gave them; `nil`
    /// when no quality is preferred or no stream has it.
    static func preferred(_ quality: StreamQuality?, in choices: [StreamChoice]) -> StreamChoice? {
        guard let quality else { return nil }
        return choices.first { $0.quality == quality }
    }

    private func arrange() {
        groups = StreamGroup.groups(of: choices, by: sort)
        if let match = lastChoice?.bestMatch(in: choices) {
            suggested = match
            suggestionTitle = "Like Last Time"
        } else {
            suggested = Self.preferred(preferredQuality, in: choices)
            suggestionTitle = "Your Preferred Quality"
        }
    }
}
