import SwiftUI
import AVFoundation

// MARK: - API (undocumented, same endpoints nts.live uses)

let api = URL(string: "https://www.nts.live/api/v2")!
let liveStreams = ["1": "https://stream-relay-geo.ntslive.net/stream",
                   "2": "https://stream-relay-geo.ntslive.net/stream2"]

struct Media: Decodable {
    var backgroundMediumLarge: String?, pictureMedium: String?, pictureLarge: String?, pictureSmall: String?
    var thumb: URL? { (pictureSmall ?? pictureMedium ?? pictureLarge).flatMap(URL.init) }
    var wide: URL? { (backgroundMediumLarge ?? pictureLarge).flatMap(URL.init) }
}
struct Tag: Decodable { var value: String }
struct Details: Decodable {
    var name: String?, description: String?, locationLong: String?, showAlias: String?, episodeAlias: String?
    var media: Media?, genres: [Tag]?
    /// API path of this episode, e.g. shows/x/episodes/y
    var episodePath: String? { showAlias.flatMap { s in episodeAlias.map { "shows/\(s)/episodes/\($0)" } } }
}
struct Broadcast: Decodable {
    var broadcastTitle: String, startTimestamp: Date, endTimestamp: Date?
    // API titles carry HTML entities (e.g. &amp;)
    var title: String { broadcastTitle.replacing("&amp;", with: "&").replacing("&#39;", with: "'").replacing("&quot;", with: "\"") }
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
    var uid: String, artist: String?, title: String?, offset: Int?, duration: Int?
    var id: String { uid }
}
struct Credit: Decodable { var name: String, path: String }
struct Mixtape: Decodable, Identifiable {
    var mixtapeAlias: String, title: String, subtitle: String, audioStreamEndpoint: String, media: Media?
    var description: String?, credits: [Credit]?
    var id: String { mixtapeAlias }
}
struct Results<T: Decodable>: Decodable { var results: [T] }

func fetch<T: Decodable>(_ path: String) async throws -> [T] {
    // API sends max-age=900 and CloudFront caches per header variant, so a show change can lag up to
    // 15 min. A timestamp query makes each request a cache miss (one small request a minute).
    let url = api.appending(path: path).appending(queryItems: [.init(name: "t", value: String(Int(Date().timeIntervalSince1970)))])
    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    d.dateDecodingStrategy = .iso8601
    return try d.decode(Results<T>.self, from: data).results
}

// MARK: - Store

struct Saved: Codable, Identifiable, Hashable {
    var id: String          // nts.live path: /shows/x or /shows/x/episodes/y
    var title: String
    var subtitle: String
    var image: URL?
    var isEpisode: Bool { id.contains("/episodes/") }
}

@Observable @MainActor final class Store {
    var live: [Channel] = []
    var mixtapes: [Mixtape] = []
    var playingID: String?
    var error: String?
    var tracklists: [String: [Track]] = [:]   // by episode path
    var saved: [Saved] = (UserDefaults.standard.data(forKey: "saved"))
        .flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "saved") }
    }
    private let player = AVPlayer()

    init() {
        Task {
            while true {
                do { live = try await fetch("live"); error = nil } catch { self.error = "Can't reach NTS" }
                // poll every 60s, but also wake just after the earliest current show ends
                let ends = live.compactMap(\.now.endTimestamp).map { $0.timeIntervalSinceNow + 5 }.filter { $0 > 0 }
                try? await Task.sleep(for: .seconds(min(60, ends.min() ?? 60)))
            }
        }
        Task { mixtapes = (try? await fetch("mixtapes")) ?? [] }
    }

    /// Tapping the playing item stops it (pausing a live stream would just drift behind).
    func toggle(_ id: String, _ url: String) {
        if playingID == id { player.pause(); playingID = nil; return }
        guard let u = URL(string: url) else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: u))
        player.play()
        playingID = id
    }

    func loadTracklist(_ episodePath: String) async {
        guard tracklists[episodePath] == nil else { return }
        tracklists[episodePath] = (try? await fetch(episodePath + "/tracklist")) ?? []
    }

    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }
    func toggleSave(_ item: Saved) {
        if isSaved(item.id) { saved.removeAll { $0.id == item.id } } else { saved.insert(item, at: 0) }
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
            // --playing <id> fakes what's playing (no audio); --tab now opens on Now Playing
            if let j = args.firstIndex(of: "--playing"), j + 1 < args.count { s.playingID = args[j + 1] }
            snapshot(s, to: args[i + 1], page: args.contains("now") ? .nowPlaying : .live)
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

struct RootView: View {
    @State var page = Page.live

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
            Rectangle().fill(.white).frame(height: 1)
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
        let playing = store.playingID == channel.id
        ZStack(alignment: .topLeading) {
            Cover(url: d?.media?.wide)
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.45)],
                           startPoint: .top, endPoint: .bottom)
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
                    SaveMenu(channel: channel)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 3)
            .padding(.leading, 8).padding(.trailing, 10).padding(.top, 7).padding(.bottom, 9)
        }
        .frame(height: cardHeight)
    }
}

