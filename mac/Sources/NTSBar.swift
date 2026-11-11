import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - API (undocumented, same endpoints nts.live uses)

let api = URL(string: "https://www.nts.live/api/v2")!
let liveStreams = ["1": "https://stream-relay-geo.ntslive.net/stream",
                   "2": "https://stream-relay-geo.ntslive.net/stream2"]

struct Media: Decodable {
    var backgroundMediumLarge: String?, pictureMedium: String?, pictureLarge: String?, pictureSmall: String?, iconWhite: String?, animationThumb: String?
    var thumb: URL? { (pictureSmall ?? pictureMedium ?? pictureLarge).flatMap(URL.init) }
    var wide: URL? { (backgroundMediumLarge ?? pictureLarge).flatMap(URL.init) }
}
struct Tag: Decodable { var value: String }
struct Details: Decodable {
    var name: String?, description: String?, locationLong: String?, showAlias: String?, episodeAlias: String?
    var media: Media?, genres: [Tag]?
    var frequency: String?   // shows: MONTHLY, WEEKLY…
    // archive episodes (/shows/x/episodes/y); strings so /live's embeds can't fail to decode
    var broadcast: String?, mixcloud: String?, audioSources: [Source]?
    struct Source: Decodable { var url: String? }
    var broadcastDate: Date? { broadcast.flatMap { try? Date($0, strategy: .iso8601) } }
    /// API path of this episode, e.g. shows/x/episodes/y
    var episodePath: String? { showAlias.flatMap { s in episodeAlias.map { "shows/\(s)/episodes/\($0)" } } }
}
struct Broadcast: Decodable {
    var broadcastTitle: String, startTimestamp: Date, endTimestamp: Date?
    // API titles carry HTML entities (e.g. &amp;)
    var title: String { broadcastTitle.htmlDecoded }
    var embeds: Embeds?
    struct Embeds: Decodable { var details: Details? }
}
struct Channel: Decodable, Identifiable {
    var channelName: String, now: Broadcast
    var upcoming: [Broadcast]   // API flattens the schedule into next, next2 … next17
    var next: Broadcast? { upcoming.first }
    var id: String { channelName }

    struct Key: CodingKey {
        var stringValue: String
        init(_ s: String) { stringValue = s }
        init(stringValue s: String) { stringValue = s }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        channelName = try c.decode(String.self, forKey: Key("channelName"))
        now = try c.decode(Broadcast.self, forKey: Key("now"))
        upcoming = (["next"] + (2...30).map { "next\($0)" }).compactMap { try? c.decode(Broadcast.self, forKey: Key($0)) }
    }
}
struct Track: Decodable, Identifiable {
    var uid: String?, artist: String?, title: String?, offset: Int?, duration: Int?
    var id: String { uid ?? "" }   // uid can be null; lists key rows by position anyway
}
struct Mixtape: Decodable, Identifiable {
    var mixtapeAlias: String, title: String, subtitle: String, audioStreamEndpoint: String, media: Media?
    var description: String?
    var id: String { mixtapeAlias }
}
struct Results<T: Decodable>: Decodable { var results: [T] }

func fetch<T: Decodable>(_ path: String) async throws -> [T] {
    try await fetchOne(path, as: Results<T>.self).results
}

func fetchOne<T: Decodable>(_ path: String, as: T.Type = T.self, query: [URLQueryItem] = []) async throws -> T {
    // API sends max-age=900 and CloudFront caches per header variant, so a show change can lag up to
    // 15 min. A timestamp query makes each request a cache miss (one small request a minute).
    let url = api.appending(path: path).appending(queryItems: query + [.init(name: "t", value: String(Int(Date().timeIntervalSince1970)))])
    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    d.dateDecodingStrategy = .iso8601
    return try d.decode(T.self, from: data)
}

/// Public token nts.live puts in window.nts_env (NTS_API_TOKEN) for resolve-stream.
let ntsToken = "48fhsdjEK7349fCJBS"

/// HLS link for an archive episode's SoundCloud/Mixcloud source, via nts.live's own resolver.
func resolveStream(_ source: String) async throws -> URL {
    let q = source.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? source
    var r = URLRequest(url: URL(string: "\(api)/resolve-stream?url=\(q)")!)
    r.setValue("Basic \(ntsToken)", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, resp) = try await URLSession.shared.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200, let hls = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["hls"] as? String, let u = URL(string: hls)
    else { throw APIError(errorDescription: "resolve-stream \(code): \(String(decoding: data.prefix(200), as: UTF8.self))") }
    return u
}

// MARK: - Store

struct Saved: Codable, Identifiable, Hashable {
    var id: String          // nts.live path: /shows/x or /shows/x/episodes/y
    var title: String
    var subtitle: String
    var image: URL?
    var isEpisode: Bool { id.contains("/episodes/") }
}

extension Saved {
    /// From the `article` of a My NTS Cloud Function result (a show, or an episode when episode_alias is set).
    init(article a: [String: Any]) {
        let show = a["show_alias"] as? String ?? "", ep = a["episode_alias"] as? String ?? ""
        id = ep.isEmpty ? "/shows/\(show)" : "/shows/\(show)/episodes/\(ep)"
        title = (a["name"] as? String ?? show).htmlDecoded
        if ep.isEmpty {   // shows: "Last episode 3 days ago" (the feed is already ordered by it)
            let last = ((a["latest_episode"] as? [String: Any])?["broadcast_date"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
            subtitle = last.map { "Last episode " + $0.formatted(.relative(presentation: .named)) } ?? ""
        } else { subtitle = a["broadcast_datestr"] as? String ?? "" }   // episodes: date only, as on iPhone
        image = ((a["image"] as? [String: Any])?["thumb"] as? String).flatMap(URL.init)
    }
}

enum SavedTab: String, CaseIterable { case hosts, episodes, history }

/// One lazily paged list from the account.
struct Feed { var items: [Saved] = [], cursor: Any? = nil, done = false, loading = false }

// MARK: - NTS account
// nts.live signs in with Firebase Auth (project nts-ios-app) and reads My NTS through callable
// Cloud Functions. Both are called over REST with the site's public web key; no Firebase SDK.

let firebaseKey = "AIzaSyA4Qp5AvHC8Rev72-10-_DY614w_bxUCJU"
let functions = "https://europe-west2-nts-ios-app.cloudfunctions.net"   // nts.live's _functions() region
let firestore = "https://firestore.googleapis.com/v1/projects/nts-ios-app/databases/(default)/documents"

/// Firestore REST field filter.
func filter(_ field: String, _ op: String, _ value: [String: Any]) -> [String: Any] {
    ["fieldFilter": ["field": ["fieldPath": field], "op": op, "value": value]]
}
func str(_ s: String) -> [String: Any] { ["stringValue": s] }

struct APIError: LocalizedError { var errorDescription: String? }

/// POST JSON and return the decoded reply. Google APIs report failures as {"error":{…}}
/// (runQuery wraps it in an array), so surface that message verbatim.
@MainActor func post(_ url: String, _ body: [String: Any]?, token: String? = nil, method: String = "POST") async throws -> Any {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = method
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, _) = try await URLSession.shared.data(for: r)
    let json = data.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: data)
    let err = (json as? [String: Any])?["error"] ?? (json as? [[String: Any]])?.first?["error"]
    if let e = err as? [String: Any] { throw APIError(errorDescription: (e["status"].map { "\($0): " } ?? "") + "\(e["message"] ?? e)") }
    return json
}

/// The episode a mixtape is playing now, as nts.live's footer player reads it (Firestore `mixtape_titles`).
/// Returns its title and nts.live path (/shows/x[/episodes/y]).
@MainActor func mixtapeTitle(_ alias: String) async throws -> (title: String, path: String?)? {
    let q: [String: Any] = ["from": [["collectionId": "mixtape_titles"]], "where": filter("mixtape_alias", "EQUAL", str(alias)),
                            "orderBy": [["field": ["fieldPath": "started_at"], "direction": "DESCENDING"]], "limit": 1]
    let r = try await post("\(firestore):runQuery?key=\(firebaseKey)", ["structuredQuery": q]) as? [[String: Any]] ?? []
    guard let f = (r.first?["document"] as? [String: Any])?["fields"] as? [String: Any] else { return nil }
    func v(_ k: String) -> String { (f[k] as? [String: Any])?["stringValue"] as? String ?? "" }
    guard !v("title").isEmpty else { return nil }
    let show = v("show_alias"), ep = v("episode_alias")
    return (v("title"), show.isEmpty ? nil : "/shows/\(show)" + (ep.isEmpty ? "" : "/episodes/\(ep)"))
}

