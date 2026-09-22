import Foundation

/// Holds the manifest and (re)writes manifest.json. Foundation-only.
///
/// Checkpointed periodically (on a background queue, so capture never waits
/// on JSON encoding) and on finalize, so a session killed mid-recording still
/// leaves a valid manifest for every frame recorded so far.
final class ManifestBuilder {
    private let manifestURL: URL
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.roomcapture.manifest", qos: .utility)
    private var manifest: SessionManifest
    private var framesSinceCheckpoint = 0
    private let checkpointInterval: Int

    init(sessionDirectory: URL, manifest: SessionManifest, checkpointInterval: Int = 30) {
        self.manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        self.manifest = manifest
        self.checkpointInterval = checkpointInterval
    }

    func writeInitial() {
        write(complete: false, endedAt: nil, synchronous: true)
    }

    func addFrame(_ frame: ManifestFrame) {
        lock.lock()
        manifest.frames.append(frame)
        framesSinceCheckpoint += 1
        let shouldCheckpoint = framesSinceCheckpoint >= checkpointInterval
        if shouldCheckpoint { framesSinceCheckpoint = 0 }
        lock.unlock()
        if shouldCheckpoint { write(complete: false, endedAt: nil, synchronous: false) }
    }

    func addStill(_ still: ManifestStill) {
        lock.lock(); manifest.stills.append(still); lock.unlock()
        write(complete: false, endedAt: nil, synchronous: false)
    }

    func addNote(_ note: ManifestNote) {
        lock.lock(); manifest.notes.append(note); lock.unlock()
        write(complete: false, endedAt: nil, synchronous: false)
    }

    func updateDroppedCount(_ count: Int) {
        lock.lock(); manifest.dropped_frames = count; lock.unlock()
    }

    /// Sets the actual buffer dimensions from the first captured frame (never hardcoded).
    func setDimensions(depthWidth: Int, depthHeight: Int, rgbWidth: Int, rgbHeight: Int) {
        lock.lock()
        manifest.depth_width = depthWidth
        manifest.depth_height = depthHeight
        manifest.rgb_width = rgbWidth
        manifest.rgb_height = rgbHeight
        lock.unlock()
    }

    func setAudioStart(_ arTimestamp: Double) {
        lock.lock(); manifest.audio.start_ar_timestamp = arTimestamp; lock.unlock()
    }

    @discardableResult
    func finalize(droppedFrames: Int, worldMap: WorldMapInfo?) -> URL {
        lock.lock()
        manifest.dropped_frames = droppedFrames
        manifest.world_map = worldMap
        lock.unlock()
        write(complete: true, endedAt: Date().timeIntervalSince1970, synchronous: true)
        return manifestURL
    }

    private func write(complete: Bool, endedAt: Double?, synchronous: Bool) {
        lock.lock()
        var snapshot = manifest
        lock.unlock()
        snapshot.stills.sort { $0.index < $1.index }
        snapshot.complete = complete
        snapshot.ended_at_unix = endedAt

        let url = manifestURL
        let job = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if synchronous { writeQueue.sync(execute: job) } else { writeQueue.async(execute: job) }
    }
}