struct SaveMenu: View {
    @Environment(Store.self) var store
    let channel: Channel
    var size: CGFloat = 20

    var body: some View {
        let d = channel.now.embeds?.details
        if let show = d?.showAlias {
            let showItem = Saved(id: "/shows/\(show)", title: d?.name ?? channel.now.title,
                                 subtitle: d?.locationLong ?? "", image: d?.media?.thumb)
            Menu {
                Button(store.isSaved(showItem.id) ? "Unfollow Show" : "Follow Show") { store.toggleSave(showItem) }
                if let ep = d?.episodeAlias {
                    let epItem = Saved(id: "/shows/\(show)/episodes/\(ep)", title: channel.now.title,
                                       subtitle: channel.now.startTimestamp.formatted(date: .abbreviated, time: .omitted),
                                       image: d?.media?.thumb)
                    Button(store.isSaved(epItem.id) ? "Remove Episode" : "Save Episode") { store.toggleSave(epItem) }
                }
            } label: {
                Image(systemName: store.isSaved(showItem.id) ? "bookmark.fill" : "bookmark").font(.system(size: size))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.white)
        }
    }
}

// MARK: - Mixtapes / Saved

struct Row: View {
    let image: URL?, title: String, subtitle: String, active: Bool
    var body: some View {
        HStack(spacing: 12) {
            Cover(url: image).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.nts).font(.nts(18)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).opacity(0.6).lineLimit(2)
            }
            Spacer()
            if active { Circle().fill(.red).frame(width: 8, height: 8) }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .contentShape(.rect)
    }
}

struct MixtapesView: View {
    @Environment(Store.self) var store
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.mixtapes) { m in
                    Row(image: m.media?.thumb, title: m.title, subtitle: m.subtitle, active: store.playingID == m.id)
                        .onTapGesture { store.toggle(m.id, m.audioStreamEndpoint) }
                    Rule()
                }
            }
        }
    }
}

