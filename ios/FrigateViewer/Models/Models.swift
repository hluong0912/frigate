import Foundation

// MARK: - /api/config (only the parts the app needs)

struct FrigateConfig: Decodable {
    let cameras: [String: CameraConfig]
}

struct CameraConfig: Decodable {
    let name: String
    let enabled: Bool
    let friendlyName: String?
    let live: Live?
    let ui: UI?
    let detect: Detect?
    let record: Record?

    struct Live: Decodable { let streams: [String: String]? }
    struct UI: Decodable { let order: Int?; let dashboard: Bool? }
    struct Detect: Decodable { let width: Int?; let height: Int? }
    struct Record: Decodable { let enabled: Bool? }

    enum CodingKeys: String, CodingKey {
        case name, enabled, live, ui, detect, record
        case friendlyName = "friendly_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        friendlyName = try? c.decode(String.self, forKey: .friendlyName)
        live = try? c.decode(Live.self, forKey: .live)
        ui = try? c.decode(UI.self, forKey: .ui)
        detect = try? c.decode(Detect.self, forKey: .detect)
        record = try? c.decode(Record.self, forKey: .record)
    }
}

struct LiveStream: Hashable, Identifiable {
    /// Label shown to the user, e.g. "Main" or "Sub".
    let label: String
    /// go2rtc stream name used for WebRTC.
    let stream: String
    var id: String { stream }
}

struct Camera: Identifiable, Hashable {
    let name: String
    let displayName: String
    let enabled: Bool
    let order: Int
    let aspectRatio: Double
    let recordingEnabled: Bool
    let liveStreams: [LiveStream]

    var id: String { name }

    init(_ config: CameraConfig) {
        name = config.name
        displayName = config.friendlyName?.isEmpty == false
            ? config.friendlyName!
            : config.name.replacingOccurrences(of: "_", with: " ").capitalized
        enabled = config.enabled
        order = config.ui?.order ?? 0
        if let w = config.detect?.width, let h = config.detect?.height, w > 0, h > 0 {
            aspectRatio = Double(w) / Double(h)
        } else {
            aspectRatio = 16.0 / 9.0
        }
        recordingEnabled = config.record?.enabled ?? false
        let streams = (config.live?.streams ?? [:])
            .map { LiveStream(label: $0.key, stream: $0.value) }
            .sorted { $0.label < $1.label }
        // Frigate defaults the live stream to a go2rtc stream named after the camera.
        liveStreams = streams.isEmpty ? [LiveStream(label: "Main", stream: config.name)] : streams
    }
}

// MARK: - Timestamps

/// Frigate returns unix seconds as numbers; be lenient and accept ISO strings too.
struct FlexibleTime: Decodable, Hashable {
    let value: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            if let d = Double(s) {
                value = d
            } else if let date = FlexibleTime.iso.date(from: s) ?? FlexibleTime.isoFrac.date(from: s) {
                value = date.timeIntervalSince1970
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad time \(s)")
            }
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Missing time")
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - /api/<camera>/recordings

struct RecordingSegment: Decodable, Hashable, Identifiable {
    let id: String
    let start: Double
    let end: Double
    let motion: Int
    let objects: Int

    enum CodingKeys: String, CodingKey {
        case id, motion, objects
        case start = "start_time"
        case end = "end_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        start = try c.decode(FlexibleTime.self, forKey: .start).value
        end = try c.decode(FlexibleTime.self, forKey: .end).value
        motion = (try? c.decode(Int.self, forKey: .motion)) ?? 0
        objects = (try? c.decode(Int.self, forKey: .objects)) ?? 0
    }

    init(id: String, start: Double, end: Double, motion: Int = 0, objects: Int = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.motion = motion
        self.objects = objects
    }
}

// MARK: - /api/review

struct ReviewItem: Decodable, Hashable, Identifiable {
    enum Severity: String, Decodable, CaseIterable {
        case alert, detection
    }

    let id: String
    let camera: String
    let start: Double
    let end: Double?
    let severity: Severity
    let thumbPath: String
    let reviewed: Bool
    let objects: [String]
    let zones: [String]

    var isOngoing: Bool { end == nil }

    enum CodingKeys: String, CodingKey {
        case id, camera, severity, data
        case start = "start_time"
        case end = "end_time"
        case thumbPath = "thumb_path"
        case reviewed = "has_been_reviewed"
    }

    struct DataPayload: Decodable {
        let objects: [String]?
        let zones: [String]?
        let audio: [String]?
        let subLabels: [String]?

        enum CodingKeys: String, CodingKey {
            case objects, zones, audio
            case subLabels = "sub_labels"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        camera = try c.decode(String.self, forKey: .camera)
        start = try c.decode(FlexibleTime.self, forKey: .start).value
        end = try? c.decode(FlexibleTime.self, forKey: .end).value
        severity = (try? c.decode(Severity.self, forKey: .severity)) ?? .detection
        thumbPath = (try? c.decode(String.self, forKey: .thumbPath)) ?? ""
        reviewed = (try? c.decode(Bool.self, forKey: .reviewed))
            ?? ((try? c.decode(Int.self, forKey: .reviewed)) ?? 0) != 0
        let payload = try? c.decode(DataPayload.self, forKey: .data)
        let labels = (payload?.objects ?? []) + (payload?.audio ?? [])
        // Frigate tags tracked objects that moved as "<label>-verified"; tidy for display.
        var seen = Set<String>()
        objects = labels
            .map { $0.replacingOccurrences(of: "-verified", with: "") }
            .filter { seen.insert($0).inserted }
        zones = payload?.zones ?? []
    }
}

// MARK: - Playback timeline

/// Frigate's VOD playlist concatenates recording segments and drops gaps, so
/// player time is not wall-clock time. This maps between the two.
struct PlaybackTimeline {
    struct Piece {
        let wallStart: Double
        let playerStart: Double
        let duration: Double
    }

    let pieces: [Piece]
    let rangeStart: Double
    let rangeEnd: Double

    init(segments: [RecordingSegment], start: Double, end: Double) {
        rangeStart = start
        rangeEnd = end
        var offset = 0.0
        var result: [Piece] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            let s = max(seg.start, start)
            let e = min(seg.end, end)
            let d = e - s
            guard d > 0.1 else { continue }
            result.append(Piece(wallStart: s, playerStart: offset, duration: d))
            offset += d
        }
        pieces = result
    }

    var isEmpty: Bool { pieces.isEmpty }
    var totalDuration: Double { pieces.last.map { $0.playerStart + $0.duration } ?? 0 }

    func wallTime(forPlayerTime t: Double) -> Double? {
        guard let piece = pieces.last(where: { $0.playerStart <= t }) ?? pieces.first else { return nil }
        return piece.wallStart + min(max(t - piece.playerStart, 0), piece.duration)
    }

    /// Player time for a wall-clock time; snaps forward to the next recorded piece inside a gap.
    func playerTime(forWallTime w: Double) -> Double? {
        for piece in pieces {
            if w < piece.wallStart { return piece.playerStart }
            if w <= piece.wallStart + piece.duration { return piece.playerStart + (w - piece.wallStart) }
        }
        return pieces.isEmpty ? nil : totalDuration
    }
}