/// The refresh token lives in the Keychain; it's the long-lived credential.
enum Keychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jessemorley.ntsbar",
         kSecAttrAccount as String: "nts-refresh-token"]
    }
    static var refreshToken: String? {
        get {
            var q = query, out: AnyObject?
            q[kSecReturnData as String] = true
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue else { return }
            var q = query
            q[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}


@Observable @MainActor final class Store {
    var live: [Channel] = []
    var mixtapes: [Mixtape] = []
    var playingID: String?
    var mixtapeNow: (title: String, path: String?)?   // the episode the playing mixtape is on
    var error: String?
    var tracklists: [String: [Track]] = [:]   // by episode path
    var saved: [Saved] = (UserDefaults.standard.data(forKey: "saved"))
        .flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "saved") }
    }
    let player = AVPlayer()
    var episode: (id: String, details: Details)?   // the archive episode loaded for playback
    var paused = false                              // archive only; live and mixtapes stop instead
    var resolving = false   // fetching an archive episode's stream, before the player has an item
    var buffering = false   // player is waiting for audio
    var loading: Bool { resolving || buffering }
    var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double { player.currentItem.map { $0.duration.seconds.isFinite ? $0.duration.seconds : 0 } ?? 0 }

    var email = UserDefaults.standard.string(forKey: "email")   // signed-in NTS account
    var feeds: [SavedTab: Feed] = [:]   // account lists, paged in as you scroll
    var problem: String?
    var followed: [String: Bool] = [:]   // account state of bookmarked show/episode ids, checked on demand
    @ObservationIgnored private var session: (token: String, uid: String, expires: Date)?
    @ObservationIgnored private var deviceIDs: [String] = []

    init() {
        Task {
            while true {
                do { live = try await fetch("live"); error = nil; if liveStreams[playingID ?? ""] != nil { nowPlaying() } } catch { self.error = "Can't reach NTS" }
                // poll every 60s, but also wake just after the earliest current show ends
                let ends = live.compactMap(\.now.endTimestamp).map { $0.timeIntervalSinceNow + 5 }.filter { $0 > 0 }
                try? await Task.sleep(for: .seconds(min(60, ends.min() ?? 60)))
            }
        }
        Task { mixtapes = (try? await fetch("mixtapes")) ?? []; await refreshMixtapeNow() }
        Task {
            // ponytail: polls every 30s; nts.live uses a Firestore onSnapshot listener, switch if the lag shows
            while true { await refreshMixtapeNow(); try? await Task.sleep(for: .seconds(30)) }
        }
        statusObserver = observeStatus()
        Task {
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification).map({ _ in () }) { ended() }
        }
        if !CommandLine.arguments.contains("--snapshot") { remoteCommands() }
    }

    /// Tapping the playing item stops it (pausing a live stream would just drift behind).
    func toggle(_ id: String, _ url: String) {
        defer { nowPlaying() }
        if playingID == id { if paused { pauseResume() } else { stop() }; return }
        guard let u = URL(string: url) else { return }
        listenStop()
        streamURL = u
        player.replaceCurrentItem(with: AVPlayerItem(url: u))
        player.play()
        playingID = id
        paused = false
        mixtapeNow = nil
        Task { await refreshMixtapeNow() }
    }

    @ObservationIgnored private var streamURL: URL?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?

    /// KVO, not publisher(for:).values: that async sequence drops changes emitted between awaits.
    /// nonisolated so the off-main KVO closure doesn't inherit @MainActor and trap.
    nonisolated private func observeStatus() -> NSKeyValueObservation {
        player.observe(\.timeControlStatus) { [weak self] p, _ in
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in self?.buffering = waiting }
        }
    }

    func refreshMixtapeNow() async {
        guard let id = playingID, mixtapes.contains(where: { $0.id == id }), let t = try? await mixtapeTitle(id), id == playingID else { return }
        if t.title != mixtapeNow?.title { mixtapeNow = t; nowPlaying() }
    }

    func stop() {
        listenStop(); player.pause(); playingID = nil
        nowPlaying()
    }

    /// Archive episodes resume where they paused; live streams and mixtapes reload at the live edge.
    func pauseResume() {
        defer { nowPlaying() }
        if !paused { listenStop(); player.pause() }
        else if episode?.id == playingID { player.play(); paused = false; listenStart(); return }
        else if let u = streamURL { player.replaceCurrentItem(with: AVPlayerItem(url: u)); player.play() }
        paused.toggle()
    }

    /// Archive episodes play in-app: tapping the playing one pauses or resumes it.
    func playEpisode(_ id: String) async {
        if playingID == id { pauseResume(); return }
        resolving = true; defer { resolving = false }
        do {
            let d: Details = try await fetchOne(String(id.dropFirst()))
            guard let source = d.audioSources?.first?.url ?? d.mixcloud else { throw APIError(errorDescription: "No audio for this episode") }
            let hls = try await resolveStream(source)
            episode = (id, d)
            toggle(id, hls.absoluteString)
            listenStart()
            if let item = player.currentItem {   // HLS duration arrives once the playlist loads
                Task { for await _ in item.publisher(for: \.duration).first(where: { $0.seconds > 0 }).values { nowPlaying() } }
            }
            problem = nil
        } catch { report(error) }
    }

    /// Shows an error under the tab bar, except cancellations: SwiftUI cancels a view's .task
    /// (bookmark check, page load) when the popover closes or the page changes mid-request.
    func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        problem = error.localizedDescription
    }

    func skip(_ seconds: Double) {
        let t = CMTime(seconds: min(max(0, position + seconds), duration), preferredTimescale: 600)
        Task { await player.seek(to: t); nowPlaying() }
    }

    var scrub: Double?   // 0…1 while dragging the tab divider over an archive episode
    var seekable: Bool { episode?.id == playingID && duration > 0 }
    /// Seeks to the dragged spot, holding the handle there until the seek lands.
    func endScrub() {
        guard let f = scrub else { return }
        Task { await player.seek(to: CMTime(seconds: f * duration, preferredTimescale: 600)); scrub = nil; nowPlaying() }
    }

    // MARK: Now Playing (Control Centre) and media keys / AirPods, routed through the in-app controls.
    private func remoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        let on = Store.on
        on(rc.playCommand) { [weak self] _ in if self?.paused == true { self?.pauseResume() } }
        on(rc.pauseCommand) { [weak self] _ in if self?.playingID != nil, self?.paused == false { self?.pauseResume() } }
        on(rc.togglePlayPauseCommand) { [weak self] _ in if self?.playingID != nil { self?.pauseResume() } }
        on(rc.stopCommand) { [weak self] _ in self?.stop() }
        rc.skipBackwardCommand.preferredIntervals = [30]
        rc.skipForwardCommand.preferredIntervals = [30]
        on(rc.skipBackwardCommand) { [weak self] _ in if self?.seekable == true { self?.skip(-30) } }
        on(rc.skipForwardCommand) { [weak self] _ in if self?.seekable == true { self?.skip(30) } }
        on(rc.changePlaybackPositionCommand) { [weak self] t in
            guard let self, seekable else { return }
            scrub = t / duration; endScrub()   // moves the in-app handle too
        }
    }

    /// MediaPlayer may call handlers off the main thread, so the handler itself is nonisolated and hops over.
    private nonisolated static func on(_ c: MPRemoteCommand, _ f: @escaping @MainActor @Sendable (Double) -> Void) {
        c.addTarget { e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in f(t) }
            return .success
        }
    }

    @ObservationIgnored private var artwork: (url: URL, art: MPMediaItemArtwork?)?
    /// MediaPlayer calls the image handler off the main thread, so it must not inherit the Store's actor.
    private nonisolated func makeArtwork(_ img: NSImage) -> MPMediaItemArtwork { MPMediaItemArtwork(boundsSize: img.size) { _ in img } }

    /// Publishes what's playing to Control Centre. Called on play/pause/seek/skip/stop and when /live moves on.
    func nowPlaying() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let center = MPNowPlayingInfoCenter.default(), rc = MPRemoteCommandCenter.shared()
        let archive = playingID != nil && episode?.id == playingID
        for c in [rc.skipBackwardCommand, rc.skipForwardCommand, rc.changePlaybackPositionCommand] { c.isEnabled = archive }
        guard let id = playingID else { center.nowPlayingInfo = nil; center.playbackState = .stopped; return }

        var title = "", artist = "", media: Media?
        if archive, let d = episode?.details {
            let date = (d.broadcastDate ?? .now).formatted(.dateTime.day(.twoDigits).month(.abbreviated).year())
            title = d.name ?? ""; artist = "NTS · " + [d.locationLong, date].compactMap { $0 }.joined(separator: ", "); media = d.media
        } else if let c = live.first(where: { $0.id == id }) {
            let d = c.now.embeds?.details
            title = c.now.title; artist = ["NTS \(id)", d?.locationLong].compactMap { $0 }.joined(separator: " · "); media = d?.media
        } else if let m = mixtapes.first(where: { $0.id == id }) {
            title = m.title; artist = [mixtapeNow?.title, "NTS Infinite Mixtape"].compactMap { $0 }.joined(separator: " · "); media = m.media
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
                                   MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
                                   MPNowPlayingInfoPropertyIsLiveStream: !archive]
        if archive {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        // NTS's image server crops to a centred square when the path says crop/ instead of resize/
        let url = (media?.pictureLarge ?? media?.pictureMedium).flatMap { URL(string: $0.replacing(/resize\/\d+x\d+/, with: "crop/500x500")) }
        if let url, artwork?.url == url { info[MPMediaItemPropertyArtwork] = artwork?.art }
        else if let url {   // load once per item, then republish
            artwork = (url, nil)
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data),
                      artwork?.url == url else { return }
                artwork = (url, makeArtwork(img))
                nowPlaying()
            }
        }
        center.nowPlayingInfo = info
        center.playbackState = paused ? .paused : .playing
    }

    func loadTracklist(_ episodePath: String) async {
        guard tracklists[episodePath] == nil else { return }
        tracklists[episodePath] = (try? await fetch(episodePath + "/tracklist")) ?? []
        await checkTracks(tracklists[episodePath] ?? [])
    }

    var savedTracks: Set<String> = []   // track uids saved to the account

    /// Which of these tracks are saved, as nts.live's tracklists ask (getMyTracksEurope with trackUids).
    func checkTracks(_ tracks: [Track]) async {
        let uids = tracks.compactMap(\.uid)
        guard email != nil, !uids.isEmpty else { return }
        do {
            let r = (try await post("\(functions)/getMyTracksEurope", ["data": ["trackUids": uids]], token: token().token) as? [String: Any])?["result"] as? [String: Any]
            for t in r?["results"] as? [[String: Any]] ?? [] { if let u = t["track_uid"] as? String { savedTracks.insert(u) } }
        } catch { report(error) }
    }

    /// Save or remove a track (createMyTrackEurope / deleteMyTrackEurope), optimistic with rollback.
    func toggleTrack(_ t: Track, episode: String) {
        guard let uid = t.uid else { return }
        let was = savedTracks.contains(uid)
        if was { savedTracks.remove(uid) } else { savedTracks.insert(uid) }
        let (show, ep) = aliases(episode)
        Task {
            do {
                let (fn, args): (String, [String: Any]) = was ? ("deleteMyTrackEurope", ["trackUid": uid])
                    : ("createMyTrackEurope", ["artistNames": [t.artist ?? ""], "episodeAlias": ep, "showAlias": show, "songTitle": t.title ?? "", "trackUid": uid])
                _ = try await post("\(functions)/\(fn)", ["data": args], token: token().token)
            } catch {
                if was { savedTracks.insert(uid) } else { savedTracks.remove(uid) }
                report(error)
            }
        }
    }

    func isSaved(_ id: String) -> Bool {
        guard email != nil else { return saved.contains { $0.id == id } }
        return followed[id] ?? [SavedTab.hosts, .episodes].contains { feeds[$0]?.items.contains { $0.id == id } == true }
    }

    /// Signed out: local. Signed in: the account's Firestore favourites, updated optimistically, rolled back on error.
    func toggleSave(_ item: Saved) {
        guard email != nil else {
            if isSaved(item.id) { saved.removeAll { $0.id == item.id } } else { saved.insert(item, at: 0) }
            return
        }
        let tab: SavedTab = item.isEpisode ? .episodes : .hosts
        let was = isSaved(item.id), before = (followed[item.id], feeds[tab])
        followed[item.id] = !was
        if was { feeds[tab]?.items.removeAll { $0.id == item.id } } else { feeds[tab]?.items.insert(item, at: 0) }
        Task {
            do {
                let (t, uid) = try await token()
                if was {   // duplicates exist, so delete every match
                    for name in try await favouriteDocs(item.id) {
                        _ = try await post("https://firestore.googleapis.com/v1/\(name)", nil, token: t, method: "DELETE")
                    }
                } else {
                    let (show, ep) = aliases(item.id)
                    // nts.live's writeFavourite
                    try await createDoc("favourites", ["show_alias": str(show), "episode_alias": str(ep),
                                                       "created_at": ["timestampValue": Date.now.ISO8601Format()]], token: t, uid: uid)
                }
                problem = nil
            } catch {
                followed[item.id] = before.0; feeds[tab] = before.1   // ponytail: restores the whole feed; pages loaded mid-request are refetched later
                report(error)
            }
        }
    }

    /// Reads the account state for bookmark icons once per id.
    func checkSaved(_ ids: [String]) async {
        guard email != nil else { return }
        for id in ids where followed[id] == nil {
            do { followed[id] = try await !favouriteDocs(id, limit: 1).isEmpty }
            catch { report(error); return }
        }
    }

    /// nts.live's createDocWithSession: the fields plus device_id and a minimal session, added to a collection.
    private func createDoc(_ collection: String, _ fields: [String: Any], token t: String, uid: String) async throws {
        let session: [String: Any] = ["device_id": str(uid), "client": str("NTSWebApp"),
                                      "session": ["mapValue": ["fields": ["firebase_user_uid": str(uid), "installation_id": ["nullValue": NSNull()]]]]]
        _ = try await post("\(firestore)/\(collection)", ["fields": fields.merging(session) { a, _ in a }], token: t)
    }

    // MARK: Archive listens, written like nts.live's writeArchivePlayStart/Stop; History is built from them.
    @ObservationIgnored private var listen: (id: String, started: Date)?

    private func playFields(_ id: String, playedAt: Date, listened: Int, position: Double, length: Double) -> [String: Any] {
        let (show, ep) = aliases(id)
        func int(_ n: Int) -> [String: Any] { ["integerValue": String(n)] }
        return ["show_alias": str(show), "episode_alias": str(ep),
                "played_at": ["timestampValue": playedAt.ISO8601Format()], "updated_at": ["timestampValue": Date.now.ISO8601Format()],
                "duration_s": int(listened), "current_position_s": int(Int(position)), "episode_duration_s": int(Int(length))]
    }

    /// Playback of an archive episode started or resumed.
    private func listenStart() {
        guard email != nil, listen == nil, let id = playingID, episode?.id == id,
              !CommandLine.arguments.contains("--snapshot") else { return }   // renders don't write listens
        listen = (id, .now)
        let f = playFields(id, playedAt: .now, listened: 0, position: position, length: 0)
        Task { do { let (t, uid) = try await token(); try await createDoc("archive_plays_start", f, token: t, uid: uid) } catch { report(error) } }
    }

    /// Paused, switched away, finished or quitting: records the listen. Reads the position now, before the item changes.
    @discardableResult func listenStop() -> Task<Void, Never>? {
        guard let l = listen else { return nil }
        listen = nil
        let secs = Int(Date.now.timeIntervalSince(l.started).rounded(.up))
        let f = playFields(l.id, playedAt: l.started, listened: secs, position: position, length: duration)
        return Task { do { let (t, uid) = try await token(); try await createDoc("archive_plays", f, token: t, uid: uid) } catch { report(error) } }
    }

    /// An archive episode reached its end: show play, back at the start.
    private func ended() {
        guard episode?.id == playingID, !paused else { return }
        listenStop()
        paused = true
        player.seek(to: .zero)
        nowPlaying()
    }

    private func aliases(_ id: String) -> (show: String, episode: String) {
        let p = id.split(separator: "/").map(String.init)   // shows/x[/episodes/y]
        return (p.count > 1 ? p[1] : "", p.count > 3 ? p[3] : "")
    }

    /// Firestore doc names of the favourite for a show or episode, found as nts.live's upsertFavourite does:
    /// device_id IN [uid + user_devices], show_alias ==, episode_alias == ("" for a followed show).
    private func favouriteDocs(_ id: String, limit: Int? = nil) async throws -> [String] {
        let (t, uid) = try await token()
        func query(_ q: [String: Any]) async throws -> [[String: Any]] {
            let r = try await post("\(firestore):runQuery", ["structuredQuery": q], token: t) as? [[String: Any]] ?? []
            return r.compactMap { $0["document"] as? [String: Any] }
        }
        if deviceIDs.isEmpty {   // nts.live's getUserDeviceIds: uid first, capped at 10
            let devs = try await query(["from": [["collectionId": "user_devices"]], "where": filter("firebase_user_uid", "EQUAL", str(uid))])
                .compactMap { (($0["fields"] as? [String: Any])?["device_id"] as? [String: Any])?["stringValue"] as? String }
            deviceIDs = Array(([uid] + devs.filter { $0 != uid }).prefix(10))
        }
        let (show, ep) = aliases(id)
        var q: [String: Any] = ["from": [["collectionId": "favourites"]], "where": ["compositeFilter": ["op": "AND", "filters": [
            filter("device_id", "IN", ["arrayValue": ["values": deviceIDs.map(str)]]),
            filter("show_alias", "EQUAL", str(show)), filter("episode_alias", "EQUAL", str(ep))]]]]
        if let limit { q["limit"] = limit }
        return try await query(q).compactMap { $0["name"] as? String }
    }

    func signIn(_ email: String, _ password: String) async {
        do {
            let r = try await post("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(firebaseKey)",
                                   ["email": email, "password": password, "returnSecureToken": true]) as? [String: Any] ?? [:]
            guard let token = r["idToken"] as? String, let uid = r["localId"] as? String else { throw APIError(errorDescription: "Unexpected sign-in reply") }
            Keychain.refreshToken = r["refreshToken"] as? String
            session = (token, uid, .now + 3000)   // ID tokens last an hour
            self.email = email
            UserDefaults.standard.set(email, forKey: "email")
            problem = nil
            feeds = [:]; followed = [:]; deviceIDs = []
        } catch { report(error) }
    }

    func signOut() {
        Keychain.refreshToken = nil
        session = nil; email = nil; feeds = [:]; problem = nil; followed = [:]; deviceIDs = []; savedTracks = []
        UserDefaults.standard.removeObject(forKey: "email")
    }

    /// A valid ID token, refreshed from the Keychain's refresh token when expired.
    private func token() async throws -> (token: String, uid: String) {
        if let s = session, s.expires > .now { return (s.token, s.uid) }
        guard let refresh = Keychain.refreshToken else { throw APIError(errorDescription: "Signed out, sign in again") }
        let r = try await post("https://securetoken.googleapis.com/v1/token?key=\(firebaseKey)",
                               ["grant_type": "refresh_token", "refresh_token": refresh]) as? [String: Any] ?? [:]
        guard let t = r["id_token"] as? String, let uid = r["user_id"] as? String else { throw APIError(errorDescription: "Unexpected token reply") }
        Keychain.refreshToken = r["refresh_token"] as? String ?? refresh
        session = (t, uid, .now + 3000)
        return (t, uid)
    }

    /// Next page of hosts or episodes, from the callable functions nts.live's My NTS pages use.
    func loadMore(_ tab: SavedTab) async {
        guard email != nil, feeds[tab]?.done != true, feeds[tab]?.loading != true else { return }
        feeds[tab, default: Feed()].loading = true
        defer { feeds[tab]?.loading = false }
        do {
            let t = try await token().token
            var added = 0
            repeat {   // the site re-asks when a page is empty but not final
                let cursor = feeds[tab]?.cursor ?? NSNull()
                let (fn, args, next): (String, [String: Any], String) = switch tab {
                case .hosts: ("getShowFavouritesEurope", ["order_by": "broadcast_date", "order_direction": "desc", "paginate": true, "cursor": cursor], "next_cursor")
                case .episodes: ("getBookmarkedEpisodesEurope", ["lastCreatedAt": cursor], "last_created_at")
                case .history: ("getHistoryEpisodesEurope", ["lastPlayedAt": cursor], "last_played_at")
                }
                let r = (try await post("\(functions)/\(fn)", ["data": args], token: t) as? [String: Any])?["result"] as? [String: Any] ?? [:]
                let meta = (r["metadata"] as? [String: Any])?["resultset"] as? [String: Any] ?? [:]
                var seen = Set(feeds[tab]?.items.map(\.id) ?? [])   // history repeats replayed episodes, even within a page
                let items = (r["results"] as? [[String: Any]] ?? []).compactMap { $0["article"] as? [String: Any] }
                    .map(Saved.init(article:)).filter { seen.insert($0.id).inserted }
                feeds[tab]?.items += items
                feeds[tab]?.cursor = meta[next]
                feeds[tab]?.done = meta["is_final_page"] as? Bool ?? true || meta[next] == nil || meta[next] is NSNull
                added = items.count
            } while added == 0 && feeds[tab]?.done == false
            problem = nil
        } catch { report(error) }
    }
}