struct SavedView: View {
    @Environment(Store.self) var store
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.saved.isEmpty {
                        Text("NOTHING SAVED YET".nts).font(.nts(16)).opacity(0.5)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    section("SHOWS", store.saved.filter { !$0.isEpisode })
                    section("EPISODES", store.saved.filter(\.isEpisode))
                }
            }
            Button("QUIT") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.nts(13)).opacity(0.5)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(10)
        }
    }

    @ViewBuilder func section(_ title: String, _ items: [Saved]) -> some View {
        if !items.isEmpty {
            Text(title).font(.nts(14)).opacity(0.5).padding(.horizontal, 9).padding(.top, 14).padding(.bottom, 4)
            ForEach(items) { s in
                Row(image: s.image, title: s.title, subtitle: s.subtitle, active: false)
                    // ponytail: opens nts.live; archive audio is SoundCloud/Mixcloud, in-app playback needs a hidden WKWebView embed
                    .onTapGesture { NSWorkspace.shared.open(URL(string: "https://www.nts.live" + s.id)!) }
                    .contextMenu { Button("Remove") { store.toggleSave(s) } }
                Rule()
            }
        }
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
    let image: URL?, title: String, progress: Double
    @ViewBuilder let badge: Badge
    @ViewBuilder let accessory: Accessory
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Cover(url: image).frame(height: 221)
            Rectangle().fill(.white.opacity(0.3)).frame(height: 2)
                .overlay(alignment: .leading) { Rectangle().fill(.white).frame(width: 360 * progress) }
            badge.padding(.horizontal, pageInset).padding(.top, 16)
            HStack(alignment: .top, spacing: 16) {
                Text(title.nts).font(.nts(16)).fixedSize(horizontal: false, vertical: true)
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
    var body: some View {
        Text(text.nts).font(.nts(13)).opacity(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pageInset).padding(.top, 16).padding(.bottom, 6)
    }
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
                TracklistView(tracks: tracks, current: current) { showTracklist = false }
            } else {
                FitScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        let end = b.endTimestamp ?? ctx.date
                        NowHeader(image: d?.media?.wide, title: b.title, progress: fraction(b, at: ctx.date)) {
                            ChannelBadge(channel: channel.channelName, location: d?.locationLong ?? "")
                        } accessory: {
                            SaveMenu(channel: channel, size: 15)
                        }
                        HStack {
                            Text("\(hhmm(b.startTimestamp)) - \(hhmm(end))".nts)
                            Spacer()
                            Text("\(Int(end.timeIntervalSince(ctx.date) / 60)) MIN LEFT".nts).opacity(0.6)
                        }
                        .font(.nts(10.5, .regular)).padding(.horizontal, pageInset).padding(.top, 7)
                        // Tag + description sizes measured from the NTS iPhone episode page (×0.896 for 360pt)
                        if let genres = d?.genres, !genres.isEmpty {
                            HStack(spacing: 7) {
                                ForEach(genres.prefix(4), id: \.value) {
                                    Text($0.value.nts).font(.nts(10)).opacity(0.85)
                                        .padding(.horizontal, 9).frame(height: 29)
                                        .overlay(Rectangle().strokeBorder(.white.opacity(0.33), lineWidth: 1))
                                }
                            }
                            .padding(.horizontal, pageInset).padding(.top, 12)
                        }
                        if let desc = d?.description, !desc.isEmpty {
                            Text(desc).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, pageInset).padding(.top, 13)
                        }

                        if let tracks, !tracks.isEmpty {
                            SectionLabel(text: "Playing now")
                            Button { showTracklist = true } label: {
                                VStack(spacing: 0) {
                                    if let current { TrackRow(track: tracks[current], state: .now) }
                                    let next = (current ?? -1) + 1
                                    if next < tracks.count { TrackRow(track: tracks[next], state: .next) }
                                }
                                .overlay(alignment: .trailing) {
                                    Image(systemName: "chevron.right").font(.nts(15)).opacity(0.6).padding(.trailing, pageInset)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 12)
                    }
                }
            }
        }
        .task(id: d?.episodePath) { if let p = d?.episodePath { await store.loadTracklist(p) } }
    }

    func fraction(_ b: Broadcast, at now: Date) -> Double {
        let end = b.endTimestamp ?? now
        return max(0, min(1, now.timeIntervalSince(b.startTimestamp) / max(1, end.timeIntervalSince(b.startTimestamp))))
    }
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
    let tracks: [Track], current: Int?, back: () -> Void
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
                            TrackRow(track: t, state: current == i ? .now : (current ?? -1) > i ? .past : .next)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
        }
    }
}

struct TrackRow: View {
    enum State { case past, now, next }
    let track: Track, state: State
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(.red).frame(width: 6, height: 6).padding(.top, 6).opacity(state == .now ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text((track.artist ?? "").nts).font(.nts(15)).lineLimit(1)
                Text(track.title ?? "").font(.system(size: 12)).opacity(0.75).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, pageInset).padding(.vertical, 5)
        .background(state == .now ? Color.white.opacity(0.08) : .clear)
        .opacity(state == .past ? 0.4 : 1)
    }
}

struct MixtapeNowView: View {
    let mixtape: Mixtape
    var body: some View {
        FitScroll {
            VStack(alignment: .leading, spacing: 0) {
                NowHeader(image: mixtape.media?.wide, title: mixtape.title, progress: 1) {
                    HStack(spacing: 7) {
                        Circle().fill(.red).frame(width: 5, height: 5)
                        Text("INFINITE MIXTAPE".nts).font(.nts(12.4, .regular))
                    }
                } accessory: { EmptyView() }
                Text(mixtape.subtitle).font(.system(size: 13, weight: .semibold)).padding(.horizontal, pageInset).padding(.top, 12)
                if let desc = mixtape.description {
                    Text(desc).font(.system(size: 13)).padding(.horizontal, pageInset).padding(.top, 6)
                }
                // ponytail: no public per-track feed for mixtapes (now_playing_topic is empty), so show the source shows
                SectionLabel(text: "Featuring shows from")
                ForEach(mixtape.credits ?? [], id: \.path) { c in
                    Button { NSWorkspace.shared.open(URL(string: "https://www.nts.live" + c.path)!) } label: {
                        Text(c.name.nts).font(.nts(14)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, pageInset).padding(.vertical, 4).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 12)
            }
        }
    }
}
