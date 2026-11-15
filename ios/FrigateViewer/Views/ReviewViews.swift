import SwiftUI

/// Frigate's review items (alerts and detections) for the last day, newest first.
struct ReviewListView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case alerts = "Alerts", detections = "Detections", all = "All"
        var id: String { rawValue }
        var severity: ReviewItem.Severity? {
            switch self {
            case .alerts: return .alert
            case .detections: return .detection
            case .all: return nil
            }
        }
    }

    @State private var filter: Filter = .alerts
    @State private var cameraFilter: String?
    @State private var hours: Double = 24
    @State private var items: [ReviewItem] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Severity", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                } else if items.isEmpty && !loading {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                           description: Text("No \(filter.rawValue.lowercased()) in the last \(Int(hours)) hours."))
                }

                ForEach(groupedByDay) { group in
                    Section(group.day) {
                        ForEach(group.items) { item in
                            NavigationLink {
                                ReviewPlaybackView(item: item)
                            } label: {
                                ReviewRow(item: item, showCamera: cameraFilter == nil)
                            }
                        }
                    }
                }
            }
            .overlay { if loading && items.isEmpty { ProgressView() } }
            .navigationTitle("Review")
            .toolbar {
                Menu {
                    Picker("Camera", selection: $cameraFilter) {
                        Text("All cameras").tag(String?.none)
                        ForEach(model.cameras) { Text($0.displayName).tag(Optional($0.name)) }
                    }
                    Picker("Period", selection: $hours) {
                        Text("Last 24 hours").tag(24.0)
                        Text("Last 3 days").tag(72.0)
                        Text("Last 7 days").tag(168.0)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
            .refreshable { await load() }
            .task(id: "\(filter.rawValue)|\(cameraFilter ?? "")|\(hours)") { await load() }
        }
    }

    private struct DayGroup: Identifiable {
        let day: String
        let items: [ReviewItem]
        var id: String { day }
    }

    private var groupedByDay: [DayGroup] {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .none
        var order: [String] = []
        var groups: [String: [ReviewItem]] = [:]
        for item in items {
            let key = f.string(from: Date(unix: item.start))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { DayGroup(day: $0, items: groups[$0]!) }
    }

    private func load() async {
        guard let client = model.client else { return }
        loading = true
        defer { loading = false }
        let now = Date().timeIntervalSince1970
        do {
            try await client.ensureSession()
            items = try await client.reviews(cameras: cameraFilter.map { [$0] }, severity: filter.severity,
                                             after: now - hours * 3600, before: now, limit: 500)
                .sorted { $0.start > $1.start }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    let item: ReviewItem
    var showCamera = true

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let client = model.client, !item.thumbPath.isEmpty {
                    AuthImage(url: client.mediaURL(forStoredPath: item.thumbPath))
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                Circle().fill(item.severity == .alert ? Color.red : Color.orange)
                    .frame(width: 8, height: 8).padding(4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.objects.isEmpty ? item.severity.rawValue.capitalized
                     : item.objects.map { $0.capitalized }.joined(separator: ", "))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.reviewed ? .secondary : .primary)
                HStack(spacing: 4) {
                    if showCamera {
                        Text(model.camera(named: item.camera)?.displayName ?? item.camera)
                        Text("·")
                    }
                    Text(Formatters.shortTime.string(from: Date(unix: item.start)))
                    if let end = item.end {
                        Text("· \(Formatters.duration(end - item.start))")
                    } else {
                        Text("· ongoing").foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !item.zones.isEmpty {
                    Text(item.zones.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
