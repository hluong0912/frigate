import SwiftUI

struct CameraGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: sizeClass == .regular ? 3 : 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.cameras.isEmpty {
                    if model.isLoading {
                        ProgressView().padding(.top, 80)
                    } else if let err = model.lastError {
                        ErrorBanner(message: err) { Task { await model.refresh() } }.padding(.top, 60)
                    } else {
                        ContentUnavailableView("No cameras", systemImage: "video.slash",
                                               description: Text("Frigate returned no enabled cameras."))
                            .padding(.top, 60)
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.cameras) { camera in
                            NavigationLink(value: camera) {
                                CameraTile(camera: camera)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Live")
            .navigationDestination(for: Camera.self) { LiveCameraView(camera: $0) }
        }
    }
}

private struct CameraTile: View {
    let camera: Camera

    var body: some View {
        SnapshotView(camera: camera, height: 360, interval: .seconds(4))
            .aspectRatio(camera.aspectRatio, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                Text(camera.displayName)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct LiveCameraView: View {
    @Environment(AppModel.self) private var model
    let camera: Camera

    enum Mode: String, CaseIterable, Identifiable {
        case webrtc = "Live"
        case snapshot = "Snapshots"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .webrtc
    @State private var stream: LiveStream?
    @State private var muted = true
    @State private var status: WebRTCPlayerView.Status = .connecting
    @State private var recent: [ReviewItem] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                player
                    .aspectRatio(camera.aspectRatio, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode == .webrtc && camera.liveStreams.count > 1 {
                    Picker("Stream", selection: Binding(
                        get: { stream ?? camera.liveStreams[0] },
                        set: { stream = $0 })) {
                        ForEach(camera.liveStreams) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                HStack {
                    Button {
                        model.showRecordings(camera: camera.name)
                    } label: {
                        Label("Recordings", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    NavigationLink {
                        RecordingPlayerView(camera: camera.name,
                                            start: Date().timeIntervalSince1970 - 15 * 60,
                                            end: Date().timeIntervalSince1970)
                    } label: {
                        Label("Last 15 min", systemImage: "gobackward.15")
                    }
                    .buttonStyle(.bordered)
                }

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent activity").font(.headline)
                        ForEach(recent) { item in
                            NavigationLink {
                                ReviewPlaybackView(item: item)
                            } label: {
                                ReviewRow(item: item, showCamera: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(camera.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .webrtc {
                Button {
                    muted.toggle()
                } label: {
                    Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
                }
            }
        }
        .task(id: camera.name) {
            guard let client = model.client else { return }
            let now = Date().timeIntervalSince1970
            recent = (try? await client.reviews(cameras: [camera.name], severity: nil,
                                                 after: now - 24 * 3600, before: now, limit: 10)) ?? []
        }
    }

    @ViewBuilder private var player: some View {
        switch mode {
        case .webrtc:
            if let client = model.client {
                WebRTCPlayerView(client: client,
                                 stream: (stream ?? camera.liveStreams[0]).stream,
                                 muted: muted,
                                 status: $status)
                    .overlay {
                        switch status {
                        case .playing:
                            EmptyView()
                        case .connecting:
                            ProgressView("Connecting…").tint(.white).foregroundStyle(.white)
                        case let .failed(reason):
                            VStack(spacing: 8) {
                                Text("Live stream unavailable").font(.headline)
                                Text(reason).font(.caption).multilineTextAlignment(.center)
                                Button("Use snapshots") { mode = .snapshot }.buttonStyle(.borderedProminent)
                            }
                            .foregroundStyle(.white)
                            .padding()
                        }
                    }
            }
        case .snapshot:
            SnapshotView(camera: camera, height: 720, interval: .seconds(1), contentMode: .fit)
        }
    }
}