// MARK: - App

@main struct NTSBarApp: App {
    @State private var store: Store

    init() {
        let s = Store()
        _store = State(initialValue: s)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // --playing <id> fakes what's playing (no audio); --tab now/mixtapes opens that page
            // an episode path (/shows/x/episodes/y) really loads it, muted
            if let j = args.firstIndex(of: "--playing"), j + 1 < args.count {
                let id = args[j + 1]
                if id.hasPrefix("/shows/") { s.player.isMuted = true; Task { await s.playEpisode(id) } } else { s.playingID = id }
            }
            snapshot(s, to: args[i + 1], page: args.contains("now") ? .nowPlaying : args.contains("mixtapes") ? .mixtapes : args.contains("saved") ? .saved : .live)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Popover().environment(store)
        } label: {
            Image(systemName: store.playingID == nil ? "radio" : "radio.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Popover: View {
    var page = Page.live
    var body: some View {
        RootView(page: page)
            .frame(width: 360)
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .background(.black)   // the window clips to its own native radius
    }
}

/// Dev aid: `NTSBar --snapshot out.png` renders the popover offscreen, saves a PNG, and quits.
@MainActor func snapshot(_ store: Store, to path: String, page: Page) {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        let view = NSHostingView(rootView: Popover(page: page).environment(store)
            .background(.black))
        let win = NSWindow(contentRect: .init(x: -3000, y: 0, width: 360, height: 800),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = view
        win.orderFront(nil)
        try? await Task.sleep(for: .seconds(7))  // let live data + artwork load
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}

/// Installed Univers Condensed faces (PostScript names vary by vendor, e.g. UniversLTStd-BoldCn).
let univers = NSFontManager.shared.availableFonts.filter {
    let n = $0.lowercased()
    return n.contains("univers") && (n.contains("cn") || n.contains("cond"))
}

extension Font {
    /// NTS look: Univers Condensed (what nts.live uses) if installed, else the system font's condensed width.
    static func nts(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let bold = weight == .bold || weight == .heavy || weight == .black || weight == .semibold
        let face = univers.first { ($0.lowercased().contains("bold") || $0.lowercased().contains("black")) == bold
                                   && !$0.lowercased().contains("obl") }
        if let face { return .custom(face, size: size) }
        return .system(size: size, weight: weight).width(.condensed)
    }
}

struct Rule: View {
    var body: some View { Rectangle().fill(.white.opacity(0.2)).frame(height: 1) }
}

/// Image that fills a fixed frame without pushing the layout wider.
struct Cover: View {
    let url: URL?
    var body: some View {
        Color(white: 0.12)
            .overlay { AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
            .clipped()
    }
}

// Layout measured from the NTS iPhone app (402pt wide), scaled to our 360pt popover.
let cardHeight: CGFloat = 326
let contentHeight = cardHeight * 2
let pageInset: CGFloat = 14   // page margin below artwork (16pt on iPhone)

func hhmm(_ d: Date) -> String {
    d.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                          timeZone: .current, calendar: .current))
}

extension String {
    /// API titles carry HTML entities (e.g. &amp;).
    var htmlDecoded: String { replacing("&amp;", with: "&").replacing("&#39;", with: "'").replacing("&quot;", with: "\"") }
    /// Uppercased, with U+2005 spaces: Univers Condensed kerns the plain space against W and "-",
    /// shrinking gaps ("SHOWW/", "18:00- 20:00"); CoreText applies those pairs even with kerning 0.
    var nts: String { uppercased().replacing(" ", with: "\u{2005}") }
}

enum Page: CaseIterable { case live, nowPlaying, mixtapes, saved
    var label: String {
        switch self { case .live: "LIVE"; case .nowPlaying: "NOW PLAYING"; case .mixtapes: "MIXTAPES"; case .saved: "MY NTS" }
    }
    var icon: String {
        switch self {
        case .live: "antenna.radiowaves.left.and.right"; case .nowPlaying: "waveform"
        case .mixtapes: "infinity"; case .saved: "person"
        }
    }
}

/// A bright band sweeping across the divider while audio loads.
struct Shimmer: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let x = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 480 - 120
            LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 120).offset(x: x)
                .frame(maxWidth: .infinity, alignment: .leading).clipped()
        }
    }
}

