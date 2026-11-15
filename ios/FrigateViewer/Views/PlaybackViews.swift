import AVKit
import SwiftUI

/// Plays recorded video for one camera between two unix timestamps using
/// Frigate's HLS VOD endpoint, and shows the wall-clock time being watched.
struct RecordingPlayerView: View {
    @Environment(AppModel.self) private var model
    let camera: String
    @State var start: Double
    @State var end: Double
    /// Optional wall-clock time to seek to once loaded.
    var focus: Double?
    /// Whether to show the previous/next buttons that move by the range length.
    var allowsPaging = true

    @State private var player: AVPlayer?
    @State private var timeline: PlaybackTimeline?
    @State private var reviews: [ReviewItem] = []
    @State private var currentWall: Double?
    @State private var error: String?
    @State private var loading = true
    @State private var timeObserver: Any?

    private var title: String { model.camera(named: camera)?.displayName ?? camera }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Color.black
                    if let player {
                        PlayerController(player: player)
                    } else if loading {
                        ProgressView().tint(.white)
                    } else if let error {
                        Text(error).foregroundStyle(.white).font(.callout).multilineTextAlignment(.center).padding()
                    }
                }
                .aspectRatio(model.camera(named: camera)?.aspectRatio ?? 16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    VStack(alignment: .leading) {
                        Text(currentWall.map { Formatters.time.string(from: Date(unix: $0)) } ?? "--:--:--")
                            .font(.title3.monospacedDigit().weight(.semibold))
                        Text("\(Formatters.dayTime.string(from: Date(unix: start))) – \(Formatters.shortTime.string(from: Date(unix: end)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                    Button { seek(by: 10) } label: { Image(systemName: "goforward.10") }
                }
                .buttonStyle(.bordered)

                if allowsPaging {
                    HStack {
                        Button { page(-1) } label: { Label("Earlier", systemImage: "chevron.left") }
                        Spacer()
                        Button { page(1) } label: { Label("Later", systemImage: "chevron.right") }
                            .disabled(end >= Date().timeIntervalSince1970)
                    }
                    .buttonStyle(.bordered)
                }

                if let timeline, !timeline.isEmpty {
                    CoverageBar(timeline: timeline, reviews: reviews, current: currentWall) { wall in
                        seek(toWall: wall)
                    }
                    .frame(height: 28)
                }

                if !reviews.isEmpty {
                    Text("Activity in this range").font(.headline).padding(.top, 4)
                    ForEach(reviews) { item in
                        Button {
                            seek(toWall: item.start - 3)
                        } label: {
                            ReviewRow(item: item, showCamera: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(start)-\(end)") { await load() }
        .onDisappear { teardown() }
    }

    private func load() async {
        guard let client = model.client else { return }
        teardown()
        loading = true
        error = nil
        defer { loading = false }
        do {
            try await client.ensureSession()
            async let segs = client.recordings(camera: camera, after: start, before: end)
            async let revs = client.reviews(cameras: [camera], severity: nil, after: start, before: end)
            let segments = try await segs
            reviews = ((try? await revs) ?? []).sorted { $0.start < $1.start }
            let tl = PlaybackTimeline(segments: segments, start: start, end: end)
            timeline = tl
            guard !tl.isEmpty else {
                error = "No recordings for this time. Recordings that were moved to the NAS archive can't be played through Frigate."
                return
            }
            let asset = AVURLAsset(url: client.vodURL(camera: camera, start: start, end: end), options: assetOptions(client))
            let item = AVPlayerItem(asset: asset)
            let p = AVPlayer(playerItem: item)
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { t in
                currentWall = tl.wallTime(forPlayerTime: t.seconds)
            }
            player = p
            if let focus, let pt = tl.playerTime(forWallTime: focus) {
                _ = await p.seek(to: CMTime(seconds: pt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            p.play()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func assetOptions(_ client: FrigateClient) -> [String: Any] {
        var options: [String: Any] = [:]
        // Header injection for HLS is an undocumented but long-standing AVURLAsset option;
        // the cookie option is the documented fallback. Frigate accepts either.
        if !client.authHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = client.authHeaders }
        if let cookie = client.authCookie { options[AVURLAssetHTTPCookiesKey] = [cookie] }
        return options
    }

    private func teardown() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func seek(by delta: Double) {
        guard let player else { return }
        let t = max(player.currentTime().seconds + delta, 0)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    private func seek(toWall wall: Double) {
        guard let player, let pt = timeline?.playerTime(forWallTime: wall) else { return }
        player.seek(to: CMTime(seconds: pt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func page(_ direction: Double) {
        let length = end - start
        start += direction * length
        end += direction * length
    }
}

/// Thin strip showing where recordings exist, where review items are, and the playhead.
struct CoverageBar: View {
    let timeline: PlaybackTimeline
    let reviews: [ReviewItem]
    let current: Double?
    let onTap: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let span = max(timeline.rangeEnd - timeline.rangeStart, 1)
            let x: (Double) -> CGFloat = { CGFloat(($0 - timeline.rangeStart) / span) * geo.size.width }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill))
                ForEach(timeline.pieces.indices, id: \.self) { i in
                    let piece = timeline.pieces[i]
                    Rectangle().fill(Color.accentColor.opacity(0.45))
                        .frame(width: max(x(piece.wallStart + piece.duration) - x(piece.wallStart), 1))
                        .offset(x: x(piece.wallStart))
                }
                ForEach(reviews) { item in
                    Rectangle().fill(item.severity == .alert ? Color.red : Color.orange)
                        .frame(width: max(x(item.end ?? timeline.rangeEnd) - x(item.start), 2), height: 8)
                        .offset(x: x(item.start), y: 10)
                }
                if let current {
                    Rectangle().fill(Color.primary).frame(width: 2).offset(x: x(current))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { location in
                onTap(timeline.rangeStart + Double(location.x / geo.size.width) * span)
            }
        }
    }
}

/// AVPlayerViewController gives fullscreen, AirPlay and picture-in-picture for free.
struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

/// Playback for a single review item, padded a few seconds either side.
struct ReviewPlaybackView: View {
    let item: ReviewItem

    var body: some View {
        let end = item.end ?? Date().timeIntervalSince1970
        RecordingPlayerView(camera: item.camera,
                            start: item.start - 5,
                            end: end + 5,
                            focus: item.start - 2,
                            allowsPaging: false)
    }
}
