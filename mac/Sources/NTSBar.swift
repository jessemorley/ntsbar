import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
import Network

// MARK: - API (undocumented, same endpoints nts.live uses)

let api = URL(string: "https://www.nts.live/api/v2")!
let liveStreams = ["1": "https://stream-relay-geo.ntslive.net/stream",
                   "2": "https://stream-relay-geo.ntslive.net/stream2"]

struct Media: Decodable {
    var backgroundMediumLarge: String?, backgroundMedium: String?, pictureMedium: String?, pictureLarge: String?, pictureSmall: String?, iconWhite: String?, animationThumb: String?
    var thumb: URL? { (pictureSmall ?? pictureMedium ?? pictureLarge).flatMap(URL.init) }
    var wide: URL? { (backgroundMediumLarge ?? pictureLarge).flatMap(URL.init) }
    /// `wide` at 400px, for episode rows (148pt), so they don't decode an 800px banner each
    var wideSmall: URL? { backgroundMedium.flatMap(URL.init) ?? wide }
    var square: URL? { (pictureMedium ?? pictureLarge ?? pictureSmall).flatMap(URL.init) }
    /// NTS's image server crops to a centred square when the path says crop/ instead of resize/
    var cover: URL? { (pictureLarge ?? pictureMedium).flatMap { URL(string: $0.replacing(/resize\/\d+x\d+/, with: "crop/500x500")) } }
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
    var source: String? { audioSources?.first?.url ?? mixcloud }   // what resolve-stream turns into HLS
    /// API path of this episode, e.g. shows/x/episodes/y
    var episodePath: String? { showAlias.flatMap { s in episodeAlias.map { "shows/\(s)/episodes/\($0)" } } }
}
struct Broadcast: Decodable {
    var broadcastTitle: String, startTimestamp: Date, endTimestamp: Date?
    // API titles carry HTML entities (e.g. &amp;)
    var title: String { broadcastTitle.htmlDecoded }
    /// Reruns end " (R)"; the big titles drop it for the ReplayIcon, as on iPhone (small text keeps it).
    var isReplay: Bool { title.hasSuffix(" (R)") }
    var bareTitle: String { isReplay ? String(title.dropLast(4)) : title }
    var embeds: Embeds?
    struct Embeds: Decodable { var details: Details? }
    var links: [Link]?   // schedule only: …/api/v2/shows/x/episodes/y
    struct Link: Decodable { var href: String }
    var showPath: String? { links?.first.flatMap { $0.href.firstMatch(of: /\/shows\/[^\/?]+/) }.map { String($0.output) } }
}
/// /radio/schedule/{1,2}: this week and next, past slots included, one entry per UTC day.
struct ScheduleDay: Decodable { var broadcasts: [Broadcast] }
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
    // 15 min. On /live a timestamp query makes each request a cache miss (one small request a minute);
    // everything else (episode details, tracklists, show pages) is fine served from the CDN.
    let bust = path == "live" ? [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))] : []
    let url = api.appending(path: path).appending(queryItems: query + bust)
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

/// An error as a short line someone can act on, not the raw reply (Firebase codes, HTTP bodies).
func friendly(_ error: Error) -> String {
    if let u = error as? URLError { return u.code == .notConnectedToInternet ? "You're offline" : "Can't reach NTS" }
    if error is DecodingError { return "NTS sent something unexpected" }
    let m = error.localizedDescription
    if ["INVALID_LOGIN_CREDENTIALS", "INVALID_PASSWORD", "EMAIL_NOT_FOUND", "INVALID_EMAIL"].contains(where: m.contains) { return "Wrong email or password" }
    if m.contains("TOO_MANY_ATTEMPTS") { return "Too many attempts. Try again later" }
    if m.contains("UNAUTHENTICATED") || m.contains("TOKEN_EXPIRED") { return "Signed out. Sign in again" }
    if m.hasPrefix("resolve-stream") { return "Can't play this episode" }
    return m
}

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

// MARK: - Sonos (local UPnP on :1400, no account)

/// A Sonos room or group, addressed by its coordinator: only the coordinator takes transport commands.
/// The speaker fetches the stream itself, so this suits the MP3 live and mixtape streams; archive HLS stays on the Mac.
struct SonosRoom: Hashable {
    let name: String, host: String, uuid: String   // the coordinator's, which names its queue