struct RootView: View {
    @Environment(Store.self) var store
    @State var page = Page.live
    @State private var barHover = false

    /// The divider doubles as the progress bar: live show or archive episode; solid for mixtapes, grey when idle.
    func progress(at now: Date) -> Double {
        if store.seekable { return store.scrub ?? store.position / store.duration }
        guard let id = store.playingID else { return 0 }   // nothing playing: all inactive grey
        guard let c = store.live.first(where: { $0.id == id }) else { return 1 }   // mixtapes: solid
        return fraction(c.now, at: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Page.allCases, id: \.self) { p in
                    Button { page = p } label: {
                        VStack(spacing: 4) {
                            Image(systemName: p.icon).font(.system(size: 19)).frame(height: 22)
                            Text(p.label.nts).font(.nts(10))
                        }
                        .frame(maxWidth: .infinity, minHeight: 54).contentShape(.rect)
                        .opacity(page == p ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let f = progress(at: ctx.date)
                Rectangle().fill(.white.opacity(store.loading ? 0.7 : 0.3)).frame(height: 1)   // loading: dimmer white under the shimmer
                    .overlay(alignment: .leading) { Rectangle().fill(.white).frame(width: store.loading ? 0 : 360 * f) }
                    .overlay { if store.loading { Shimmer() } }
                    .overlay(alignment: .leading) {   // archive episodes: a handle on hover, drag to seek
                        if store.seekable && (barHover || store.scrub != nil) {
                            Circle().fill(.white).frame(width: 10, height: 10).offset(x: 360 * f - 5)
                        }
                    }
            }
            .overlay {
                if store.seekable {
                    Color.clear.frame(height: 14).contentShape(.rect)
                        .onHover { barHover = $0 }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { store.scrub = min(1, max(0, $0.location.x / 360)) }
                            .onEnded { _ in store.endScrub() })
                }
            }
            .zIndex(1)   // handle and hit area overlap the page below
            if let err = store.problem {   // account failures (e.g. a rejected bookmark), on every page; click to dismiss
                Text(err).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 6)
                    .onTapGesture { store.problem = nil }
            }
            Group {
                switch page {
                case .live: LiveView()
                case .nowPlaying: NowPlayingView()
                case .mixtapes: MixtapesView()
                case .saved: SavedView()
                }
            }
            // Now Playing shrinks the window to its content; other pages keep the fixed height
            .frame(minHeight: page == .nowPlaying ? nil : contentHeight, maxHeight: contentHeight, alignment: .top)
        }
    }
}

