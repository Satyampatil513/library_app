import Foundation

/// Writes captured frames and stills to disk on a background queue. Never
/// accumulates frames in memory. If the queue falls behind, new *frames* are
/// dropped and counted rather than queued, so capture never stalls. Stills are
/// rare and never dropped.
final class FrameWriter {
    private let framesDirectory: URL
    private let stillsDirectory: URL
    private let queue = DispatchQueue(label: "com.roomcapture.framewriter", qos: .utility)
    private let stateLock = NSLock()
    private var pendingCount = 0
    private let maxPending: Int
    private var droppedCount = 0

    init(sessionDirectory: URL, maxPending: Int = 16) {
        self.framesDirectory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
        self.stillsDirectory = sessionDirectory.appendingPathComponent("stills", isDirectory: true)
        self.maxPending = maxPending
    }

    var droppedFrameCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return droppedCount
    }

    /// Returns false if the frame was dropped because the write queue is backlogged.
    @discardableResult
    func submit(_ payload: CapturedFramePayload) -> Bool {
        stateLock.lock()
        if pendingCount >= maxPending {
            droppedCount += 1
            stateLock.unlock()
            return false
        }
        pendingCount += 1
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.write(payload)
            self.stateLock.lock()
            self.pendingCount -= 1
            self.stateLock.unlock()
        }
        return true
    }

    func submitStill(index: Int, jpeg: Data) {
        queue.async { [stillsDirectory] in
            let name = String(format: "%06d_still.jpg", index)
            try? jpeg.write(to: stillsDirectory.appendingPathComponent(name), options: .atomic)
        }
    }

    /// Calls `completion` (on the writer queue) once every previously submitted write is on disk.
    func flush(_ completion: @escaping () -> Void) {
        queue.async(execute: completion)
    }

    private func write(_ payload: CapturedFramePayload) {
        let indexString = String(format: "%06d", payload.index)
        try? payload.rgbData.write(to: framesDirectory.appendingPathComponent("\(indexString)_rgb.jpg"), options: .atomic)
        try? payload.depthData.write(to: framesDirectory.appendingPathComponent("\(indexString)_depth.bin"), options: .atomic)
        try? payload.confidenceData.write(to: framesDirectory.appendingPathComponent("\(indexString)_conf.bin"), options: .atomic)
    }
}