    /// Every room on the network: any speaker found over Bonjour reports the whole household's groups.
    static func discover() async -> [SonosRoom] {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: .tcp)
        let hosts = AsyncStream<String> { c in
            b.browseResultsChangedHandler = { results, _ in
                for r in results { if case .bonjour(let t) = r.metadata, let h = t["location"].flatMap(URL.init(string:))?.host() { c.yield(h) } }
            }
            b.stateUpdateHandler = { s in switch s { case .failed, .cancelled: c.finish(); default: break } }
            b.start(queue: .main)
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(3)); b.cancel() }   // nothing found (or the Local Network prompt still up)
        defer { timeout.cancel(); b.cancel() }
        guard let host = await hosts.first(where: { _ in true }),
              let xml = try? await soap(host, "ZoneGroupTopology", "GetZoneGroupState") else { return [] }
        func attr(_ tag: Substring, _ k: String) -> String? {
            (try? Regex<(Substring, Substring)>(" \(k)=\"([^\"]*)\"")).flatMap { tag.firstMatch(of: $0)?.1 }.map(String.init)
        }
        let state = xml.replacing("&lt;", with: "<").replacing("&gt;", with: ">").replacing("&quot;", with: "\"").replacing("&amp;", with: "&")
        return state.matches(of: /<ZoneGroup Coordinator="([^"]+)"[^>]*>(.*?)<\/ZoneGroup>/.dotMatchesNewlines()).compactMap { g in
            let members = g.2.matches(of: /<ZoneGroupMember [^>]*>/).map(\.0)
            guard let lead = members.first(where: { attr($0, "UUID") == String(g.1) }),
                  let host = attr(lead, "Location").flatMap(URL.init(string:))?.host() else { return nil }
            var names: [String] = []   // a stereo pair's second speaker is Invisible and shares the room's name
            for m in members where attr(m, "Invisible") != "1" { if let n = attr(m, "ZoneName"), !names.contains(n) { names.append(n) } }
            return names.isEmpty ? nil : SonosRoom(name: names.joined(separator: " + "), host: host, uuid: String(g.1))
        }.sorted { $0.name < $1.name }
    }

    /// A stream as a radio station; a file (an archive episode, via EpisodeRelay) as a track, so it can pause and seek.
    func play(_ url: URL, title: String, art: URL? = nil, file: Bool = false) async throws {
        func esc(_ s: String) -> String { s.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&quot;") }
        let uri = file ? url.absoluteString : Self.uri(url.absoluteString)
        // audioBroadcast + the radio cdudn: the Sonos app shows the title as a station.
        // A track needs a <res> and a non-radio id, or the app shows "No content".
        let kind = file ? #"<upnp:class>object.item.audioItem.musicTrack</upnp:class><dc:creator>NTS</dc:creator><res protocolInfo="http-get:*:audio/mpeg:*">"# + esc(uri) + "</res>"
            : #"<upnp:class>object.item.audioItem.audioBroadcast</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc>"#
        let id = file ? #"id="-1" parentID="-1""# : #"id="R:0/0/0" parentID="R:0/0""#
        let didl = #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item "#
            + id + #" restricted="true"><dc:title>"# + esc(title) + "</dc:title>"
            + (art.map { "<upnp:albumArtURI>" + esc($0.absoluteString) + "</upnp:albumArtURI>" } ?? "") + kind + "</item></DIDL-Lite>"
        if file {   // played from the queue (replacing it): the Sonos app shows "No content" for a track set directly
            _ = try await Self.soap(host, "MediaRenderer/AVTransport", "RemoveAllTracksFromQueue", "<InstanceID>0</InstanceID>")
            _ = try await Self.soap(host, "MediaRenderer/AVTransport", "AddURIToQueue", "<InstanceID>0</InstanceID><EnqueuedURI>\(esc(uri))</EnqueuedURI><EnqueuedURIMetaData>\(esc(didl))</EnqueuedURIMetaData><DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>")
            _ = try await Self.soap(host, "MediaRenderer/AVTransport", "SetAVTransportURI", "<InstanceID>0</InstanceID><CurrentURI>x-rincon-queue:\(uuid)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
        } else {
            _ = try await Self.soap(host, "MediaRenderer/AVTransport", "SetAVTransportURI", "<InstanceID>0</InstanceID><CurrentURI>\(esc(uri))</CurrentURI><CurrentURIMetaData>\(esc(didl))</CurrentURIMetaData>")
        }
        try await resume()
    }

    func resume() async throws { _ = try await Self.soap(host, "MediaRenderer/AVTransport", "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>") }
    func pause() async throws { _ = try await Self.soap(host, "MediaRenderer/AVTransport", "Pause", "<InstanceID>0</InstanceID>") }

    /// Retried for a few seconds: a track that's still loading refuses to seek.
    func seek(_ seconds: Double) async throws {
        let s = Int(seconds), target = String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        for attempt in 0..<10 {
            do { _ = try await Self.soap(host, "MediaRenderer/AVTransport", "Seek", "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target>"); return }
            catch { if attempt == 9 { throw error }; try await Task.sleep(for: .milliseconds(500)) }
        }
    }

    /// Where the track is, whether it's PLAYING, PAUSED_PLAYBACK, STOPPED or TRANSITIONING, and which track it is.
    func position() async throws -> (seconds: Double, state: String, track: String?) {
        let state = try await Self.soap(host, "MediaRenderer/AVTransport", "GetTransportInfo", "<InstanceID>0</InstanceID>")
            .firstMatch(of: /<CurrentTransportState>([A-Z_]+)/).map { String($0.1) } ?? ""
        let info = try await Self.soap(host, "MediaRenderer/AVTransport", "GetPositionInfo", "<InstanceID>0</InstanceID>")
        let rel = info.firstMatch(of: /<RelTime>(\d+):(\d+):(\d+)/).map { Double(Int($0.1)! * 3600 + Int($0.2)! * 60 + Int($0.3)!) } ?? 0
        return (rel, state, info.firstMatch(of: /<TrackURI>([^<]*)/).map { String($0.1).replacing("&amp;", with: "&") })
    }

    /// How Sonos names a stream we gave it; it keeps this as CurrentURI while following the geo redirects itself.
    static func uri(_ url: String) -> String { "x-rincon-mp3radio://" + url.replacing(/^https?:\/\//, with: "") }

    /// What the room is playing (or starting) or has paused, nil when stopped.
    func currentURI() async throws -> (uri: String, playing: Bool)? {
        let state = try await Self.soap(host, "MediaRenderer/AVTransport", "GetTransportInfo", "<InstanceID>0</InstanceID>")
        let playing = state.contains("<CurrentTransportState>PLAYING") || state.contains("<CurrentTransportState>TRANSITIONING")
        guard playing || state.contains("<CurrentTransportState>PAUSED_PLAYBACK") else { return nil }
        let media = try await Self.soap(host, "MediaRenderer/AVTransport", "GetMediaInfo", "<InstanceID>0</InstanceID>")
        guard let uri = media.firstMatch(of: /<CurrentURI>([^<]*)/).map({ String($0.1).replacing("&amp;", with: "&") }) else { return nil }
        // an episode plays from the queue: the track it's on says which
        if uri.hasPrefix("x-rincon-queue:"), let track = try await position().track { return (track, playing) }
        return (uri, playing)
    }

    func stop() async throws { _ = try await Self.soap(host, "MediaRenderer/AVTransport", "Stop", "<InstanceID>0</InstanceID>") }

    /// The group's volume (0–100): all its rooms together, as the Sonos app's group slider.
    func volume() async throws -> Int {
        let r = try await Self.soap(host, "MediaRenderer/GroupRenderingControl", "GetGroupVolume", "<InstanceID>0</InstanceID>")
        guard let v = r.firstMatch(of: /<CurrentVolume>(\d+)/).flatMap({ Int($0.1) }) else { throw APIError(errorDescription: "Sonos volume unreadable") }
        return v
    }

    func setVolume(_ v: Int) async throws {
        // the snapshot keeps the rooms' levels in proportion as the group's moves
        _ = try await Self.soap(host, "MediaRenderer/GroupRenderingControl", "SnapshotGroupVolume", "<InstanceID>0</InstanceID>")
        _ = try await Self.soap(host, "MediaRenderer/GroupRenderingControl", "SetGroupVolume", "<InstanceID>0</InstanceID><DesiredVolume>\(v)</DesiredVolume>")
    }

    private static func soap(_ host: String, _ path: String, _ action: String, _ args: String = "") async throws -> String {
        let service = path.split(separator: "/").last!
        var r = URLRequest(url: URL(string: "http://\(host):1400/\(path)/Control")!, timeoutInterval: 5)
        r.httpMethod = "POST"
        r.setValue(#"text/xml; charset="utf-8""#, forHTTPHeaderField: "Content-Type")
        r.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        r.httpBody = Data(#"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
            .appending("<u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">\(args)</u:\(action)></s:Body></s:Envelope>").utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(errorDescription: "Sonos \(action) failed") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Serves an archive episode to a Sonos room as one plain MP3, on this Mac's LAN address, only while it plays there.
/// SoundCloud's HLS segments are byte ranges of a single MP3 whose signature covers any range, so each request
/// (Sonos seeks with Range) is fetched as pieces small enough for SoundCloud (≤150 KB, it refuses ~200 KB),
/// one at a time as the speaker reads: about 16 KB/s and one piece in memory.
@MainActor final class EpisodeRelay {
    private(set) var url: URL?   // what the speaker fetches, once started
    private(set) var seconds: Double = 0
    private var template = "", size = 0
    private let playlist: URL, refresh: () async throws -> URL
    /// Sonos ignores our DIDL for an HTTP MP3 and names it from its ID3 (else the filename, and the app says "No content"),
    /// so the served file starts with a tag of its own: byte offsets past it map to SoundCloud's MP3 shifted by its length.
    private var tag = Data()

    /// An ID3v2.3 tag with UTF-16 text frames.
    static func id3(_ frames: [String: String]) -> Data {
        func be(_ n: Int, synchsafe: Bool) -> [UInt8] {
            synchsafe ? [24, 16, 8, 0].map { UInt8(n >> ($0 / 8 * 7) & 0x7f) } : [24, 16, 8, 0].map { UInt8(n >> $0 & 0xff) }
        }
        var body = Data()
        for (id, text) in frames.sorted(by: { $0.key < $1.key }) {
            let value: [UInt8] = [1, 0xff, 0xfe] + text.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } + [0, 0]
            body += Data(id.utf8) + be(value.count, synchsafe: false) + [0, 0] + value
        }
        return Data("ID3".utf8) + [3, 0, 0] + be(body.count, synchsafe: true) + body
    }
    private var listener: NWListener?
    private var awake: NSObjectProtocol?
    private static let session = URLSession(configuration: .ephemeral)   // pieces kept out of the app's disk cache

    init(playlist: URL, refresh: @escaping () async throws -> URL) { self.playlist = playlist; self.refresh = refresh }

    /// Reads the playlist and starts listening; throws for a stream that isn't SoundCloud's MP3 ranges (play it on the Mac).
    /// `path` (the episode's id) goes in the URL so a relaunched app can tell what the room is playing,
    /// and `port` takes back the one in that URL, so the room carries on reading from the new relay.
    func start(for speaker: String, path: String, title: String, port wanted: UInt16? = nil) async throws {
        try await read(playlist)
        tag = Self.id3(["TIT2": title, "TPE1": "NTS"])
        // the address this Mac reaches the speaker from
        let probe = NWConnection(host: .init(speaker), port: 1400, using: .tcp)
        defer { probe.cancel() }
        let ip: String = try await withCheckedThrowingContinuation { c in
            probe.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    if case .hostPort(let h, _)? = probe.currentPath?.localEndpoint { c.resume(returning: "\(h)") } else { c.resume(throwing: APIError(errorDescription: "No local address")) }
                    probe.stateUpdateHandler = nil
                case .failed(let e), .waiting(let e): c.resume(throwing: e); probe.stateUpdateHandler = nil   // waiting: unreachable, it would retry forever
                default: break
                }
            }
            probe.start(queue: .main)
        }
        let tcp = NWParameters.tcp
        tcp.allowLocalEndpointReuse = true   // the last run's connections may still hold the port
        let l = try wanted.flatMap(NWEndpoint.Port.init(rawValue:)).map { try NWListener(using: tcp, on: $0) } ?? NWListener(using: tcp)
        listener = l
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.serve(c) } }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            l.stateUpdateHandler = { s in
                switch s {
                case .ready: c.resume(returning: l.port?.rawValue ?? 0); l.stateUpdateHandler = nil
                case .failed(let e): c.resume(throwing: e); l.stateUpdateHandler = nil
                default: break
                }
            }
            l.start(queue: .main)
        }
        url = URL(string: "http://\(ip):\(port)\(path).mp3")
    }

    /// While the room plays: no idle sleep, no App Nap. Paused, the Mac may sleep (resume then reads afresh).
    var playing = false {
        didSet {
            guard playing != oldValue else { return }
            if playing { awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Playing an episode on Sonos") }
            else if let a = awake { ProcessInfo.processInfo.endActivity(a); awake = nil }
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        playing = false
    }

    private func read(_ playlist: URL) async throws {
        let text = String(decoding: try await URLSession.shared.data(from: playlist).0, as: UTF8.self)
        let parts = text.split(separator: "\n").filter { $0.hasPrefix("http") }
        guard let first = parts.first, first.contains(/\/media\/\d+\/\d+\/\d+\//),
              let end = parts.last?.firstMatch(of: /\/media\/\d+\/\d+\/(\d+)\//).flatMap({ Int($0.1) })
        else { throw APIError(errorDescription: "Not an MP3 playlist") }
        template = String(first); size = end + 1
        seconds = text.matches(of: /#EXTINF:([\d.]+)/).compactMap { Double($0.1) }.reduce(0, +)
    }

    private func piece(_ from: Int, _ to: Int, retry: Bool = true) async throws -> Data {
        let u = URL(string: template.replacing(/\/media\/(\d+)\/\d+\/\d+\//) { "/media/\($0.1)/\(from)/\(to)/" })!
        let (data, resp) = try await Self.session.data(from: u)
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return data }
        guard retry else { throw APIError(errorDescription: "Episode piece refused") }
        try await read(try await refresh())   // signatures last an hour or so: a long pause outlives them
        return try await piece(from, to, retry: false)
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            Task { @MainActor in await self?.respond(c, head); c.cancel() }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) async {
        func send(_ d: Data) async throws {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                c.send(content: d, completion: .contentProcessed { e in if let e { k.resume(throwing: e) } else { k.resume() } })
            }
        }
        let size = tag.count + self.size, t = tag.count
        let range = head.firstMatch(of: /(?im)^range:\s*bytes=(\d+)-(\d*)/)
        let from = range.flatMap { Int($0.1) } ?? 0, to = min(range.flatMap { Int($0.2) } ?? size - 1, size - 1)
        guard from <= to else { try? await send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nConnection: close\r\n\r\n".utf8)); return }
        var h = (range == nil ? "HTTP/1.1 200 OK" : "HTTP/1.1 206 Partial Content") + "\r\nContent-Type: audio/mpeg\r\nAccept-Ranges: bytes\r\nContent-Length: \(to - from + 1)\r\nConnection: close\r\n"
        if range != nil { h += "Content-Range: bytes \(from)-\(to)/\(size)\r\n" }
        do {
            try await send(Data((h + "\r\n").utf8))
            guard !head.hasPrefix("HEAD") else { return }
            if from < t { try await send(tag[from...min(to, t - 1)]) }
            var at = max(from, t)
            while at <= to, listener != nil {   // a send fails once the speaker hangs up (it seeked or stopped)
                let end = min(at + 150_000 - 1, to)
                try await send(try await piece(at - t, end - t))
                at = end + 1
            }
        } catch {}
    }
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
    var mixtapeVideos: [String: URL] = [:]   // cached hover loops, by mixtape id
    var playingID: String?
    var mixtapeNow: (title: String, path: String?)?   // the episode the playing mixtape is on
    var error: String?
    var tracklists: [String: [Track]] = [:]   // by episode path
    var details: [String: Details] = [:]   // My NTS rows' full details, by id, so rows scrolled back into view don't refetch
    var saved: [Saved] = (UserDefaults.standard.data(forKey: "saved"))
        .flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "saved") }
    }
    let player = AVPlayer()
    var episode: (id: String, details: Details)?   // the archive episode loaded for playback
    var paused = false { didSet { relay?.playing = !paused } }   // archive only; live and mixtapes stop instead
    var resolving = false   // fetching an archive episode's stream, before the player has an item
    var buffering = false   // player is waiting for audio
    var loading: Bool { resolving || buffering }
    var pendingID: String?   // episode tapped but not yet audible, for its spinner
    func waiting(_ id: String) -> Bool { pendingID == id || (playingID == id && buffering) }
    var position: Double {
        if let c = castClock { return min(c.pos + (paused ? 0 : -c.at.timeIntervalSinceNow), duration > 0 ? duration : .infinity) }
        return seekTarget ?? (player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
    }
    var seekTarget: Double?   // held while a seek is in flight, so the tracklist highlight jumps straight there
    var duration: Double = 0   // stored, not read off the player: views must see it arrive (the mini player's seek bar)

    var email = UserDefaults.standard.string(forKey: "email")   // signed-in NTS account
    var feeds: [SavedTab: Feed] = [:]   // account lists, paged in as you scroll
    var problem: String?
    var streamError: String?   // shown in the mini player while the failed item sits paused
    var showTracklist = false   // Now Playing shows the tracklist in place of the episode page
    var followed: [String: Bool] = [:]   // account state of bookmarked show/episode ids, checked on demand
    var schedules: [String: [Broadcast]] = [:]   // by channel: this week and next (/radio/schedule)
    @ObservationIgnored private var schedulesAt = Date.distantPast
    var showEpisodes: [String: [Details]] = [:]   // a show's first page of episodes (raw), prefetched on hover
    @ObservationIgnored private var prefetching: Set<String> = []
    @ObservationIgnored private var session: (token: String, uid: String, expires: Date)?
    @ObservationIgnored private var deviceIDs: [String] = []

    init() {
        Task {
            while true {
                do { live = try await fetch("live"); error = nil; if liveStreams[playingID ?? ""] != nil { nowPlaying() } } catch { self.error = "Can't reach NTS" }
                Task { await loadSchedules() }   // throttled to every 15 min
                // poll every 60s, but also wake just after the earliest current show ends
                let ends = live.compactMap(\.now.endTimestamp).map { $0.timeIntervalSinceNow + 5 }.filter { $0 > 0 }
                try? await Task.sleep(for: .seconds(min(60, ends.min() ?? 60)))
            }
        }
        Task {
            mixtapes = (try? await fetch("mixtapes")) ?? []
            cacheImages(mixtapes.flatMap { [$0.media?.pictureMedium, $0.media?.iconWhite].map { $0.flatMap(URL.init) } })   // tiles + icons drawn at once
            await findRooms()   // at launch, so the remembered room is ready before the first play; after mixtapes, to recognise one playing there
            await refreshMixtapeNow()
            // the tiles' 120px hover loops (~4 MB in all), kept on disk so hover plays at once
            let dir = URL.cachesDirectory.appending(path: "NTSBar/mixtape-videos")   // NTSBar/ itself is URLSession's cache
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for m in mixtapes {
                guard let remote = m.media?.animationThumb.flatMap(URL.init) else { continue }
                let file = dir.appending(path: remote.lastPathComponent)   // names carry a content hash
                if !FileManager.default.fileExists(atPath: file.path),
                   let (tmp, _) = try? await URLSession.shared.download(from: remote) { try? FileManager.default.moveItem(at: tmp, to: file) }
                if FileManager.default.fileExists(atPath: file.path) { mixtapeVideos[m.id] = file }
            }
        }
        Task {
            // ponytail: polls every 30s; nts.live uses a Firestore onSnapshot listener, switch if the lag shows
            while true { await refreshMixtapeNow(); try? await Task.sleep(for: .seconds(30)) }
        }
        statusObserver = observeStatus()
        itemObserver = observeItem()
        Task {
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification).map({ _ in () }) { ended() }
        }
        Task {   // mid-play failures (connection dropped); the background video's looper posts these too, hence the item check
            for await (item, why) in NotificationCenter.default.notifications(named: AVPlayerItem.failedToPlayToEndTimeNotification)
                .map({ (($0.object as? AVPlayerItem).map(ObjectIdentifier.init),($0.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription) })
            where item == player.currentItem.map(ObjectIdentifier.init) { streamFailed(why) }
        }
        if !CommandLine.arguments.contains("--snapshot") { remoteCommands(); reconnects() }
        // logout/restart/shutdown: no time for a network write, so save the position for recoverListen next launch
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveOpenListen() }
        }
        if email != nil { Task { await loadMore(.hosts) }; Task { await recoverListen(); await loadProgress() } }   // My NTS opens on Hosts, and the schedule's following tab needs it
    }

    /// Tapping the playing item stops it (pausing a live stream would just drift behind).
    func toggle(_ id: String, _ url: String, at start: Double = 0) {
        defer { nowPlaying() }
        if playingID == id { if paused { pauseResume() } else { stop() }; return }
        guard let u = URL(string: url) else { return }
        listenStop()
        streamError = nil
        retries = 0; retrying = false   // a new stream's failures count afresh, even mid-wait
        noSonos = false
        streamURL = u
        duration = 0
        playingID = id
        load(u, at: start)
        paused = false
        mixtapeNow = nil
        Task { await refreshMixtapeNow() }
    }

    @ObservationIgnored private var streamURL: URL?
    /// When the episode's HLS was resolved. SoundCloud signs the playlist for about an hour and its pieces for about three,
    /// so a later load (resume, output switch, retry) asks for a fresh one first.
    @ObservationIgnored private var resolvedAt = Date.distantPast
    private var stale: Bool { -resolvedAt.timeIntervalSinceNow > 45 * 60 }

    var rooms: [SonosRoom] = []   // found at launch and again whenever the mini player shows
    var speaker: SonosRoom? { didSet { UserDefaults.standard.set(speaker?.name, forKey: "speaker") } }   // chosen output for live and mixtapes; nil plays on this Mac
    var cast: SonosRoom?   // the room actually playing our stream now
    var noSonos = false   // the playing episode can't be relayed (Mixcloud): rooms grey out until something else plays
    var volume: Int?   // the chosen room's, read when it's picked or the rooms are looked up again
    @ObservationIgnored private var relay: EpisodeRelay?   // set while an archive episode plays on Sonos
    @ObservationIgnored private var castClock: (pos: Double, at: Date)?   // that episode's position, as of a moment: counted here, corrected by watch
    @ObservationIgnored private var castCommandAt = Date.distantPast   // our last pause/resume/seek: a reading taken before it is stale

    func setVolume(_ v: Int) {
        guard let s = speaker else { return }
        volume = v
        Task { try? await s.setVolume(v) }
    }

    /// Starts the playing item's stream (an archive episode from `start` seconds): on the chosen Sonos room, else on the Mac.
    /// Live and mixtapes the speaker fetches itself; an episode goes through an EpisodeRelay.
    private func load(_ u: URL, at start: Double = 0) {
        if episode?.id == playingID, stale, let source = episode?.details.source {
            let id = playingID
            player.pause(); resolving = true
            Task {
                defer { resolving = false }
                let fresh = try? await resolveStream(source)
                guard playingID == id, !paused else { return }
                guard let fresh else { listenStop(); paused = true; streamError = "Can't reach NTS"; return nowPlaying() }
                streamURL = fresh; resolvedAt = .now
                load(fresh, at: start)
            }
            return
        }
        if let c = cast, c != speaker { stopCast(c) }
        dropRelay()   // the same room just takes the new URI, no Stop that could land after it
        guard let s = speaker else { playHere(u, at: start); return }
        player.pause(); player.replaceCurrentItem(with: nil)   // paused first: a playing player with no item reports waiting, which shows as loading
        cast = s
        let id = playingID
        guard episode?.id == id, let source = episode?.details.source else {
            let mix = mixtapes.first { $0.id == id }, show = live.first { $0.id == id }?.now
            let art = (mix?.media ?? show?.embeds?.details?.media)?.cover
            // a live stream's top line is its own "NTS 1 - show" metadata (follows the schedule); ours is the line under it
            Task { do { try await s.play(u, title: mix?.title ?? "NTS \(id ?? "")", art: art) } catch { castFailed(s, id) } }
            return
        }
        let r = EpisodeRelay(playlist: u) { try await resolveStream(source) }
        relay = r; castClock = (start, .now); r.playing = !paused
        Task {
            do { try await r.start(for: s.host, path: id ?? "/episode", title: episode?.details.name ?? "NTS") } catch {
                guard relay === r else { return r.stop() }
                stopCast(s)   // not SoundCloud's MP3 ranges (Mixcloud): the Mac plays it, and the room stops what it had on
                noSonos = true
                return playHere(u, at: start)
            }
            guard relay === r, let url = r.url else { return r.stop() }
            duration = r.seconds; nowPlaying()
            do {
                try await s.play(url, title: episode?.details.name ?? "NTS", art: episode?.details.media?.cover, file: true)
                if start > 0 { try await s.seek(start) }
                guard relay === r else { return }
                if paused { try await s.pause() }   // paused while it started
                castClock = (start, .now); pendingID = nil; nowPlaying()   // counted from when it actually starts
                watch(r, on: s)
            } catch { castFailed(s, id) }
        }
    }

    private func playHere(_ u: URL, at start: Double) {
        let item = AVPlayerItem(url: u)
        item.preferredForwardBufferDuration = 60   // left to itself an episode reads ~15 min ahead: +30 MB, not +15
        player.replaceCurrentItem(with: item)
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        player.play()
        guard episode?.id == playingID else { return }   // live and mixtapes have no duration
        Task {   // HLS duration arrives once the playlist loads
            for await d in item.publisher(for: \.duration).first(where: { $0.seconds > 0 }).values where player.currentItem === item {
                duration = d.seconds.isFinite ? d.seconds : 0; nowPlaying()
            }
        }
    }

    private func castFailed(_ s: SonosRoom, _ id: String?) {
        guard cast == s, playingID == id else { return }
        listenStop()
        if castClock != nil { castClock = (position, .now) }   // kept, paused: play carries on from here
        relay?.stop(); relay = nil
        cast = nil; paused = true; pendingID = nil; streamError = "Can't reach \(s.name)"; nowPlaying()
    }

    private func dropRelay() { relay?.stop(); relay = nil; castClock = nil }

    /// Every 5s while an episode plays on Sonos: corrects the position, and follows a pause, play or stop made in the Sonos app or on the speaker.
    private func watch(_ r: EpisodeRelay, on s: SonosRoom) {
        Task {
            while relay === r {
                try? await Task.sleep(for: .seconds(5))
                let asked = Date.now
                guard let (pos, state, track) = try? await s.position(), relay === r, castCommandAt < asked else { continue }
                // another source took the room (Spotify, the Sonos app): let it go, no Stop; play picks up here
                if state != "STOPPED", let track, track != r.url?.absoluteString {
                    if !paused { castClock = (position, .now); listenStop(); paused = true }
                    relay?.stop(); relay = nil; cast = nil; nowPlaying()
                    return
                }
                switch state {
                case "PLAYING": castClock = (pos, .now); if paused { paused = false; listenStart(); nowPlaying() }
                case "PAUSED_PLAYBACK": if !paused { castClock = (pos, .now); listenStop(); paused = true; nowPlaying() }
                case "STOPPED": ended()   // reached the end, or stopped from the Sonos app
                default: break
                }
            }
        }
    }

    private func stopCast(_ c: SonosRoom? = nil) {
        guard let c = c ?? cast else { return }
        if cast == c { cast = nil; dropRelay() }
        Task { try? await c.stop() }
    }

    /// Picks the remembered room back up by name: its coordinator's address can change (DHCP, regrouping).
    /// A remembered room that's offline stays remembered, the Mac plays meanwhile.
    func findRooms() async {
        guard !CommandLine.arguments.contains("--snapshot") else { return }   // a playing room would take over the snapshot
        rooms = await SonosRoom.discover()
        let name = speaker?.name ?? UserDefaults.standard.string(forKey: "speaker")
        if let r = rooms.first(where: { $0.name == name }), r != speaker { setSpeaker(r) }
        if let s = speaker, let v = try? await s.volume(), speaker == s { volume = v }   // the Sonos app or buttons may have moved it
        // The room still playing an NTS stream (from before a relaunch, or picked in the Sonos app): shown here so pause and stop work
        guard playingID == nil, let s = speaker, let (uri, playing) = try? await s.currentURI(), playingID == nil else { return }
        if let m = uri.wholeMatch(of: /http:\/\/[\d.]+:(\d+)(\/shows\/.+)\.mp3/), let port = UInt16(m.1) {
            return await adoptEpisode(String(m.2), uri: uri, port: port, on: s, playing: playing)
        }
        guard playing, let (id, url) = (liveStreams.map { ($0.key, $0.value) } + mixtapes.map { ($0.id, $0.audioStreamEndpoint) })
                .first(where: { SonosRoom.uri($0.1) == uri }) else { return }
        playingID = id; streamURL = URL(string: url); cast = s; paused = false; streamError = nil
        nowPlaying()
    }

    /// An episode the last run of the app was relaying (playing or paused): the relay comes back on the same address,
    /// so the room keeps reading, and the episode shows as playing there.
    private func adoptEpisode(_ id: String, uri: String, port: UInt16, on s: SonosRoom, playing: Bool) async {
        guard let d: Details = try? await fetchOne(String(id.dropFirst())), let source = d.source,
              let hls = try? await resolveStream(source), playingID == nil else { return }
        let r = EpisodeRelay(playlist: hls) { try await resolveStream(source) }
        // another Mac's relay, or the port's taken: not ours to pick up
        guard (try? await r.start(for: s.host, path: id, title: d.name ?? "NTS", port: port)) != nil, r.url?.absoluteString == uri, playingID == nil,
              let (pos, _, _) = try? await s.position() else { return r.stop() }
        episode = (id, d); playingID = id; streamURL = hls; resolvedAt = .now
        cast = s; relay = r; duration = r.seconds; paused = !playing; streamError = nil
        castClock = (pos, .now)
        if playing { listenStart() }
        watch(r, on: s)
        nowPlaying()
    }

    /// Moves whatever's playing to the new output straight away, an episode at the same spot. A paused one moves when resumed.
    func setSpeaker(_ s: SonosRoom?) {
        guard s != speaker else { return }
        speaker = s
        volume = nil
        if let s { Task { if let v = try? await s.volume(), speaker == s { volume = v } } }
        if playingID != nil, !paused, let u = streamURL { load(u, at: episode?.id == playingID ? position : 0) }
    }

    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?

    /// KVO, not publisher(for:).values: that async sequence drops changes emitted between awaits.
    /// nonisolated so the off-main KVO closure doesn't inherit @MainActor and trap.
    nonisolated private func observeStatus() -> NSKeyValueObservation {
        player.observe(\.timeControlStatus) { [weak self] p, _ in
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate, playing = p.timeControlStatus == .playing && p.currentItem?.status == .readyToPlay   // switching items briefly reports .playing for the old one
            Task { @MainActor in self?.buffering = waiting; if playing { self?.pendingID = nil; self?.retries = 0 } }
        }
    }

    /// Item can't open (bad URL, expired certificate, 404): status goes .failed.
    nonisolated private func observeItem() -> NSKeyValueObservation {
        player.observe(\.currentItem?.status) { [weak self] p, _ in
            guard let item = p.currentItem, item.status == .failed else { return }
            let why = item.error?.localizedDescription   // e.g. "The certificate for this server is invalid."
            Task { @MainActor in self?.streamFailed(why) }
        }
    }

    @ObservationIgnored private var retries = 0   // reloads since the stream last played
    @ObservationIgnored private var retrying = false   // one failure can report twice (item status and the mid-play notification)

    /// Live and mixtapes first reload a few times (2, 4, 8s apart): a Wi-Fi blip or waking from sleep drops them.
    /// Then, or for an archive episode, leaves the item in the mini player, paused, with the reason in place of its subtitle; play retries.
    func streamFailed(_ why: String?) {
        guard let id = playingID, !retrying else { return }
        if episode?.id != id, retries < 3, let u = streamURL {
            retries += 1
            retrying = true
            buffering = true   // the shimmer, while it waits
            Task { [wait = Double(1 << retries)] in
                try? await Task.sleep(for: .seconds(wait))
                retrying = false
                // stopped or paused meanwhile: the failed item reports no status change to clear the shimmer
                // (switched: the new item's status takes over)
                guard playingID == id, !paused, streamURL == u else { if playingID == nil || paused { buffering = false }; return }
                player.replaceCurrentItem(with: AVPlayerItem(url: u)); player.play()
            }
            return
        }
        listenStop(); player.pause(); paused = true; pendingID = nil
        if episode?.id == id { resolvedAt = .distantPast }   // likely expired: play resolves it afresh
        streamError = "Can't play stream" + (why.map { ". \($0)" } ?? "")
        nowPlaying()
    }

    func refreshMixtapeNow() async {
        guard let id = playingID, mixtapes.contains(where: { $0.id == id }), let t = try? await mixtapeTitle(id), id == playingID else { return }
        if t.title != mixtapeNow?.title { mixtapeNow = t; nowPlaying() }
    }

    func stop() {
        listenStop(); player.pause(); stopCast(); playingID = nil; pendingID = nil
        nowPlaying()
    }

    /// Archive episodes resume where they paused; live streams and mixtapes reload at the live edge.
    /// An episode on Sonos pauses there; one whose output changed while paused resumes on the new one, at the same spot.
    func pauseResume() {
        defer { nowPlaying() }
        let archive = episode?.id == playingID
        if !paused {
            listenStop()
            if relay != nil, let c = cast { castCommandAt = .now; castClock = (position, .now); paused = true; Task { try? await c.pause() }; return }
            player.pause(); stopCast()
        } else if archive, streamError == nil, relay != nil ? cast == speaker : speaker == nil && player.currentItem != nil && -resolvedAt.timeIntervalSinceNow < 150 * 60 {   // the player's pieces expire too
            if relay != nil, let c = cast { castCommandAt = .now; castClock = (position, .now); Task { try? await c.resume() } } else { player.play() }
            paused = false; listenStart(); return
        } else if let u = streamURL { load(u, at: archive ? position : 0) }   // a failed episode carries on where it stopped
        paused.toggle()
        streamError = nil
        if archive, !paused { listenStart() }
    }

    /// Archive episodes play in-app: tapping the playing one pauses or resumes it.
    func playEpisode(_ id: String) async {
        if playingID == id { pauseResume(); return }
        resolving = true; pendingID = id
        defer { resolving = false }   // pendingID clears once audio actually plays (observeStatus), so the spinner doesn't blink at the hand-off
        do {
            let d: Details = try await fetchOne(String(id.dropFirst()))
            guard let source = d.source else { throw APIError(errorDescription: "No audio for this episode") }
            async let saved = email == nil ? nil : try? resumePoint(id)   // looked up while the stream resolves
            let hls = try await resolveStream(source)
            // ponytail: server wins when it answers; a just-paused write still in flight can read stale. Compare timestamps if that bites
            let start = await saved ?? progress[id]?.pos ?? 0
            resolvedAt = .now
            episode = (id, d)
            toggle(id, hls.absoluteString, at: start)
            listenStart()
            problem = nil
        } catch { if pendingID == id { pendingID = nil }; report(error) }
    }

    /// Shows an error under the tab bar, except cancellations: SwiftUI cancels a view's .task
    /// (bookmark check, page load) when the popover closes or the page changes mid-request.
    func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        problem = friendly(error)
    }

    /// Waking from sleep or a network coming back: refresh at once rather than on the next poll.
    private func reconnects() {
        Task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification).map({ _ in () }) { reconnect() }
        }
        Task {
            var online = true
            for await path in NWPathMonitor() {
                if path.status == .satisfied, !online { reconnect() }
                online = path.status == .satisfied
            }
        }
    }

    func reconnect() {
        Task { if let l: [Channel] = try? await fetch("live") { live = l; error = nil } }
        Task { await refreshMixtapeNow() }
        // a live stream or mixtape that ran out of retries while offline plays again; an episode keeps its error until play
        if playingID != nil, episode?.id != playingID, streamError != nil { pauseResume() }
    }

    func skip(_ seconds: Double) { seek(to: position + seconds) }
    func seek(to seconds: Double) {
        let s = min(max(0, seconds), duration)
        if relay != nil, let c = cast { castCommandAt = .now; castClock = (s, .now); Task { try? await c.seek(s) }; return nowPlaying() }
        seekTarget = s
        // exact: the default tolerance lands on the segment before, i.e. the end of the previous track
        Task { await player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); seekTarget = nil; nowPlaying() }
    }

    var scrub: Double?   // 0…1 while dragging the tab divider over an archive episode
    var seekable: Bool { episode?.id == playingID && duration > 0 }
    /// Seeks to the dragged spot, holding the handle there until the seek lands.
    func endScrub() {
        guard let f = scrub else { return }
        if relay != nil { seek(to: f * duration); scrub = nil; return }
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
        let url = media?.cover
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

    /// Hovering a row that opens a show: its details, banner, first page of episodes and the first few episodes' artwork,
    /// so the push slides in with them drawn. Fetched side by side; whatever fails the show page loads itself.
    func hoverShow(_ id: String, _ inside: Bool) {
        if inside {
            hoverTask?.cancel(); hovered = id
            hoverTask = Task { if (try? await Task.sleep(for: .milliseconds(150))) != nil { prefetchShow(id) } }   // rows passed over fetch nothing
        } else if hovered == id { hoverTask?.cancel() }
    }
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var hovered: String?

    private func prefetchShow(_ id: String) {
        guard prefetching.insert(id).inserted else { return }
        Task {
            if details[id] == nil { details[id] = try? await fetchOne(String(id.dropFirst())) }
            cacheImages([details[id]?.media?.wide])
        }
        Task {
            if showEpisodes[id] == nil { showEpisodes[id] = try? await fetchEpisodes(id, offset: 0) }
            cacheImages((showEpisodes[id] ?? []).prefix(3).map(\.media?.wideSmall))   // what fits below the banner
        }
    }

    /// Warms the shared image cache, side by side.
    private func cacheImages(_ urls: [URL?]) {
        for case let u? in urls { Task { _ = await loadImage(u) } }
    }

    /// Both channels' schedules, refetched once over 15 min old (the API's max-age); a failure retries next call.
    func loadSchedules() async {
        guard schedulesAt < .now - 900 else { return }
        schedulesAt = .now   // also keeps a second caller from fetching alongside
        do {
            try await withThrowingTaskGroup(of: (String, [ScheduleDay]).self) { g in   // channels side by side
                for ch in liveStreams.keys { g.addTask { (ch, try await fetch("radio/schedule/\(ch)")) } }
                for try await (ch, days) in g { schedules[ch] = days.flatMap(\.broadcasts) }
            }
        } catch { schedulesAt = .distantPast; self.error = "Can't reach NTS" }   // the live poll clears it and retries
    }

    /// Pages in the whole hosts feed when signed in, so isSaved answers for every followed show.
    func loadFollowedShows() async {
        guard email != nil else { return }
        var n = -1
        while feeds[.hosts]?.done != true {
            if feeds[.hosts]?.loading == true {   // a page already on its way (launch, My NTS): wait for it
                guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
                continue
            }
            let count = feeds[.hosts]?.items.count ?? 0
            if count == n { return }   // the last page added nothing (failed)
            n = count
            await loadMore(.hosts)
        }
    }

    /// The hover-prefetched first page of a show's episodes, handed over once so the next open refetches it fresh.
    func takePrefetchedEpisodes(_ id: String) -> [Details] {
        prefetching.remove(id)
        return showEpisodes.removeValue(forKey: id) ?? []
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
    var progress: [String: (pos: Double, length: Double)] = [:]   // by episode id: where the account last left it

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
        let started = Date.now
        listen = (id, started)
        let f = playFields(id, playedAt: .now, listened: 0, position: position, length: 0)
        Task { do { let (t, uid) = try await token(); try await createDoc("archive_plays_start", f, token: t, uid: uid) } catch { report(error) } }
        // plays are written only on pause/resume/stop, as nts.live does; a crash loses at most a minute (see recoverListen)
        Task { while listen?.started == started { saveOpenListen(); try? await Task.sleep(for: .seconds(60)) } }
    }

    /// The open listen, kept locally (no Firestore writes) so a crash, force quit or shutdown can be recorded next launch.
    private func saveOpenListen() {
        guard let l = listen else { return }
        UserDefaults.standard.set(["id": l.id, "started": l.started, "saved": Date.now, "position": position, "length": duration], forKey: "openListen")
    }

    /// Records a listen the app didn't get to (from saveOpenListen); kept until the write succeeds.
    private func recoverListen() async {
        guard let o = UserDefaults.standard.dictionary(forKey: "openListen"), let id = o["id"] as? String, let started = o["started"] as? Date,
              let saved = o["saved"] as? Date, let pos = o["position"] as? Double, let length = o["length"] as? Double else { return }
        let f = playFields(id, playedAt: started, listened: Int(saved.timeIntervalSince(started).rounded(.up)), position: pos, length: length)
        do { let (t, uid) = try await token(); try await createDoc("archive_plays", f, token: t, uid: uid) } catch { return }
        if (UserDefaults.standard.dictionary(forKey: "openListen")?["started"] as? Date) == started {   // not a listen begun since
            UserDefaults.standard.removeObject(forKey: "openListen")
        }
        if length > 0, progress[id] == nil { progress[id] = (pos, length) }
    }

    /// Paused, switched away, finished or quitting: records the listen. Reads the position now, before the item changes.
    @discardableResult func listenStop() -> Task<Void, Never>? {
        guard let l = listen else { return nil }
        listen = nil
        UserDefaults.standard.removeObject(forKey: "openListen")
        let secs = Int(Date.now.timeIntervalSince(l.started).rounded(.up))
        let f = playFields(l.id, playedAt: l.started, listened: secs, position: position, length: duration)
        if duration > 0 { progress[l.id] = (position, duration) }
        return Task { do { let (t, uid) = try await token(); try await createDoc("archive_plays", f, token: t, uid: uid) } catch { report(error) } }
    }

    /// An archive episode reached its end: show play, back at the start.
    private func ended() {
        guard episode?.id == playingID, !paused else { return }
        listenStop()
        paused = true
        if castClock != nil { castClock = (0, .now) }   // on Sonos, play starts the stopped track over
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
        try await myDocs("favourites", id, limit: limit).compactMap { $0["name"] as? String }
    }

    /// Where the account last left this episode (any device: nts.live, iPhone, here), as nts.live's readArchivePlays finds plays.
    /// nil when never played or played to (near) the end.
    private func resumePoint(_ id: String) async throws -> Double? {
        func val(_ f: [String: Any], _ k: String) -> String? { (f[k] as? [String: Any]).flatMap { $0["integerValue"] ?? $0["timestampValue"] } as? String }
        // ponytail: newest picked here, not orderBy (that needs a composite index); fine for the handful of plays per episode
        guard let last = try await myDocs("archive_plays", id).compactMap({ $0["fields"] as? [String: Any] })
                .max(by: { (val($0, "updated_at") ?? "") < (val($1, "updated_at") ?? "") }),
              let pos = val(last, "current_position_s").flatMap(Double.init), pos > 0 else { return nil }
        let length = val(last, "episode_duration_s").flatMap(Double.init) ?? 0
        return length > 0 && pos > length - 30 ? nil : pos
    }

    /// How far the account got through its recently played episodes (nts.live's readArchivePlays: newest first), for the rows' bars.
    func loadProgress() async {
        guard email != nil, let docs = try? await myDocs("archive_plays", nil, newest: 300) else { return }
        var p: [String: (pos: Double, length: Double)] = [:]
        for d in docs.compactMap({ $0["fields"] as? [String: Any] }) {
            func val(_ k: String) -> String? { (d[k] as? [String: Any]).flatMap { $0["integerValue"] ?? $0["stringValue"] } as? String }
            guard let show = val("show_alias"), let ep = val("episode_alias"), !ep.isEmpty,
                  let pos = val("current_position_s").flatMap(Double.init), let length = val("episode_duration_s").flatMap(Double.init), length > 0
            else { continue }
            let id = "/shows/\(show)/episodes/\(ep)"
            if p[id] == nil { p[id] = (pos, length) }   // newest play wins
        }
        progress.merge(p) { mine, _ in mine }   // this session's own listens are newer
    }

    /// The account's docs in a collection, from all its devices: device_id IN [uid + user_devices], and for a show or episode
    /// show_alias ==, episode_alias ==; or with `newest`, the latest that many by played_at.
    private func myDocs(_ collection: String, _ id: String?, limit: Int? = nil, newest: Int? = nil) async throws -> [[String: Any]] {
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
        let devices = filter("device_id", "IN", ["arrayValue": ["values": deviceIDs.map(str)]])
        var q: [String: Any] = ["from": [["collectionId": collection]], "where": devices]
        if let id {
            let (show, ep) = aliases(id)
            q["where"] = ["compositeFilter": ["op": "AND", "filters": [devices, filter("show_alias", "EQUAL", str(show)), filter("episode_alias", "EQUAL", str(ep))]]]
        }
        if let newest { q["orderBy"] = [["field": ["fieldPath": "played_at"], "direction": "DESCENDING"]]; q["limit"] = newest }   // the site's index
        if let limit { q["limit"] = limit }
        return try await query(q)
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
            feeds = [:]; followed = [:]; deviceIDs = []; progress = [:]
            await loadProgress()
        } catch { report(error) }
    }

    func signOut() {
        Keychain.refreshToken = nil
        session = nil; email = nil; feeds = [:]; problem = nil; followed = [:]; deviceIDs = []; savedTracks = []; progress = [:]
        UserDefaults.standard.removeObject(forKey: "email")
    }

    @ObservationIgnored private var refreshing: Task<(token: String, uid: String), Error>?

    /// A valid ID token, refreshed from the Keychain's refresh token when expired.
    /// Calls that arrive mid-refresh (a page of bookmark checks) wait on the same one.
    private func token() async throws -> (token: String, uid: String) {
        if let s = session, s.expires > .now { return (s.token, s.uid) }
        if let refreshing { return try await refreshing.value }
        let task = Task { () throws -> (token: String, uid: String) in
            guard let refresh = Keychain.refreshToken else { throw APIError(errorDescription: "Signed out, sign in again") }
            let r = try await post("https://securetoken.googleapis.com/v1/token?key=\(firebaseKey)",
                                   ["grant_type": "refresh_token", "refresh_token": refresh]) as? [String: Any] ?? [:]
            guard let t = r["id_token"] as? String, let uid = r["user_id"] as? String else { throw APIError(errorDescription: "Unexpected token reply") }
            Keychain.refreshToken = r["refresh_token"] as? String ?? refresh
            session = (t, uid, .now + 3000)
            return (t, uid)
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
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
                let results = r["results"] as? [[String: Any]] ?? []
                var seen = Set(feeds[tab]?.items.map(\.id) ?? [])   // history repeats replayed episodes, even within a page
                let items = results.compactMap { $0["article"] as? [String: Any] }.map(Saved.init(article:)).filter { seen.insert($0.id).inserted }
                feeds[tab]?.items += items
                added = items.count
                feeds[tab]?.cursor = meta[next]
                feeds[tab]?.done = meta["is_final_page"] as? Bool ?? true || meta[next] == nil || meta[next] is NSNull
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

/// Decoded artwork shared by every view, so one rebuilt (a poll, a tab switch, Now Playing's clock) draws at once
/// instead of reloading through a shimmer and fade. Capped by decoded bytes (an 800px banner is ~2.5 MB; JPEGs decode
/// on first draw into IOSurfaces Core Animation draws from directly) and evicted under memory pressure; a miss just
/// reloads from URLSession's disk cache.
nonisolated(unsafe) let imageCache: NSCache<NSURL, NSImage> = { let c = NSCache<NSURL, NSImage>(); c.totalCostLimit = 40 << 20; return c }()

/// The image at `u`, from the cache or fetched into it.
@MainActor func loadImage(_ u: URL) async -> NSImage? {
    if let img = imageCache.object(forKey: u as NSURL) { return img }
    guard let (d, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: d) else { return nil }
    let px = img.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
    imageCache.setObject(img, forKey: u as NSURL, cost: px * 4)
    return img
}

/// A remote image: cached ones on the first frame; new ones shimmer (unless `fit`, for icons), then fade in.
struct RemoteImage: View {
    let url: URL?, fit: Bool
    @State private var image: NSImage?
    @State private var failed = false
    init(url: URL?, fit: Bool = false) {
        self.url = url; self.fit = fit
        _image = State(initialValue: url.flatMap { imageCache.object(forKey: $0 as NSURL) })   // a lookup, no decode
    }
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: fit ? .fit : .fill).transition(.opacity)
            } else if url != nil && !failed && !fit {
                Shimmer().opacity(0.08)   // loading; failed or no artwork stays plain grey
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = imageCache.object(forKey: url as NSURL) { image = c; return }
            // keep the current image (e.g. a My NTS row's feed thumb) until the new one is in, swapped without a blank or fade
            failed = false
            let img = await loadImage(url)
            guard !Task.isCancelled else { return }   // superseded by a newer url; don't blank its image
            if image == nil { withAnimation(.easeOut(duration: 0.25)) { image = img } } else if let img { image = img }
            failed = image == nil
        }
    }
}