// MARK: - Live

struct LiveView: View {
    @Environment(Store.self) var store

    var body: some View {
        VStack(spacing: 0) {
            if let e = store.error { Text(e.uppercased()).font(.nts(14)).opacity(0.6).padding() }
            ForEach(Array(store.live.enumerated()), id: \.element.id) { i, c in
                ChannelCard(channel: c)
            }
            if store.live.isEmpty && store.error == nil { ProgressView().frame(maxHeight: .infinity) }
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: .init(x: r.minX, y: r.minY)); p.addLine(to: .init(x: r.maxX, y: r.midY)); p.addLine(to: .init(x: r.minX, y: r.maxY)) }
    }
}

struct ChannelCard: View {
    @Environment(Store.self) var store
    let channel: Channel

    var body: some View {
        let d = channel.now.embeds?.details
        let playing = store.playingID == channel.id && !store.paused
        ZStack(alignment: .topLeading) {
            Cover(url: d?.media?.wide)
            Color.black.opacity(0.2)   // NTS dims the artwork slightly; no shadows on text
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    Text(channel.channelName).font(.nts(11)).foregroundStyle(.black)
                        .frame(width: 11, height: 12).background(.white)
                    Text((d?.locationLong ?? "").nts).font(.nts(12.5, .regular))
                        .padding(.leading, 2)
                }
                Text(channel.now.title.nts).font(.nts(21.5))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                if let end = channel.now.endTimestamp {
                    Text("\(hhmm(channel.now.startTimestamp)) - \(hhmm(end))".nts)
                        .font(.nts(12.5)).padding(.top, 5)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Button { store.toggle(channel.id, liveStreams[channel.id] ?? "") } label: {
                        Group {
                            if playing { Rectangle().frame(width: 34, height: 34).padding(3) }
                            else { Triangle().frame(width: 41, height: 40) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    SaveMenu(details: channel.now.embeds?.details, title: channel.now.title, date: channel.now.startTimestamp)
                }
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.top, 7).padding(.bottom, 9)
        }
        .frame(height: cardHeight)
    }
}

struct SaveMenu: View {
    @Environment(Store.self) var store
    let details: Details?, title: String, date: Date
    var size: CGFloat = 20

