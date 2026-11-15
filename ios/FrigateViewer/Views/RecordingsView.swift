import SwiftUI

/// Pick a camera and a day, see which hours have footage and activity, tap to play.
struct RecordingsView: View {
    @Environment(AppModel.self) private var model

    struct HourSummary: Identifiable {
        let hourStart: Double
        var recorded: Double = 0
        var motion: Int = 0
        var alerts = 0
        var detections = 0
        var id: Double { hourStart }
    }

    @State private var hoursList: [HourSummary] = []
    @State private var loading = false
    @State private var error: String?

    private var selectedCamera: Camera? {
        if let name = model.recordingsCamera, let cam = model.camera(named: name) { return cam }
        return model.cameras.first
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Picker("Camera", selection: Binding(
                        get: { selectedCamera?.name ?? "" },
                        set: { model.recordingsCamera = $0 })) {
                        ForEach(model.cameras) { Text($0.displayName).tag($0.name) }
                    }
                    DatePicker("Day", selection: $model.recordingsDate, in: ...Date(), displayedComponents: .date)
                }

                if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                } else if !loading && hoursList.allSatisfy({ $0.recorded == 0 }) && selectedCamera != nil {
                    ContentUnavailableView("No recordings", systemImage: "film",
                                           description: Text("Nothing recorded for this camera on this day. Footage moved to the NAS archive isn't visible to Frigate."))
                }

                if let camera = selectedCamera {
                    Section("Hours") {
                        ForEach(hoursList.filter { $0.recorded > 0 }.reversed()) { hour in
                            NavigationLink {
                                RecordingPlayerView(camera: camera.name,
                                                    start: hour.hourStart,
                                                    end: min(hour.hourStart + 3600, Date().timeIntervalSince1970))
                            } label: {
                                HourRow(hour: hour)
                            }
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Recordings")
            .refreshable { await load() }
            .task(id: "\(selectedCamera?.name ?? "")|\(Calendar.current.startOfDay(for: model.recordingsDate).timeIntervalSince1970)") {
                await load()
            }
        }
    }

    private func load() async {
        guard let client = model.client, let camera = selectedCamera else { return }
        loading = true
        defer { loading = false }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: model.recordingsDate).timeIntervalSince1970
        let dayEnd = min(dayStart + 86400, Date().timeIntervalSince1970)
        do {
            try await client.ensureSession()
            async let segsTask = client.recordings(camera: camera.name, after: dayStart, before: dayEnd)
            async let revsTask = client.reviews(cameras: [camera.name], severity: nil, after: dayStart, before: dayEnd, limit: 1000)
            let segs = try await segsTask
            let revs = (try? await revsTask) ?? []

            // Hour boundaries follow the local calendar (handles DST days of 23/25 hours).
            var starts: [Double] = []
            var cursor = Date(unix: dayStart)
            while cursor.timeIntervalSince1970 < dayEnd {
                starts.append(cursor.timeIntervalSince1970)
                cursor = cal.date(byAdding: .hour, value: 1, to: cursor)!
            }
            var summaries = starts.map { HourSummary(hourStart: $0) }
            func index(for t: Double) -> Int? {
                guard let i = starts.lastIndex(where: { $0 <= t }) else { return nil }
                return i
            }
            for seg in segs {
                guard let i = index(for: max(seg.start, dayStart)) else { continue }
                summaries[i].recorded += max(min(seg.end, dayEnd) - max(seg.start, dayStart), 0)
                summaries[i].motion += seg.motion
            }
            for r in revs {
                guard let i = index(for: max(r.start, dayStart)) else { continue }
                if r.severity == .alert { summaries[i].alerts += 1 } else { summaries[i].detections += 1 }
            }
            hoursList = summaries
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct HourRow: View {
    let hour: RecordingsView.HourSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(Formatters.shortTime.string(from: Date(unix: hour.hourStart)))
                    .font(.headline.monospacedDigit())
                ProgressView(value: min(hour.recorded / 3600, 1))
                    .tint(.accentColor)
                    .frame(maxWidth: 160)
            }
            Spacer()
            if hour.alerts > 0 {
                Label("\(hour.alerts)", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            if hour.detections > 0 {
                Label("\(hour.detections)", systemImage: "eye.circle.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}