/// Image that fills a fixed frame without pushing the layout wider.
struct Cover: View {
    let url: URL?
    var body: some View {
        Color(white: 0.12)
            // .clipped() hides the fill's overflow but it still takes clicks (e.g. a card's image over the play button above it)
            .overlay { RemoteImage(url: url).allowsHitTesting(false) }
            .clipped()
    }
}

/// A small image fitted whole (mixtape icons).
struct Icon: View {
    let url: URL?
    var body: some View { RemoteImage(url: url, fit: true) }
}

// Layout measured from the NTS iPhone app (402pt wide), scaled to our 360pt popover.
let cardHeight: CGFloat = 326
let contentHeight = cardHeight * 2
let pageInset: CGFloat = 10   // page margin below artwork
let bannerHeight: CGFloat = 221   // NowHeader artwork

func hhmm(_ d: Date) -> String {
    d.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                          timeZone: .current, calendar: .current))
}

/// "13:00 - 14:00"
func hours(_ start: Date, _ end: Date) -> String { "\(hhmm(start)) - \(hhmm(end))" }

/// Playback position, e.g. 0:19:23
func clock(_ s: Double) -> String { Duration.seconds(max(0, s)).formatted(.time(pattern: .hourMinuteSecond)) }

extension View {
    /// Keeps `height` at this view's laid-out height (ignoring the zero of a first, unsized pass).
    func measureHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { height.wrappedValue = $0 } }
    }
}