    var body: some View {
        let d = details
        if let show = d?.showAlias {
            let showItem = Saved(id: "/shows/\(show)", title: d?.name ?? title,
                                 subtitle: d?.locationLong ?? "", image: d?.media?.thumb)
            Menu {
                Button(store.isSaved(showItem.id) ? "Unfollow Show" : "Follow Show") { store.toggleSave(showItem) }
                if let ep = d?.episodeAlias {
                    let epItem = Saved(id: "/shows/\(show)/episodes/\(ep)", title: title,
                                       subtitle: date.formatted(date: .abbreviated, time: .omitted),
                                       image: d?.media?.thumb)
                    Button(store.isSaved(epItem.id) ? "Remove Episode" : "Save Episode") { store.toggleSave(epItem) }
                }
            } label: {
                Image(systemName: store.isSaved(showItem.id) ? "bookmark.fill" : "bookmark").font(.system(size: size))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.white)
            .task(id: "\(showItem.id)|\(d?.episodeAlias ?? "")|\(store.email ?? "")") {
                await store.checkSaved([showItem.id] + (d?.episodeAlias.map { ["/shows/\(show)/episodes/\($0)"] } ?? []))
            }
        }
    }
}

// MARK: - Mixtapes / Saved

struct Row: View {
    /// Episodes are playable: a play overlay on hover; the current one keeps pause (or play while paused).
    enum Playback { case none, playable, playing, paused }
    let image: URL?, title: String, subtitle: String
    var playback = Playback.none
    @State private var hovering = false
    var body: some View {
        let icon = playback == .playing || playback == .paused || (playback == .playable && hovering)
        HStack(spacing: 12) {
            Cover(url: image).frame(width: 52, height: 52)
                .overlay {
                    if icon {
                        Color.black.opacity(0.3)
                        Group {
                            if playback == .playing { PauseIcon() } else { Triangle() }
                        }
                        .frame(width: 14, height: 16)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                // sizes from the iPhone My NTS list (×0.896): bold title, regular uppercase date
                Text(title.nts).font(.nts(14)).lineLimit(2)
                if subtitle.hasPrefix("Last episode ") {   // hosts: grey, only the age bold
                    (Text("Last episode ".nts) + Text(String(subtitle.dropFirst(13)).nts).font(.nts(11)))
                        .font(.nts(11, .regular)).opacity(0.6).lineLimit(1)
                } else {
                    Text(subtitle.nts).font(.nts(11, .regular)).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// Two bars, sized by the frame it's given.
struct PauseIcon: View {
    var body: some View {
        GeometryReader { g in
            HStack(spacing: g.size.width / 3) { Rectangle(); Rectangle() }   // bars and gap in equal thirds, as on iPhone
        }
    }
}

struct MixtapesView: View {
    @Environment(Store.self) var store
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(spacing: 1), GridItem()], spacing: 1) {
                ForEach(store.mixtapes) { m in MixtapeTile(mixtape: m) }
            }
        }
    }
}

/// Square tile styled after nts.live's infinite mixtapes grid: dimmed artwork, play top-left, icon + title bottom-left.
struct MixtapeTile: View {
    @Environment(Store.self) var store
    let mixtape: Mixtape
    var body: some View {
        let playing = store.playingID == mixtape.id && !store.paused
        Button { store.toggle(mixtape.id, mixtape.audioStreamEndpoint) } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { Cover(url: mixtape.media?.pictureMedium.flatMap(URL.init)) }
                .overlay { Color.black.opacity(0.3) }
                .overlay(alignment: .topLeading) {
                    Group {
                        if playing { Rectangle().frame(width: 15, height: 15).padding(1) }
                        else { Triangle().frame(width: 17, height: 17) }
                    }
                    .padding(10)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        AsyncImage(url: mixtape.media?.iconWhite.flatMap(URL.init)) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                            .frame(width: 13, height: 13)
                        Text(mixtape.title.nts).font(.nts(15)).lineLimit(1)
                    }
                    .padding(10)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct SavedView: View {
    @Environment(Store.self) var store
    @State private var tab = CommandLine.arguments.contains("history") ? SavedTab.history : .hosts   // `--snapshot … --tab saved history`
    // a followed show's episodes, in place of the tabs; `--snapshot … --tab saved --show /shows/x` opens one
    @State private var show: Saved? = CommandLine.arguments.firstIndex(of: "--show").flatMap { i in
        CommandLine.arguments.indices.contains(i + 1) ? Saved(id: CommandLine.arguments[i + 1], title: "", subtitle: "") : nil
    }

    /// Signed in: the account's lists, paged in. Signed out: the local saves.
    var items: [Saved] {
        if store.email != nil { return store.feeds[tab]?.items ?? [] }
        return tab == .history ? [] : store.saved.filter { $0.isEpisode == (tab == .episodes) }
    }

    var body: some View {
        if let s = show { ShowView(show: s) { show = nil } } else { lists }
    }

    var lists: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SavedTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue.nts).font(.nts(14))
                            .frame(maxWidth: .infinity, minHeight: 36).contentShape(.rect)
                            .opacity(tab == t ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                }
            }
            Rule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.email == nil { AccountView() }
                    let loading = store.feeds[tab]?.loading == true
                    if tab == .history && store.email == nil {
                        empty("SIGN IN FOR HISTORY")
                    } else if items.isEmpty && !loading {
                        empty(tab == .history ? "NOTHING PLAYED YET" : "NOTHING SAVED YET")
                    }
                    ForEach(items) { s in
                        let web = URL(string: "https://www.nts.live" + s.id)!
                        Row(image: s.image, title: s.title, subtitle: s.subtitle,
                            playback: !s.isEpisode ? .none : store.playingID != s.id ? .playable : store.paused ? .paused : .playing)
                            // episodes play in-app; hosts open their episode list
                            .onTapGesture { if s.isEpisode { Task { await store.playEpisode(s.id) } } else { show = s } }
                            .contextMenu {
                                Button("Open on nts.live") { NSWorkspace.shared.open(web) }
                                if tab != .history { Button(tab == .hosts ? "Unfollow Show" : "Remove Episode") { store.toggleSave(s) } }
                            }
                            .onAppear { if s.id == items.last?.id { Task { await store.loadMore(tab) } } }
                        Rule()
                    }
                    if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16) }
                }
            }
            .task(id: "\(tab)\(store.email ?? "")") { await store.loadMore(tab) }
            HStack {
                if let e = store.email {
                    Text(e).font(.system(size: 11)).opacity(0.5).lineLimit(1)
                    Button("SIGN OUT".nts) { store.signOut() }.buttonStyle(.plain).font(.nts(13)).opacity(0.5)
                }
                Spacer()
                Button("QUIT") { Task { await store.listenStop()?.value; NSApp.terminate(nil) } }.buttonStyle(.plain).font(.nts(13)).opacity(0.5)
            }
            .padding(10)
        }
    }

    func empty(_ text: String) -> some View {
        Text(text.nts).font(.nts(16)).opacity(0.5).frame(maxWidth: .infinity).padding(.top, 60)
    }
}

/// An episode as in the iPhone My NTS Episodes list (×0.896): wide artwork with a play box in its corner,
/// title and date beside it, genres below, ⋯ menu bottom-right.
struct EpisodeRow: View {
    @Environment(Store.self) var store
    let id: String, d: Details
    var body: some View {
        let date = d.broadcastDate?.formatted(.dateTime.day(.twoDigits).month(.abbreviated).year()) ?? ""
        let web = URL(string: "https://www.nts.live" + id)!
        let item = Saved(id: id, title: d.name ?? "", subtitle: date, image: d.media?.thumb)
        HStack(alignment: .top, spacing: 10) {
            Cover(url: d.media?.wide).frame(width: 148, height: 93)
                .overlay(alignment: .bottomLeading) {
                    Group {
                        if store.playingID == id && !store.paused { PauseIcon().frame(width: 13, height: 15) }
                        else { Triangle().frame(width: 15, height: 17) }
                    }
                    .frame(width: 49, height: 45).background(.black.opacity(0.75))
                }
            VStack(alignment: .leading, spacing: 4) {
                Text((d.name ?? "").nts).font(.nts(14)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(date.nts).font(.nts(11, .regular))
                if let g = d.genres, !g.isEmpty {
                    Text(g.map(\.value).joined(separator: " • ").nts).font(.nts(10)).opacity(0.5).lineLimit(2).padding(.top, 2)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Menu {
                        Button(store.isSaved(id) ? "Remove Episode" : "Save Episode") { store.toggleSave(item) }
                        Button("Open on nts.live") { NSWorkspace.shared.open(web) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 20, height: 16)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.white)
                }
            }
            .frame(minHeight: 93)   // ⋯ sits level with the artwork's bottom edge
        }
        .padding(.horizontal, 9).padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { Task { await store.playEpisode(id) } }
    }
}

/// A followed show's archive, newest first, paged in; episodes play in-app like My NTS rows.
struct ShowView: View {
    @Environment(Store.self) var store
    let show: Saved, back: () -> Void
    @State private var episodes: [Details] = []
    @State private var done = false
    @State private var loading = false
    @State private var info: Details?   // the show itself: banner, location, frequency, description

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // banner as on the NTS iPhone show page: artwork, LOCATION · FREQUENCY, title + follow, description
                    NowHeader(image: info?.media?.wide, title: info?.name ?? show.title, titleSize: 22) {
                        HStack(spacing: 7) {
                            if let l = info?.locationLong { Text(l.nts).font(.nts(12.4)) }
                            if info?.locationLong != nil, info?.frequency != nil { Text("·").font(.nts(12.4)) }
                            if let f = info?.frequency { Text(f.nts).font(.nts(12.4, .regular)) }
                        }
                    } accessory: {
                        SaveMenu(details: info, title: info?.name ?? show.title, date: .now, size: 15)
                    }
                    .overlay(alignment: .topLeading) {
                        Button(action: back) {
                            Image(systemName: "chevron.left").font(.nts(17)).frame(width: 44, height: 44).contentShape(.rect)
                                .shadow(color: .black.opacity(0.6), radius: 4)
                        }
                        .buttonStyle(.plain)
                    }
                    if let desc = info?.description, !desc.isEmpty {
                        Text(desc).font(.system(size: 13)).padding(.horizontal, pageInset).padding(.top, 10)
                    }
                    Rule().padding(.horizontal, pageInset).padding(.top, 18)
                    SectionLabel(text: "Episodes", dim: false).padding(.top, -6)
                    ForEach(episodes, id: \.episodeAlias) { d in
                        let id = "/" + (d.episodePath ?? "")
                        EpisodeRow(id: id, d: d)
                            .onAppear { if d.episodeAlias == episodes.last?.episodeAlias { Task { await loadMore() } } }
                        Rule()
                    }
                    if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16) }
                }
            }
            .task { info = try? await fetchOne(String(show.id.dropFirst())) }
            .task { await loadMore() }
        }
    }

    func loadMore() async {
        guard !loading, !done else { return }
        loading = true; defer { loading = false }
        let limit = 12
        do {
            let page: [Details] = try await fetchOne(String(show.id.dropFirst()) + "/episodes", as: Results<Details>.self,
                query: [.init(name: "offset", value: String(episodes.count)), .init(name: "limit", value: String(limit))]).results
            episodes += page.filter { $0.episodePath != nil }
            done = page.count < limit
        } catch { store.report(error) }
    }
}

