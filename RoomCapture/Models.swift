import Foundation

/// Everything below uses only Foundation so it is testable without ARKit/AVFoundation.

struct AudioInfo: Codable {
    let file: String
    let sample_rate: Int
    let channels: Int
    var start_ar_timestamp: Double
}

/// Per-frame live-check metrics [F3], recorded so the server (and threshold
/// tuning) can use them. Blur score is a Laplacian variance on luma.
struct ManifestFrameQuality: Codable {
    let blur_score: Float
    let center_depth_m: Float?
    let low_conf_fraction: Float
    let speed_mps: Float?
    let angular_speed_rps: Float?
}

struct ManifestFrame: Codable {
    let index: Int
    let ar_timestamp: Double
    let rgb: String
    let depth: String
    let confidence: String
    let transform: [[Float]]
    let intrinsics: [[Float]]
    let tracking_state: String
    let quality: ManifestFrameQuality?
}

/// Hi-res still [F1] with its own pose and intrinsics.
struct ManifestStill: Codable {
    let index: Int
    let ar_timestamp: Double
    let file: String
    let width: Int
    let height: Int
    let transform: [[Float]]
    let intrinsics: [[Float]]
    let tracking_state: String
    /// "auto" (~40cm moved), "button", or "voice"
    let trigger: String
}

/// Typed note [F2], tied to the object the camera was aimed at: the note
/// stores the camera pose and the 3D world point at the centre of view.
struct ManifestNote: Codable {
    let index: Int
    let text: String
    let ar_timestamp: Double
    let frame_index: Int?
    let transform: [[Float]]
    let target_point_world: [Float]?
    let target_distance_m: Float?
}

struct WorldMapInfo: Codable {
    let file: String
    let status: String
}

/// Matches the required manifest.json shape, plus additive fields.
/// `complete` stays false until a clean stop finalizes it, so a partial
/// session (killed mid-recording) is still valid and readable.
struct SessionManifest: Codable {
    let session_id: String
    let device_model: String
    let ios_version: String
    let started_at_unix: Double
    let country: String
    let relocalized_against: String?
    let relocalized_at_ar_timestamp: Double?
    let faces_blurred: Bool
    var audio: AudioInfo
    var depth_width: Int
    var depth_height: Int
    var rgb_width: Int
    var rgb_height: Int
    var frames: [ManifestFrame]
    var stills: [ManifestStill]
    var notes: [ManifestNote]
    var world_map: WorldMapInfo?
    var dropped_frames: Int
    var complete: Bool
    var ended_at_unix: Double?
}

/// Fully-converted, Foundation-only payload for one captured frame.
struct CapturedFramePayload {
    let index: Int
    let arTimestamp: Double
    let rgbData: Data
    let depthData: Data
    let confidenceData: Data
    let transform: [[Float]]
    let intrinsics: [[Float]]
    let trackingState: String
}