extension ScrollGeometry {
    /// How far the content has scrolled from its top.
    var scrolled: CGFloat { contentOffset.y + contentInsets.top }
}

extension String {
    /// API titles carry HTML entities (e.g. &amp;).
    /// Numeric entities (&#39; &#8217; &#x2019;) plus the named ones titles use; &amp; last so "&amp;lt;" stays "&lt;".
    var htmlDecoded: String {
        replacing(/&#([xX]?)([0-9a-fA-F]+);/) { m in
            UInt32(m.2, radix: m.1.isEmpty ? 10 : 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.0)
        }
        .replacing("&quot;", with: "\"").replacing("&apos;", with: "'").replacing("&lt;", with: "<").replacing("&gt;", with: ">")
        .replacing("&nbsp;", with: " ").replacing("&amp;", with: "&")
    }
    /// Uppercased, with U+2005 spaces: Univers Condensed kerns the plain space against W and "-",
    /// shrinking gaps ("SHOWW/", "18:00- 20:00"); CoreText applies those pairs even with kerning 0.
    var nts: String { uppercased().replacing(" ", with: "\u{2005}") }
}

enum Page { case live, nowPlaying, mixtapes, saved
    /// The tab bar: page, label, icon. The mini player opens Now Playing too.
    static let tabs: [(page: Page, label: String, icon: String)] = [
        (.live, "LIVE", "antenna.radiowaves.left.and.right"), (.nowPlaying, "NOW PLAYING", "waveform"), (.mixtapes, "MIXTAPES", "infinity"), (.saved, "MY NTS", "person"),
    ]
}