/// Sign-in form, shown above the local list while signed out.
struct AccountView: View {
    @Environment(Store.self) var store
    @State private var email = ""
    @State private var password = ""
    @State private var open = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if open {
                TextField("Email", text: $email).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password).onSubmit(submit)
                Button((busy ? "SIGNING IN…" : "SIGN IN").nts, action: submit).font(.nts(14))
                    .disabled(busy || email.isEmpty || password.isEmpty)
            } else {
                Button("SIGN IN TO NTS".nts) { open = true }.buttonStyle(.plain).font(.nts(14))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 9).padding(.top, 12)
    }

    func submit() {
        guard !busy else { return }
        busy = true
        Task { await store.signIn(email, password); password = ""; busy = false }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @Environment(Store.self) var store
    var body: some View {
        if let id = store.playingID, let c = store.live.first(where: { $0.id == id }) {
            ChannelNowView(channel: c)
        } else if let id = store.playingID, let m = store.mixtapes.first(where: { $0.id == id }) {
            MixtapeNowView(mixtape: m)
        } else if let e = store.episode, e.id == store.playingID {
            EpisodeNowView(id: e.id, d: e.details)
        } else {
            VStack(spacing: 12) {
                Triangle().frame(width: 30, height: 30).opacity(0.3)
                Text("NOTHING PLAYING".nts).font(.nts(18)).opacity(0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Artwork with the show info below it, as on the NTS iPhone show page (sizes measured from it, ×0.896).
struct NowHeader<Badge: View, Accessory: View>: View {
    let image: URL?, title: String
    var video: URL? = nil
    var titleSize: CGFloat = 16
    @ViewBuilder let badge: Badge
    @ViewBuilder let accessory: Accessory
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Cover(url: image).frame(height: 221)
                .overlay {
                    if let video {
                        // fades into the page like the NTS iPhone mixtape page
                        LoopingVideo(url: video)
                            .overlay { LinearGradient(colors: [.clear, .black], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom) }
                    }
                }
            badge.padding(.horizontal, pageInset).padding(.top, 16)
            HStack(alignment: .top, spacing: 16) {
                Text(title.nts).font(.nts(titleSize)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                accessory.padding(.trailing, 5)
            }
            .padding(.horizontal, pageInset).padding(.top, 8)
        }
    }
}

/// • [2] LONDON
struct ChannelBadge: View {
    let channel: String, location: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.red).frame(width: 5, height: 5)
            Text(channel).font(.nts(10)).foregroundStyle(.black).frame(width: 10, height: 10).background(.white)
            Text(location.nts).font(.nts(12.4, .regular))
        }
    }
}

struct SectionLabel: View {
    let text: String
    var dim = true
    var body: some View {
        Text(text.nts).font(.nts(13)).opacity(dim ? 0.5 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pageInset).padding(.top, 16).padding(.bottom, 6)
    }
}

/// Genre tags, description and the current/next track (live and archive episode pages).
struct EpisodeInfo: View {
    let details: Details?, tracks: [Track]?, current: Int?, openTracklist: () -> Void
    var body: some View {
        // Tag + description sizes measured from the NTS iPhone episode page (×0.896 for 360pt)
        if let genres = details?.genres, !genres.isEmpty {
            HStack(spacing: 7) {
                ForEach(genres.prefix(4), id: \.value) {
                    Text($0.value.nts).font(.nts(10)).opacity(0.85)
                        .padding(.horizontal, 9).frame(height: 29)
                        .overlay(Rectangle().strokeBorder(.white.opacity(0.33), lineWidth: 1))
                }
            }
            .padding(.horizontal, pageInset).padding(.top, 12)
        }
        if let desc = details?.description, !desc.isEmpty {
            Text(desc).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, pageInset).padding(.top, 13)
        }
        if let tracks, !tracks.isEmpty {
            Rule().padding(.horizontal, pageInset).padding(.top, 18)
            Button(action: openTracklist) {
                SectionLabel(text: "Playing now", dim: false).padding(.top, -6)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.right").font(.nts(13)).opacity(0.6).padding(.trailing, pageInset).padding(.top, 10)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // always three rows (previous, current, next; the first three before the first track starts):
            // the menu bar window doesn't grow while open, so the section mustn't change height
            let start = max(0, min((current ?? 0) - 1, tracks.count - 3))
            ForEach(start..<min(start + 3, tracks.count), id: \.self) { i in
                TrackRow(track: tracks[i], state: i == current ? .now : i < (current ?? -1) ? .past : .next, episode: details?.episodePath)
            }
        }
    }
}

/// Pause/play over the dimmed Now Playing artwork, as on the iPhone player (×0.896); ±30s for archive episodes.
struct PlayOverlay: View {
    @Environment(Store.self) var store
    var skips = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            HStack(spacing: 0) {
                if skips { control("gobackward.30") { store.skip(-30) } }
                Button { store.pauseResume() } label: {
                    Group {
                        if store.paused { Triangle().frame(width: 34, height: 39) }
                        else { PauseIcon().frame(width: 34, height: 39) }
                    }
                    .frame(width: 80, height: 80).contentShape(.rect)
                }
                if skips { control("goforward.30") { store.skip(30) } }
            }
            .buttonStyle(.plain)
        }
        .frame(height: 221)
    }

    func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 25, weight: .semibold)).frame(width: 80, height: 80).contentShape(.rect) }
    }
}

/// An archive episode playing in-app: like the live page, plus pause and a scrubber.
struct EpisodeNowView: View {
    @Environment(Store.self) var store
    let id: String, d: Details
    @State private var showTracklist = false

    var path: String { String(id.dropFirst()) }