/// A soft glow easing across the progress line while audio loads.
struct Shimmer: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let e = t * t * (3 - 2 * t)   // smoothstep: eases in and out at the ends
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.9), location: 0.5),
                                   .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 180).offset(x: e * 540 - 180)
                .frame(maxWidth: .infinity, alignment: .leading).clipped()
        }
    }
}

/// Whether a page is scrolled a way down; the app's tab bar (and My NTS's title) tuck away while it is.
struct ScrolledDown: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// On a page's ScrollView: starts its content below the app's tab bar (plus `extra`, for a header of its own
/// floating over it), and reports scrolled down once past 50pt, back on any scroll up (as Safari's toolbar) or near the top.
struct HidesTabs: ViewModifier {
    var extra: CGFloat = 0
    @Environment(\.tabBar) var tabBar
    @State private var down = false   // per scroll view: one that appears (e.g. back from a show) starts with the bar shown
    @State private var turn: CGFloat = 0   // where the scroll last turned around: hidden, the furthest down; shown, the furthest up
    static let travel: CGFloat = 40   // scroll this far one way before the bar moves, so small wheel nudges leave it be
    struct Offset: Equatable { var y, end: CGFloat }
    func body(content: Content) -> some View {
        content
            .contentMargins(.top, tabBar.height + extra, for: .scrollContent)
            .onScrollGeometryChange(for: Offset.self) { g in
                Offset(y: g.scrolled, end: g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.containerSize.height)
            } action: { _, g in
                let y = g.y
                if y < 20 { down = false; turn = y; return }
                if y > g.end { turn = y; return }   // past the end: a bounce easing back, not the reader scrolling up
                turn = down ? max(turn, y) : min(turn, y)
                if down ? y < turn - Self.travel : y > turn + Self.travel && y > 50 { down.toggle(); turn = y }
            }
            .preference(key: ScrolledDown.self, value: down)
    }
}

/// The app's tab bar floats over the page, so pages never resize as it comes and goes (a resizing ScrollView
/// strands its offset past the end after a bounce). Scrolling pages inset their content by `height`;
/// anything pinned to their top (My NTS's header, a show's back bar) sits `visible` down.
struct TabBarInset: Equatable {
    var height: CGFloat = 0, shown = true
    var visible: CGFloat { shown ? height : 0 }
}

extension EnvironmentValues {
    @Entry var tabBar = TabBarInset()
}

/// What's playing as a 2pt line along the mini player's top edge:
/// live show or archive episode progress; solid for mixtapes. Archive episodes: thickens on hover, drag to seek.
struct ProgressLine: View {
    @Environment(Store.self) var store
    @State private var hover = false
    static let width: CGFloat = 358   // the 360pt window less its border pixel each side

    func progress(at now: Date) -> Double {
        if store.seekable { return store.scrub ?? store.position / store.duration }
        guard let id = store.playingID else { return 0 }
        guard let c = store.live.first(where: { $0.id == id }) else { return 1 }   // mixtapes: solid
        return fraction(c.now, at: now)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let f = progress(at: ctx.date)
            let grown = store.seekable && (hover || store.scrub != nil)   // seeking: the bar thickens, no knob
            Rectangle().fill(.white.opacity(0.2))
                .overlay(alignment: .leading) { Rectangle().fill(.white).frame(width: store.loading ? 0 : Self.width * f) }
                .overlay { if store.loading { Shimmer() } }
                .frame(height: grown ? 5 : 2)
                .frame(height: 2, alignment: .bottom)   // grows upward, past its 2pt slot
                .animation(.spring(duration: 0.25), value: grown)
                .padding(.horizontal, 1)   // clear of the window's border pixel
        }
        .overlay {
            if store.seekable {
                Color.clear.frame(height: 14).contentShape(.rect)
                    .onHover { hover = $0 }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { store.scrub = min(1, max(0, ($0.location.x - 1) / Self.width)) }
                        .onEnded { _ in store.endScrub() })
            }
        }
    }
}

struct RootView: View {
    @Environment(Store.self) var store
    @State var page = Page.live
    @State private var tabsHidden = false
    @State private var tabsHeight: CGFloat = 54
    @State private var back = Page.live   // where the mini player returns to from Now Playing
    var mini: Bool { store.playingID != nil }
    /// The page runs under the tab bar; the mini player takes its share.
    var pageHeight: CGFloat { tabsHeight + contentHeight - (mini ? miniHeight : 0) }
    var scrollsUnderTabs: Bool { page == .saved }   // only My NTS hides the bar; the rest start below it

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .live: LiveView()
                case .nowPlaying: NowPlayingView()
                case .mixtapes: MixtapesView()
                case .saved: SavedView()
                }
            }
            .padding(.top, scrollsUnderTabs ? 0 : tabsHeight)
            .environment(\.tabBar, TabBarInset(height: tabsHeight, shown: !tabsHidden))
            // Now Playing shrinks the window to its content; other pages keep the fixed height
            .frame(minHeight: page == .nowPlaying ? nil : pageHeight, maxHeight: pageHeight, alignment: .top)
            // pages without HidesTabs (all but My NTS) report false, so switching pages brings the bar back
            .onPreferenceChange(ScrolledDown.self) { down in withAnimation(.easeOut(duration: 0.12)) { tabsHidden = down } }
            .overlay(alignment: .top) { VStack(spacing: 0) { tabs; problem } }
            .clipped()   // the bar slides up out of the window
            if mini {
                MiniPlayer(expanded: page == .nowPlaying) {
                    if page == .nowPlaying { page = back } else { back = page; page = .nowPlaying }
                }
            }
        }
        .onChange(of: page) { if page != .nowPlaying { store.showTracklist = false } }   // Now Playing reopens on the episode
    }

    var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Page.tabs, id: \.page) { t in
                Button {
                    if t.page == .nowPlaying && page != .nowPlaying { back = page }   // the mini player's chevron returns here
                    page = t.page
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 19)).frame(height: 22)
                        Text(t.label.nts).font(.nts(10))
                    }
                    .frame(maxWidth: .infinity, minHeight: 54).contentShape(.rect)
                    .opacity(page == t.page ? 1 : 0.45)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { if page != .saved { Rectangle().fill(.white.opacity(0.75)).frame(height: 1) } }   // My NTS's own tab row follows straight on
        .fixedSize(horizontal: false, vertical: true)
        .measureHeight($tabsHeight)
        .opacity(tabsHidden ? 0 : 1)
        .background(.black)   // after the fade: a fading background would flash the list beneath
        .offset(y: tabsHidden ? -tabsHeight : 0)   // slides up out of view
        .frame(height: tabsHidden ? 0 : tabsHeight, alignment: .top)
    }

    @ViewBuilder var problem: some View {
        if let err = store.problem {   // account failures (e.g. a rejected bookmark), on every page; click to dismiss
            Text(err).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 6)
                .background(.black)
                .onTapGesture { store.problem = nil }
        }
    }
}

// MARK: - Live

/// Parallax push: `top` slides in from the right edge over `base`, which drifts a third as far left; back reverses it.
/// Change `shown` inside `push { }`.
struct Push<Base: View, Top: View>: View {
    let shown: Bool
    /// Base stays alive underneath, so back returns to its scroll position (and its images stay loaded).
    /// Off where the window fits its content (Now Playing): a kept base would hold the window at its height.
    var keep = true
    @ViewBuilder var base: Base
    @ViewBuilder var top: Top
    var body: some View {
        ZStack(alignment: .top) {
            if keep {
                base
                    .offset(x: shown ? -120 : 0)
                    .allowsHitTesting(!shown)
                    .transformPreference(ScrolledDown.self) { if shown { $0 = false } }   // only the page in front drives the tab bar
            } else if !shown {
                base.transition(.offset(x: -120))
            }
            if shown { top.background(.black).transition(.move(edge: .trailing)).zIndex(1) }
        }
    }
}

func push(_ change: () -> Void) { withAnimation(.easeOut(duration: 0.2), change) }

struct LiveView: View {
    @Environment(Store.self) var store
    // a channel's schedule, in place of the cards; `--snapshot out.png --schedule 2` opens one
    @State private var schedule: String? = CommandLine.arguments.firstIndex(of: "--schedule").flatMap { i in
        CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : nil
    }

    var body: some View {
        Push(shown: schedule != nil) { cards } top: {
            if let ch = schedule {
                ScheduleView(tab: ch) { open(nil) }
                    // Live keeps its tab bar: no inset under it, no hiding on scroll
                    .environment(\.tabBar, TabBarInset())
                    .transformPreference(ScrolledDown.self) { $0 = false }
            }
        }
    }

    func open(_ ch: String?) { push { schedule = ch } }

    var cards: some View {
        VStack(spacing: 0) {
            if let e = store.error { Text(e.uppercased()).font(.nts(14)).opacity(0.6).padding() }
            ForEach(store.live) { c in
                ChannelCard(channel: c) { open(c.id) }
            }
            if store.live.isEmpty && store.error == nil { ProgressView().frame(maxHeight: .infinity) }
        }
        // the mini player appears instantly; the cards ease into the room left for it
        .animation(.easeOut(duration: 0.2), value: store.playingID != nil)
    }
}

/// The schedule as in the iPhone app: white day bars, time · title · rerun mark, a red dot on what's on now
/// (with its description). Past slots dimmed; opens scrolled to now. A row opens its show.
/// Tabs: each channel, then the followed shows on both (each title led by its channel box).
struct ScheduleView: View {
    @Environment(Store.self) var store
    @State var tab: String   // a channel ("1", "2") or "following"
    let back: () -> Void
    struct Slot { var channel: String, b: Broadcast; var id: String { channel + b.startTimestamp.ISO8601Format() } }
    @State private var followsLoaded = false
    @State private var show: Saved?
    var following: Bool { tab == "following" }

    var body: some View {
        Push(shown: show != nil) { list } top: { if let s = show { ShowView(show: s) { push { show = nil } } } }
    }

    var list: some View {
        let now = Date(), loaded = self.slots, slots = loaded ?? []
        let days = Dictionary(grouping: slots) { Calendar.current.startOfDay(for: $0.b.startTimestamp) }.sorted { $0.key < $1.key }
        // the slot before what's on, so the list opens with a little of the past above
        let i = slots.firstIndex { ($0.b.endTimestamp ?? $0.b.startTimestamp) > now }
        let anchor = i.map { slots[max($0 - 1, 0)].id }
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.key) { day in
                            dayBar(day.key)
                            ForEach(day.value, id: \.id) { row($0, now) }
                        }
                        if loaded == nil, let e = store.error {
                            Text(e.uppercased()).font(.nts(14)).opacity(0.6).frame(maxWidth: .infinity).padding(.top, 60)
                        } else if loaded == nil { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16) }
                        else if slots.isEmpty {
                            Text("NO FOLLOWED SHOWS ON THE SCHEDULE".nts).font(.nts(16)).opacity(0.5).frame(maxWidth: .infinity).padding(.top, 60)
                        }
                    }
                }
                .onAppear { if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
                .onChange(of: anchor) { if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
            }
        }
        .task { await store.loadSchedules() }   // usually a no-op: fetched at launch, refreshed by the live poll
        .task(id: following) { if following { await store.loadFollowedShows(); followsLoaded = true } }
    }

    /// From the store's cached schedules, so the view slides in already filled; nil until they (and follows) are in.
    var slots: [Slot]? {
        let chans = following ? liveStreams.keys.sorted() : [tab]
        var all: [Slot] = []
        for ch in chans {
            guard let bs = store.schedules[ch] else { return nil }
            all += bs.map { Slot(channel: ch, b: $0) }
        }
        guard following else { return all }
        guard followsLoaded else { return nil }
        return all.filter { $0.b.showPath.map(store.isSaved) == true }   // live, so a follow made from a pushed show shows on return.sorted { $0.b.startTimestamp < $1.b.startTimestamp }
    }

    var header: some View {
        HStack(spacing: 16) {
            Button(action: back) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.nts(15)).frame(width: 28, height: 28)
                    Text("SCHEDULE".nts).font(.nts(15))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            ForEach(liveStreams.keys.sorted(), id: \.self) { c in
                tabButton(c) { HStack(spacing: 5) { Text("LIVE".nts).font(.nts(13)); ChannelBox(channel: c) } }
            }
            tabButton("following") { FollowingIcon() }
        }
        .padding(.leading, 4).padding(.trailing, pageInset).padding(.vertical, 8)
    }

    func tabButton(_ t: String, @ViewBuilder label: () -> some View) -> some View {
        Button { tab = t } label: { label().frame(height: 28).contentShape(.rect) }
            .buttonStyle(.plain).opacity(tab == t ? 1 : 0.45)
    }

    func dayBar(_ day: Date) -> some View {
        let cal = Calendar.current
        let name = cal.isDateInToday(day) ? "Today" : cal.isDateInTomorrow(day) ? "Tomorrow"
            : cal.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide))
        let date = Text(", " + day.formatted(.dateTime.day().month(.abbreviated)).nts).font(.nts(14, .regular))
        return Text("\(Text(name.nts).font(.nts(14)))\(date)")
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pageInset).padding(.vertical, 9)
            .background(.white)
    }

    func row(_ s: Slot, _ now: Date) -> some View {
        let b = s.b, end = b.endTimestamp ?? b.startTimestamp
        let onNow = b.startTimestamp <= now && now < end
        let live = store.live.first { $0.id == s.channel }?.now
        let desc = onNow && live?.startTimestamp == b.startTimestamp ? live?.embeds?.details?.description : nil
        return Button {
            if let p = b.showPath { push { show = Saved(id: p, title: b.bareTitle, subtitle: "") } }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(hours(b.startTimestamp, end).nts).font(.nts(13, onNow ? .bold : .regular))
                    .frame(width: 82, alignment: .leading)
                Circle().fill(.red).frame(width: 6, height: 6).opacity(onNow ? 1 : 0)
                    .frame(width: 14, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if following { ChannelBox(channel: s.channel) }
                        Text(b.bareTitle.nts).font(.nts(14)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let desc, !desc.isEmpty { Text(desc).font(.system(size: 12)).opacity(0.8).lineLimit(5) }
                }
                Spacer(minLength: 8)
                if b.isReplay { ReplayIcon(size: 12) }
            }
            .padding(.horizontal, pageInset).padding(.vertical, 9)
            .opacity(end <= now ? 0.45 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if let p = b.showPath { store.hoverShow(p, $0) } }
    }
}

/// A channel's number, black in a white box (Live cards, schedule).
struct ChannelBox: View {
    let channel: String
    var body: some View {
        Text(channel).font(.nts(11)).foregroundStyle(.black).frame(width: 11, height: 12).background(.white)
    }
}

/// Square-cornered calendar, no day dots: outline, solid header band, two rings poking above it.
struct CalendarIcon: View {
    var size: CGFloat = 20
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, lw = w * 0.09, top = w * 0.12
            ctx.stroke(Path(CGRect(x: lw / 2, y: top + lw / 2, width: w - lw, height: w - top - lw)), with: .foreground, lineWidth: lw)
            ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: w * 0.25)), with: .foreground)
            for x in [0.3, 0.7] { ctx.fill(Path(CGRect(x: w * x - lw / 2, y: 0, width: lw, height: top + lw)), with: .foreground) }
        }
        .frame(width: size, height: size)
    }
}

/// Calendar with a heart: the schedule's followed-shows tab.
struct FollowingIcon: View {
    var body: some View {
        CalendarIcon(size: 17)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "heart.fill").font(.system(size: 8)).padding(1.5)
                    .background(.black, in: .circle).offset(x: 4, y: 3)
            }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: .init(x: r.minX, y: r.minY)); p.addLine(to: .init(x: r.maxX, y: r.midY)); p.addLine(to: .init(x: r.minX, y: r.maxY)) }
    }
}

/// The iPhone app's rerun mark: square brackets chasing each other, an arrowhead on each.
struct ReplayIcon: View {
    var size: CGFloat = 20
    var body: some View {
        // proportions measured from the iPhone app's (square overall, arrowheads a third of it)
        Canvas { ctx, s in
            let w = s.width, h = s.height
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x * w, y: y * h) }
            var lines = Path()
            lines.addLines([pt(0.22, 0.835), pt(0.035, 0.835), pt(0.035, 0.165), pt(0.28, 0.165)])   // left bracket, out along the top
            lines.addLines([pt(0.8, 0.165), pt(0.965, 0.165), pt(0.965, 0.835), pt(0.72, 0.835)])   // right bracket, back along the bottom
            ctx.stroke(lines, with: .foreground, style: .init(lineWidth: w * 0.085))
            var heads = Path()
            heads.addLines([pt(0.27, 0), pt(0.56, 0.165), pt(0.27, 0.33)]); heads.closeSubpath()
            heads.addLines([pt(0.73, 0.67), pt(0.41, 0.835), pt(0.73, 1)]); heads.closeSubpath()
            ctx.fill(heads, with: .foreground)
        }
        .frame(width: size, height: size)   // brackets ~0.72 as tall as wide, as on iPhone
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }   // in a baseline row: on the baseline, dipping a hair below as on iPhone
    }
}

struct ChannelCard: View {
    @Environment(Store.self) var store
    let channel: Channel
    let openSchedule: () -> Void

    /// A new show crossfades in over the old one (title, time and artwork together), rather than swapping on the poll.
    var body: some View {
        let key = "\(channel.now.startTimestamp)\(channel.now.broadcastTitle)"
        ZStack { card.id(key).transition(.opacity) }
            .animation(.easeInOut(duration: 0.6), value: key)
            .frame(minHeight: 0, maxHeight: cardHeight)   // shrinks to make room for the mini player
    }

    @ViewBuilder var card: some View {
        let d = channel.now.embeds?.details
        let playing = store.playingID == channel.id && !store.paused
        ZStack(alignment: .topLeading) {
            Cover(url: d?.media?.wide)
            Color.black.opacity(0.2)   // NTS dims the artwork slightly; no shadows on text
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    ChannelBox(channel: channel.channelName)
                    Text((d?.locationLong ?? "").nts).font(.nts(12.5, .regular))
                        .padding(.leading, 2)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(channel.now.bareTitle.nts).font(.nts(21.5))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if channel.now.isReplay { ReplayIcon(size: 17.5) }   // as wide as the title's cap height, as on iPhone
                }
                .padding(.top, 5)
                if let end = channel.now.endTimestamp {
                    Text(hours(channel.now.startTimestamp, end).nts)
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
                    Button(action: openSchedule) {
                        CalendarIcon(size: 19).padding(4).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.top, 7).padding(.bottom, 9)
        }
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

/// Buffering: the play triangle, breathing. Sized by the frame it's given.
struct Spinner: View {
    @State private var dim = false
    var body: some View {
        Triangle().opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(), value: dim)
            .onAppear { dim = true }
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
            LazyVGrid(columns: [GridItem(spacing: 0), GridItem()], spacing: 0) {
                ForEach(store.mixtapes) { m in MixtapeTile(mixtape: m) }
            }
        }
    }
}