    var body: some View {
        let tracks = store.tracklists[path]
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let pos = store.position, dur = store.duration
            let current = tracks?.lastIndex { Double($0.offset ?? .max) <= pos }
            if showTracklist, let tracks {
                TracklistView(tracks: tracks, current: current, episode: path) { showTracklist = false }
            } else {
                FitScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        let date = d.broadcastDate ?? .now
                        NowHeader(image: d.media?.wide, title: d.name ?? "") {
                            Text([d.locationLong, date.formatted(.dateTime.day(.twoDigits).month(.abbreviated).year())]
                                .compactMap { $0 }.joined(separator: " · ").nts).font(.nts(12.4, .regular))
                        } accessory: {
                            SaveMenu(details: d, title: d.name ?? "", date: date, size: 15)
                        }
                        .overlay(alignment: .top) { PlayOverlay(skips: true) }
                        HStack {
                            let at = store.scrub.map { $0 * dur } ?? pos
                            Text(clock(at))
                            Spacer()
                            Text("-" + clock(dur - at)).opacity(0.6)
                        }
                        .font(.nts(10.5, .regular)).padding(.horizontal, pageInset).padding(.top, 7)
                        EpisodeInfo(details: d, tracks: tracks, current: current) { showTracklist = true }
                        Spacer(minLength: 20)
                    }
                }
            }
        }
        .task(id: path) { await store.loadTracklist(path) }
    }

    func clock(_ s: Double) -> String { Duration.seconds(max(0, s)).formatted(.time(pattern: .hourMinuteSecond)) }
}

struct ChannelNowView: View {
    @Environment(Store.self) var store
    let channel: Channel
    @State private var showTracklist = false

    var body: some View {
        let b = channel.now, d = b.embeds?.details
        let tracks = d?.episodePath.flatMap { store.tracklists[$0] }
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(b.startTimestamp)
            let current = tracks?.lastIndex { Double($0.offset ?? .max) <= elapsed }
            if showTracklist, let tracks {
                TracklistView(tracks: tracks, current: current, episode: d?.episodePath) { showTracklist = false }
            } else {
                FitScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        let end = b.endTimestamp ?? ctx.date
                        NowHeader(image: d?.media?.wide, title: b.title) {
                            ChannelBadge(channel: channel.channelName, location: d?.locationLong ?? "")
                        } accessory: {
                            SaveMenu(details: channel.now.embeds?.details, title: channel.now.title, date: channel.now.startTimestamp, size: 15)
                        }
                        .overlay(alignment: .top) { PlayOverlay() }
                        HStack {
                            Text("\(hhmm(b.startTimestamp)) - \(hhmm(end))".nts)
                            Spacer()
                            Text("\(Int(end.timeIntervalSince(ctx.date) / 60)) MIN LEFT".nts).opacity(0.6)
                        }
                        .font(.nts(10.5, .regular)).padding(.horizontal, pageInset).padding(.top, 7)
                        EpisodeInfo(details: d, tracks: tracks, current: current) { showTracklist = true }

                        if let next = channel.next {
                            Rule().padding(.horizontal, pageInset).padding(.top, 18)
                            SectionLabel(text: "Next on \(channel.channelName)", dim: false).padding(.top, -6)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(hhmm(next.startTimestamp)).font(.nts(14, .regular)).opacity(0.6)
                                Text(next.title.nts).font(.nts(14)).lineLimit(2)
                            }
                            .padding(.horizontal, pageInset)
                        }

                        Spacer(minLength: 20)
                    }
                }
            }
        }
        .task(id: d?.episodePath) { if let p = d?.episodePath { await store.loadTracklist(p) } }
    }
}

func fraction(_ b: Broadcast, at now: Date) -> Double {
    let end = b.endTimestamp ?? now
    return max(0, min(1, now.timeIntervalSince(b.startTimestamp) / max(1, end.timeIntervalSince(b.startTimestamp))))
}

/// Muted, looping, aspect-filled video (the mixtapes' animated artwork).
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    // ponytail: one shared player outlives the view, so switching back to Now Playing shows frames
    // straight away instead of the still while a fresh player buffers. Only one mixtape plays at a time.
    @MainActor static let player: AVQueuePlayer = { let p = AVQueuePlayer(); p.isMuted = true; return p }()
    @MainActor static var looper: AVPlayerLooper?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVPlayerLayer(player: Self.player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if (Self.looper?.loopingPlayerItems.first?.asset as? AVURLAsset)?.url != url {
            Self.looper = AVPlayerLooper(player: Self.player, templateItem: AVPlayerItem(url: url))
        }
        Self.player.play()
    }
    static func dismantleNSView(_ v: NSView, coordinator: ()) { player.pause() }
}

/// Content at its natural height, scrolling only once it outgrows the space offered.
struct FitScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var height: CGFloat = contentHeight
    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, contentHeight))
    }
}

struct TracklistView: View {
    let tracks: [Track], current: Int?, episode: String?, back: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: back) {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.left").font(.nts(15)).frame(width: 44, height: 44)
                    Text("TRACKLIST".nts).font(.nts(18))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Rule()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // tracks repeat with the same uid (e.g. a jingle played twice), so key rows by position
                        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                            TrackRow(track: t, state: current == i ? .now : (current ?? -1) > i ? .past : .next, episode: episode)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
        }
    }
}

/// ⋯ menu on a track: save to the account (signed in), copy, search on Spotify.
struct TrackMenu: View {
    @Environment(Store.self) var store
    let track: Track, episode: String?
    var body: some View {
        let text = [track.artist, track.title].compactMap { $0 }.joined(separator: " - ")
        Menu {
            if store.email != nil, let uid = track.uid, let episode {
                Button(store.savedTracks.contains(uid) ? "Remove Track" : "Save Track") { store.toggleTrack(track, episode: episode) }
            }
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            Button("Search on Spotify") {
                // the Spotify app if installed, else the web player
                let q = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
                let app = URL(string: "spotify:search:\(q)")!
                NSWorkspace.shared.open(NSWorkspace.shared.urlForApplication(toOpen: app) != nil ? app : URL(string: "https://open.spotify.com/search/\(q)")!)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 20, height: 16)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.white)
    }
}

struct TrackRow: View {
    enum State { case past, now, next }
    let track: Track, state: State
    var episode: String?   // shows/x/episodes/y, for saving the track
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(.red).frame(width: 6, height: 6).padding(.top, 6).opacity(state == .now ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text((track.artist ?? "").nts).font(.nts(12)).lineLimit(1)
                Text(track.title ?? "").font(.system(size: 12)).opacity(0.75).lineLimit(1)
            }
            Spacer()
            TrackMenu(track: track, episode: episode).padding(.top, 2)
        }
        .padding(.horizontal, pageInset).padding(.vertical, 9)
        .background(state == .now ? Color.white.opacity(0.08) : .clear)
        .opacity(state == .past ? 0.4 : 1)
    }
}

struct MixtapeNowView: View {
    @Environment(Store.self) var store
    let mixtape: Mixtape
    var body: some View {
        FitScroll {
            VStack(alignment: .leading, spacing: 0) {
                NowHeader(image: mixtape.media?.wide, title: mixtape.title, video: mixtape.media?.animationThumb.flatMap(URL.init), titleSize: 22) {
                    AsyncImage(url: mixtape.media?.iconWhite.flatMap(URL.init)) { $0.resizable().interpolation(.high).antialiased(true).scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 26, height: 26)
                } accessory: { EmptyView() }
                .overlay(alignment: .top) { PlayOverlay() }
                Text(mixtape.subtitle).font(.nts(12))   // sentence case, unlike .nts
                    .padding(.horizontal, pageInset).padding(.top, 12)
                if let desc = mixtape.description {
                    Text(desc).font(.system(size: 13)).padding(.horizontal, pageInset).padding(.top, 6)
                }
                if store.playingID == mixtape.id, let now = store.mixtapeNow {
                    Rule().padding(.horizontal, pageInset).padding(.top, 18)
                    SectionLabel(text: "Playing now", dim: false).padding(.top, -6)
                    Button { if let p = now.path { NSWorkspace.shared.open(URL(string: "https://www.nts.live" + p)!) } } label: {
                        HStack(spacing: 8) {
                            Text(now.title.uppercased().nts).font(.nts(12)).frame(maxWidth: .infinity, alignment: .leading)
                            if now.path != nil { Image(systemName: "arrow.up.right").font(.system(size: 11)).opacity(0.6) }
                        }
                        .padding(.horizontal, pageInset).padding(.vertical, 9).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 20)
            }
        }
    }
}