/// Square tile styled after nts.live's infinite mixtapes grid: dimmed artwork, play top-left, icon + title bottom-left.
struct MixtapeTile: View {
    @Environment(Store.self) var store
    let mixtape: Mixtape
    @State private var hover = false
    var body: some View {
        let playing = store.playingID == mixtape.id && !store.paused
        Button { store.toggle(mixtape.id, mixtape.audioStreamEndpoint) } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { Cover(url: mixtape.media?.pictureMedium.flatMap(URL.init)) }
                .overlay { if hover, let v = store.mixtapeVideos[mixtape.id] { HoverVideo(url: v) } }
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
                        Icon(url: mixtape.media?.iconWhite.flatMap(URL.init)).frame(width: 13, height: 13)
                        Text(mixtape.title.nts).font(.nts(15)).lineLimit(1)
                    }
                    .padding(10)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A mixtape tile's hover loop: its own muted player, so it doesn't take Now Playing's shared one.
struct HoverVideo: NSViewRepresentable {
    let url: URL
    final class Coordinator { let player = AVQueuePlayer(); var looper: AVPlayerLooper? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator
        c.player.isMuted = true
        c.looper = AVPlayerLooper(player: c.player, templateItem: AVPlayerItem(url: url))
        c.player.play()
        let v = NSView()
        let layer = AVPlayerLayer(player: c.player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.player.pause() }
}

struct SavedView: View {
    @Environment(Store.self) var store
    @State private var tab = SavedTab.allCases.first { CommandLine.arguments.contains($0.rawValue) } ?? .hosts   // `--snapshot … --tab saved history`
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
        Push(shown: show != nil) { lists } top: { if let s = show { ShowView(show: s) { push { show = nil } } } }
    }

    @Environment(\.tabBar) var tabBar
    @State private var headerHeight: CGFloat = 48
    /// The tabs float over the list, as the app's tabs do, so the list never resizes.
    var header: some View {
        // as the schedule's header: icon left, plain tabs right (selected full white, the rest dimmed)
        HStack(spacing: 16) {
            Menu {
                if let e = store.email {
                    Text(e)
                    Button("Sign Out") { store.signOut() }
                    Divider()
                }
                Button("Quit") { Task { await store.listenStop()?.value; NSApp.terminate(nil) } }
            } label: {
                Image(systemName: "person.circle")   // a menu: account, Quit
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.white)
            Spacer(minLength: 0)
            ForEach(SavedTab.allCases, id: \.self) { t in
                Button { tab = t } label: { Text(t.rawValue.nts).font(.nts(13)).frame(height: 28).contentShape(.rect) }
                    .buttonStyle(.plain).opacity(tab == t ? 1 : 0.45)
            }
        }
        .padding(.horizontal, pageInset).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .measureHeight($headerHeight)
        .background(.black)
        .offset(y: tabBar.visible)
    }

    var lists: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.email == nil { AccountView() }
                let loading = store.feeds[tab]?.loading == true
                // the account's first page not in yet (or not even asked for: no "nothing saved" flash before the fetch starts)
                let first = store.email != nil && items.isEmpty && (store.feeds[tab] == nil || loading)
                if tab == .history && store.email == nil {
                    empty("SIGN IN FOR HISTORY")
                } else if first {
                    ForEach(0..<5, id: \.self) { _ in SkeletonRow(square: tab == .hosts); Rule().padding(.horizontal, pageInset) }
                } else if items.isEmpty && !loading {
                    empty(tab == .history ? "NOTHING PLAYED YET" : "NOTHING SAVED YET")
                }
                ForEach(items) { s in
                    SavedRow(s: s) { push { show = s } }
                        .onHover { if !s.isEpisode { store.hoverShow(s.id, $0) } }   // episodes play in-app; hosts open their episode list
                        .onAppear { if s.id == items.last?.id { Task { await store.loadMore(tab) } } }
                    Rule().padding(.horizontal, pageInset)
                }
                if loading && !first { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16) }
            }
        }
        .modifier(HidesTabs(extra: headerHeight))
        .overlay(alignment: .top) { header }
        .task(id: "\(tab)\(store.email ?? "")") { await store.loadMore(tab) }
    }

    func empty(_ text: String) -> some View {
        Text(text.nts).font(.nts(16)).opacity(0.5).frame(maxWidth: .infinity).padding(.top, 60)
    }
}

/// A My NTS item as an EpisodeRow; the feed's article is thin, so the full details (artwork, genres) load per row.
struct SavedRow: View {
    @Environment(Store.self) var store
    let s: Saved, open: () -> Void
    var body: some View {
        EpisodeRow(id: s.id, d: store.details[s.id] ?? Details(name: s.title), subtitle: s.subtitle, image: s.image, open: open)
            .task {
                guard store.details[s.id] == nil, let d: Details = try? await fetchOne(String(s.id.dropFirst())) else { return }
                store.details[s.id] = d
            }
    }
}

/// An episode as in the iPhone My NTS Episodes list (×0.896): wide artwork with a play box in its corner,
/// title, date and boxed genre tags beside it, ⋯ menu bottom-right.
/// A show (id without /episodes/) gets square artwork, no play box, and `open` on tap.
struct EpisodeRow: View {
    @Environment(Store.self) var store
    let id: String, d: Details
    var subtitle = ""      // shown when the details carry no date (shows; episodes still loading)
    var image: URL?        // until the details' artwork arrives
    var open: () -> Void = {}
    @State private var latest: String?   // shows: the newest episode, once its play button is used
    var body: some View {
        let isEpisode = id.contains("/episodes/")
        let date = d.broadcastDate?.formatted(.dateTime.day(.twoDigits).month(.abbreviated).year()) ?? subtitle
        let web = URL(string: "https://www.nts.live" + id)!
        let item = Saved(id: id, title: d.name ?? "", subtitle: date, image: d.media?.thumb ?? image)
        let tags = (d.genres ?? []).map(\.value)
        HStack(alignment: .top, spacing: 10) {
            Cover(url: (isEpisode ? d.media?.wideSmall : d.media?.square) ?? image).frame(width: isEpisode ? 148 : 93, height: 93)
                .overlay(alignment: .bottomLeading) {
                    if isEpisode { playIcon(id, 15, 17).frame(width: 49, height: 45).background(.black.opacity(0.75)) }
                }
                .overlay(alignment: .bottom) {   // how far the account got, as on iPhone
                    if let p = store.progress[id] {
                        GeometryReader { g in
                            Rectangle().fill(.white.opacity(0.3))
                                .overlay(alignment: .leading) { Rectangle().fill(.white).frame(width: g.size.width * min(1, p.pos / p.length)) }
                        }
                        .frame(height: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text((d.name ?? "").nts).font(.nts(14)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if !isEpisode {   // shows: ▶ newest episode + grey "Last episode", only the age bold, on the artwork's bottom edge
                    HStack(spacing: 1) {
                        Button { Task { await playLatest() } } label: {
                            playIcon(latest, 10, 12).frame(width: 20, height: 20).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if date.hasPrefix("Last episode ") {
                            (Text("Last episode ".nts) + Text(String(date.dropFirst(13)).nts).font(.nts(11)))
                                .font(.nts(11, .regular)).opacity(0.6).lineLimit(1)
                        }
                    }
                    .padding(.leading, -5)   // triangle on the text edge, hit area spilling left
                    .frame(maxHeight: .infinity, alignment: .bottomLeading)
                } else {
                    Text(date.nts).font(.nts(11, .regular))
                    // as many tags as fit beside the artwork, clear of the ⋯, sitting on its bottom edge
                    ViewThatFits(in: .vertical) {
                        ForEach((0...tags.count).reversed(), id: \.self) { n in
                            Flow(spacing: 5) { ForEach(tags.prefix(n), id: \.self, content: genreTag) }.padding(.top, 4).padding(.trailing, 26)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottomLeading)   // last row level with the artwork's bottom
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 93, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            Menu {
                if isEpisode { Button(store.isSaved(id) ? "Remove Episode" : "Save Episode") { store.toggleSave(item) } }
                else { Button(store.isSaved(id) ? "Unfollow Show" : "Follow Show") { store.toggleSave(item) } }
                Button("Open on nts.live") { NSWorkspace.shared.open(web) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 20, height: 16)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.white)
        }
        .padding(.horizontal, pageInset).padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { if isEpisode { Task { await store.playEpisode(id) } } else { open() } }
    }

    /// Spinner while `episode` loads, pause while it plays, else play; `w`×`h` is the triangle's size.
    @ViewBuilder func playIcon(_ episode: String?, _ w: CGFloat, _ h: CGFloat) -> some View {
        if let e = episode, store.waiting(e) { Spinner().frame(width: w, height: h) }
        else if let e = episode, store.playingID == e && !store.paused { PauseIcon().frame(width: w - 2, height: h - 2) }
        else { Triangle().frame(width: w, height: h) }
    }

    func playLatest() async {
        if latest == nil {
            let page = try? await fetchOne(String(id.dropFirst()) + "/episodes", as: Results<Details>.self,
                                           query: [.init(name: "limit", value: "1")]).results
            latest = page?.first?.episodePath.map { "/" + $0 }
        }
        if let l = latest { await store.playEpisode(l) }
    }
}

/// A boxed genre tag, as on nts.live.
func genreTag(_ t: String) -> some View {
    Text(t.nts).font(.nts(9.5)).lineLimit(1).fixedSize()
        .padding(.horizontal, 5).padding(.vertical, 3)
        .overlay { Rectangle().stroke(.white.opacity(0.35), lineWidth: 1) }
}

/// Lays subviews out left to right, wrapping onto new lines.
struct Flow: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = rows(proposal.width ?? .infinity, subviews)
        return CGSize(width: r.map(\.width).max() ?? 0, height: r.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(b.width, subviews) {
            var x = b.minX
            for i in row.items { let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: b.minY + row.y), proposal: .unspecified); x += s.width + spacing }
        }
    }
    private func rows(_ maxW: CGFloat, _ subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + s.width <= maxW {
                rows[rows.count - 1].items.append(i); rows[rows.count - 1].width += spacing + s.width
                rows[rows.count - 1].height = max(last.height, s.height)
            } else {
                rows.append(([i], rows.last.map { $0.y + $0.height + spacing } ?? 0, s.width, s.height))
            }
        }
        return rows
    }
}

/// A followed show's archive, newest first, paged in; episodes play in-app like My NTS rows.
struct ShowView: View {
    @Environment(Store.self) var store
    let show: Saved, back: () -> Void
    @State private var episodes: [Details] = []
    @State private var done = false
    @State private var loading = false
    @State private var fetched = 0   // raw items paged in, the API's offset (episodes drops those without a path)
    /// The show itself (banner, location, frequency, description): prefetched on hover when it can be, so the push slides in drawn.
    var info: Details? { store.details[show.id] }
    @State private var bar = 0   // back bar: 0 hidden, 1 shown, 2 with the show name
    @Environment(\.tabBar) var tabBar

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
                    // the prefetched page until loadMore takes it, so the first frame of the push already has rows
                    let list = episodes.isEmpty ? (store.showEpisodes[show.id] ?? []).filter { $0.episodePath != nil } : episodes
                    ForEach(list, id: \.episodeAlias) { d in
                        let id = "/" + (d.episodePath ?? "")
                        EpisodeRow(id: id, d: d)
                            .onAppear { if d.episodeAlias == episodes.last?.episodeAlias { Task { await loadMore() } } }
                        Rule().padding(.horizontal, pageInset)
                    }
                    if list.isEmpty && !done {
                        ForEach(0..<2, id: \.self) { _ in SkeletonRow(); Rule().padding(.horizontal, pageInset) }
                    } else if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16) }
                }
            }
            .overlay(alignment: .top) {
                if bar > 0 {
                    VStack(spacing: 0) {
                        Button(action: back) {
                            HStack(spacing: 0) {
                                Image(systemName: "chevron.left").font(.nts(15)).frame(width: 36, height: 40)
                                Text((info?.name ?? show.title).nts).font(.nts(14)).lineLimit(1)
                                    .opacity(bar == 2 ? 1 : 0).animation(.easeOut(duration: 0.15), value: bar)
                                Spacer(minLength: 0)
                            }
                            .padding(.trailing, pageInset).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        Rule()
                    }
                    .background(.black)
                    .padding(.top, tabBar.visible)   // under the app's tabs while they show
                }
            }
            // the bar (41pt) appears as its bottom meets the title's top (~bannerHeight + 39: location line + gaps),
            // its name fades in once the title's first line is almost covered
            .onScrollGeometryChange(for: Int.self) { g in
                let y = g.scrolled
                return y > bannerHeight + 18 ? 2 : y > bannerHeight - 2 ? 1 : 0
            } action: { bar = $1 }
            .modifier(HidesTabs())
            .task { if let d: Details = try? await fetchOne(String(show.id.dropFirst())) { store.details[show.id] = d } }   // refreshes the prefetched copy
            .task { await loadMore() }
        }
    }

    func loadMore() async {
        guard !loading, !done else { return }
        loading = true; defer { loading = false }
        do {
            var page = episodes.isEmpty ? store.takePrefetchedEpisodes(show.id) : []
            if page.isEmpty { page = try await fetchEpisodes(show.id, offset: fetched) }
            fetched += page.count
            episodes += page.filter { $0.episodePath != nil }
            done = page.count < episodePage
        } catch { store.report(error); if episodes.isEmpty { done = true } }   // no skeleton rows left shimmering
    }
}

let episodePage = 12
/// One page of a show's (/shows/x) episodes, unfiltered: a short page means it was the last.
func fetchEpisodes(_ show: String, offset: Int) async throws -> [Details] {
    try await fetchOne(String(show.dropFirst()) + "/episodes", as: Results<Details>.self,
                       query: [.init(name: "offset", value: String(offset)), .init(name: "limit", value: String(episodePage))]).results
}

/// Stand-in for an EpisodeRow while a first page loads; `square` for shows' artwork.
struct SkeletonRow: View {
    var square = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color(white: 0.12).frame(width: square ? 93 : 148, height: 93).overlay { Shimmer().opacity(0.08) }.clipped()
            VStack(alignment: .leading, spacing: 8) {
                Color(white: 0.12).frame(width: 130, height: 13)
                Color(white: 0.12).frame(width: 70, height: 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, pageInset).padding(.vertical, 10)
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

let miniHeight: CGFloat = 53   // iPhone mini player (59pt) ×0.896

/// What's playing, under the page, as on the iPhone app: artwork, pause/play, title and times; tap to open Now Playing.
struct MiniPlayer: View {
    @Environment(Store.self) var store
    var expanded = false   // on Now Playing: the chevron points down, a tap goes back
    let open: () -> Void

    /// The playing episode's tracklist path and how far in we are (live shows and archive episodes; mixtapes have none).
    func episode(at now: Date) -> (path: String, elapsed: Double)? {
        let id = store.playingID
        if let c = store.live.first(where: { $0.id == id }), let p = c.now.embeds?.details?.episodePath {
            return (p, now.timeIntervalSince(c.now.startTimestamp))
        }
        if let e = store.episode, e.id == id { return (String(e.id.dropFirst()), store.position) }
        return nil
    }

    /// The track playing now, from a timestamped tracklist, in place of the subtitle.
    func track(at now: Date) -> String? {
        guard let (path, elapsed) = episode(at: now),
              let t = store.tracklists[path]?.last(where: { Double($0.offset ?? .max) <= elapsed }) else { return nil }
        return [t.artist, t.title].compactMap { $0 }.joined(separator: " - ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let (image, title, info) = info
            let track = track(at: ctx.date)
            HStack(spacing: 0) {
                Cover(url: image).frame(width: miniHeight, height: miniHeight)
                Button { store.pauseResume() } label: {
                    Group {
                        if store.loading { Spinner() } else if store.paused { Triangle() } else { PauseIcon() }
                    }
                    .frame(width: 17, height: 19).frame(width: 50, height: miniHeight).contentShape(.rect)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.nts).font(.nts(14)).lineLimit(1)
                    if let err = store.streamError {
                        Text(err).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1).help(err)
                    } else if let track {
                        Text(track.nts).font(.nts(11, .regular)).opacity(0.8).lineLimit(1)   // tap opens Now Playing, as the rest of the bar
                    } else {
                        Text(info.nts).font(.nts(11, .regular)).opacity(0.8).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                SpeakerButton().padding(.trailing, 14)   // AirPlay is always there, Sonos rooms when found
                Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.system(size: 14, weight: .semibold)).padding(.trailing, 14)
            }
            .contentShape(.rect)
            .onTapGesture(perform: open)
            .task(id: episode(at: ctx.date)?.path) { if let p = episode(at: .now)?.path { await store.loadTracklist(p) } }
        }
        .task { await store.findRooms() }   // each time it shows, so regrouped rooms are current
        .frame(height: miniHeight)
        .overlay(alignment: .top) { ProgressLine() }
    }

    var info: (URL?, String, String) {
        let id = store.playingID
        if let c = store.live.first(where: { $0.id == id }) {
            let b = c.now
            return (b.embeds?.details?.media?.thumb, b.title, b.endTimestamp.map { hours(b.startTimestamp, $0) } ?? "")
        }
        if let m = store.mixtapes.first(where: { $0.id == id }) {
            return (m.media?.thumb, m.title, store.mixtapeNow?.title ?? m.subtitle)
        }
        if let e = store.episode, e.id == id {
            return (e.details.media?.thumb, e.details.name ?? "", "\(clock(store.position)) / \(clock(store.duration))")
        }
        return (nil, "", "")
    }
}

/// The mini player's output picker: This Mac or a Sonos room, and the room's volume, in a popover (a menu can't hold a slider).
/// Stays open after a pick, so the volume can follow.
struct SpeakerButton: View {
    @Environment(Store.self) var store
    @State private var open = false
    @State private var airplay = 0   // bumped to open the system AirPlay list from this button

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: store.cast == nil ? "hifispeaker" : "hifispeaker.fill").font(.system(size: 14)).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background { AirPlayPicker(player: store.player, show: airplay) { store.setSpeaker(nil) } }   // under the button, so it never takes its clicks
        .help(store.cast.map { "Playing on \($0.name)" } ?? "Sonos or AirPlay")
        .popover(isPresented: $open, arrowEdge: .bottom) {   // downward, as the system AirPlay list opens
            VStack(alignment: .leading, spacing: 2) {
                row("This Mac", nil)
                ForEach(store.rooms, id: \.self) { row($0.name, $0) }
                // swaps this popover for the system list, so only one is up at a time
                Button { open = false; airplay += 1 } label: {
                    HStack {
                        Text("AirPlay".nts).font(.nts(13))
                        Spacer()
                        Image(systemName: "airplay.audio").font(.system(size: 12))
                    }
                    .padding(.horizontal, 8).frame(height: 26).contentShape(.rect)
                }
                .buttonStyle(.plain)
                if store.speaker != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").font(.system(size: 11)).opacity(0.6)
                        // sent once the drag ends: one request per tick could land out of order
                        Slider(value: Binding(get: { Double(store.volume ?? 0) }, set: { store.volume = Int($0) }), in: 0...100) { editing in
                            if !editing, let v = store.volume { store.setVolume(v) }
                        }
                        .disabled(store.volume == nil)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).opacity(0.6)
                    }
                    .padding(.horizontal, 8).padding(.top, 10)
                }
            }
            .padding(10).frame(width: 220)
        }
    }

    func row(_ name: String, _ room: SonosRoom?) -> some View {
        let off = room != nil && store.noSonos && store.playingID != nil
        return Button { store.setSpeaker(room) } label: {
            HStack {
                Text(name.nts).font(.nts(13)).lineLimit(1)
                Spacer()
                // while playing, where it actually plays (an episode Sonos can't take falls back to the Mac); else the chosen output
                if (store.playingID != nil && !store.paused ? store.cast : store.speaker) == room { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .padding(.horizontal, 8).frame(height: 26).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(off).opacity(off ? 0.4 : 1)
        .help(off ? "This episode can't play on Sonos" : "")
    }
}

/// The system AirPlay list for the Mac's player, from an invisible picker that opens it when `show` changes.
/// AirPlay carries the Mac's player, so picking a device switches off Sonos; just opening the list changes nothing.
struct AirPlayPicker: NSViewRepresentable {
    let player: AVPlayer, show: Int, picked: () -> Void
    @MainActor final class Coordinator: NSObject, @preconcurrency AVRoutePickerViewDelegate {   // AppKit calls it on the main thread
        var picked: () -> Void = {}
        var shown = 0
        func routePickerViewDidEndPresentingRoutes(_ v: AVRoutePickerView) {
            // No public way to read the chosen route: isExternalPlaybackActive, or the picker's own flag (private, so asked for warily)
            Task {
                try? await Task.sleep(for: .milliseconds(300))   // the route lands just after the menu closes
                let flag = Selector(("_isAirPlayActive"))
                let active = v.player?.isExternalPlaybackActive == true || (v.responds(to: flag) && (v.value(forKey: "_isAirPlayActive") as? Bool) == true)
                if active { picked() }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.alphaValue = 0   // still takes clicks
        v.delegate = context.coordinator
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        v.player = player; context.coordinator.picked = picked
        guard show != context.coordinator.shown else { return }
        context.coordinator.shown = show
        // No public call opens the list: click the picker's own button (an NSButton), once the app's popover has gone.
        // A macOS that changes its insides just leaves the row doing nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { (v.subviews.first as? NSButton)?.performClick(nil) }
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
            Cover(url: image).frame(height: bannerHeight)
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

/// Description and the current/next track (live and archive episode pages).
struct EpisodeInfo: View {
    let details: Details?, tracks: [Track]?, openTracklist: () -> Void
    var body: some View {
        // Description size measured from the NTS iPhone episode page (×0.896 for 360pt)
        if let desc = details?.description, !desc.isEmpty {
            Text(desc).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, pageInset).padding(.top, 13)
        }
        if let tags = details?.genres?.map(\.value), !tags.isEmpty {
            Flow(spacing: 5) { ForEach(tags, id: \.self, content: genreTag) }
                .padding(.horizontal, pageInset).padding(.top, 13)
        }
        if let tracks, !tracks.isEmpty {
            Rule().padding(.horizontal, pageInset).padding(.top, 18)
            // a link, not the playing track: the mini player below already shows what's on
            Button(action: openTracklist) {
                HStack {
                    Text("TRACKLIST".nts).font(.nts(13))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, pageInset).padding(.top, 18).contentShape(.rect)   // the next section's rule brings its own 18 below
            }
            .buttonStyle(.plain)
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

    var path: String { String(id.dropFirst()) }

    var body: some View {
        let tracks = store.tracklists[path]
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let pos = store.position, dur = store.duration
            let current = tracks?.lastIndex { Double($0.offset ?? .max) <= pos }
            Push(shown: store.showTracklist && tracks != nil, keep: false) {
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
                        EpisodeInfo(details: d, tracks: tracks) { push { store.showTracklist = true } }
                        Spacer(minLength: 12)
                    }
                }
            } top: {
                if let tracks {
                    TracklistView(tracks: tracks, current: current, episode: path, seek: store.seekable ? { store.seek(to: $0) } : nil) { push { store.showTracklist = false } }
                }
            }
        }
        .task(id: path) { await store.loadTracklist(path) }
    }
}

struct ChannelNowView: View {
    @Environment(Store.self) var store
    let channel: Channel

    var body: some View {
        let b = channel.now, d = b.embeds?.details
        let tracks = d?.episodePath.flatMap { store.tracklists[$0] }
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(b.startTimestamp)
            let current = tracks?.lastIndex { Double($0.offset ?? .max) <= elapsed }
            Push(shown: store.showTracklist && tracks != nil, keep: false) {
                FitScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        let end = b.endTimestamp ?? ctx.date
                        NowHeader(image: d?.media?.wide, title: b.bareTitle) {
                            ChannelBadge(channel: channel.channelName, location: d?.locationLong ?? "")
                        } accessory: {
                            HStack(spacing: 14) {
                                if b.isReplay { ReplayIcon(size: 13).padding(.top, 3) }   // as wide as the 16pt title's cap height, level with it
                                SaveMenu(details: channel.now.embeds?.details, title: channel.now.title, date: channel.now.startTimestamp, size: 15)
                            }
                        }
                        .overlay(alignment: .top) { PlayOverlay() }
                        HStack {
                            Text(hours(b.startTimestamp, end).nts)
                            Spacer()
                            // 0, not negative, while an overrun waits for the next poll
                            Text("\(max(0, Int(end.timeIntervalSince(ctx.date) / 60))) MIN LEFT".nts).opacity(0.6)
                        }
                        .font(.nts(10.5, .regular)).padding(.horizontal, pageInset).padding(.top, 7)
                        EpisodeInfo(details: d, tracks: tracks) { push { store.showTracklist = true } }

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
            } top: {
                if let tracks {
                    TracklistView(tracks: tracks, current: current, episode: d?.episodePath) { push { store.showTracklist = false } }
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
            content.measureHeight($height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, contentHeight - miniHeight))   // only on Now Playing, which keeps the mini player
    }
}

struct TracklistView: View {
    let tracks: [Track], current: Int?, episode: String?
    var seek: ((Double) -> Void)?   // archive episodes: tap a track to jump to it
    let back: () -> Void
    @State private var listHeight = contentHeight
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // tracks repeat with the same uid (e.g. a jingle played twice), so key rows by position
                        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                            TrackRow(track: t, state: current == i ? .now : (current ?? -1) > i ? .past : .next, episode: episode)
                                .contentShape(.rect)
                                .onTapGesture { if let seek, let o = t.offset { seek(Double(o)) } }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { listHeight = $1 }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
            .frame(height: min(listHeight, contentHeight - 45 - miniHeight))   // short lists: the window shrinks to fit, as FitScroll does
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
            // saving needs the episode; removing (My NTS tracks, which come without one) only the uid
            if store.email != nil, let uid = track.uid, episode != nil || store.savedTracks.contains(uid) {
                Button(store.savedTracks.contains(uid) ? "Remove Track" : "Save Track") { store.toggleTrack(track, episode: episode ?? "") }
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
                    Icon(url: mixtape.media?.iconWhite.flatMap(URL.init))
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

