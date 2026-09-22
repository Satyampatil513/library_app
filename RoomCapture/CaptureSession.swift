import ARKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import SceneKit
import SwiftUI
import UIKit
import Vision

/// The ONLY file that touches ARKit/AVFoundation/Vision. Everything it
/// hands to FrameWriter/ManifestBuilder is Foundation-only (Data, arrays, Doubles, Strings).

enum CaptureStatus: Equatable {
    case idle
    case relocalizing   // waiting for the neighbour-room match [F5]
    case recording
    case finishing      // saving world map + finalizing manifest
}

/// Live-check thresholds [F3]. UNTUNED starting values: the raw metrics are
/// stored per frame in the manifest so these can be tuned from real walkthroughs.
enum LiveCheck {
    static let minDistanceM: Float = 0.4
    static let maxDistanceM: Float = 5.0
    static let blurScoreBelow: Float = 25       // Laplacian variance on luma
    static let blurMinLinearSpeed: Float = 0.25 // m/s: only call it blur when moving
    static let blurMinAngularSpeed: Float = 0.6 // rad/s
    static let lowConfFractionAbove: Float = 0.5
}

/// Voice trigger [F1]: a still is taken when someone STARTS speaking (any words).
/// Level-based voice activity detection; UNTUNED thresholds.
enum VoiceTrigger {
    static let speechLevelDb: Float = -38      // input RMS above this counts as speech
    static let onsetBuffers = 3                // consecutive loud buffers (~60-70ms) to call it speech
    static let silenceToEndSeconds: Double = 1.0 // quiet this long ends the utterance
}

/// Vertical sweep coverage: auto-stills are binned by horizontal position ALONG
/// the aisle AND by camera pitch, not distance walked alone. A 40cm walking
/// trigger alone misses shelf rows when the operator pans up/down from one
/// spot to cover a tall bookcase without translating. UNTUNED starting values.
enum CoverageSweep {
    static let horizontalBinWidthM: Float = 0.4
    static let verticalBinCount = 7          // one bin per shelf row, roughly
    static let verticalPitchRangeDeg: Float = 70 // total up/down sweep binned
}

/// Fires its handler at most once (used to race a completion against a timeout).
private final class OneShot<T> {
    private let lock = NSLock()
    private var fired = false
    private let handler: (T) -> Void
    init(_ handler: @escaping (T) -> Void) { self.handler = handler }
    func fire(_ value: T) {
        lock.lock(); let first = !fired; fired = true; lock.unlock()
        if first { handler(value) }
    }
}

final class CaptureSession: NSObject, ObservableObject {

    // MARK: Published state (mutated on main only)

    @Published private(set) var isDeviceSupported = true
    @Published private(set) var status: CaptureStatus = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var stillCount = 0
    @Published private(set) var noteCount = 0
    @Published private(set) var trackingStateDescription = "—"
    @Published private(set) var liveWarnings: [String] = []
    @Published private(set) var relocalizeTargetName: String?
    /// Last frame of the session being relocalized against, shown as a low-opacity
    /// overlay so the operator can line up the live view before recording begins.
    @Published private(set) var relocalizeGhostImage: UIImage?
    /// Current horizontal bin's shelf-row coverage (index 0 = lowest pitch), for
    /// showing the operator what's still uncovered while sweeping a bookcase.
    @Published private(set) var verticalCoverage: [Bool] = Array(repeating: false, count: CoverageSweep.verticalBinCount)
        @Published private(set) var lastFinalizedSessionURL: URL?
    @Published var errorMessage: String?

    var isRecording: Bool { status == .recording }

    let arSession = ARSession()

    // MARK: Queues

    private let frameQueue = DispatchQueue(label: "roomcapture.frames", qos: .userInitiated)
    private let stillQueue = DispatchQueue(label: "roomcapture.stills", qos: .utility)
    private let stillGroup = DispatchGroup()

    // MARK: Main-confined state

    private struct PendingStart {
        let country: String
        let neighbourName: String?
    }
    private var pendingStart: PendingStart?
    private var recordingStartDate: Date?
    private var uiTimer: Timer?
    private var sessionDirectory: URL?

    // MARK: frameQueue-confined state

    private enum Phase { case idle, relocalizing, starting, recording, finishing }
    private var phase: Phase = .idle
    private var seenRelocalizing = false
    private var normalSince: TimeInterval?
    private var lastPublishedTracking = ""

    private var frameWriter: FrameWriter?
    private var manifestBuilder: ManifestBuilder?
    private var lastSampledTimestamp: TimeInterval?
    private var nextFrameIndex = 0
    private var dimensionsRecorded = false

    private var nextStillIndex = 0
    private var stillInFlight = false
    private var cumulativePathLength: Float = 0
    private var lastPathPosition: SIMD3<Float>?
    private var coveredVerticalBinsPerHorizontalBin: [Int: Set<Int>] = [:]
    private var lastFrameJPEGData: Data?

    private var nextNoteIndex = 0

    private struct LatestSample {
        let timestamp: TimeInterval
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
        let imageWidth: Int
        let imageHeight: Int
        let centerDepth: Float?
    }
    private var latestSample: LatestSample?
    private var previousPoseForSpeed: (timestamp: TimeInterval, transform: simd_float4x4)?

    private let ciContext = CIContext()

    // MARK: Audio (tap thread + main)

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var audioConverter: AVAudioConverter?
    private let audioTargetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var firstAudioBufferSeen = false

    // MARK: Voice activity (audio tap thread only)

    private var vadSpeaking = false
    private var vadLoudBuffers = 0
    private var vadLastLoudTime: Double = 0

    // MARK: Init

    override init() {
        super.init()
        arSession.delegate = self
        arSession.delegateQueue = frameQueue
        isDeviceSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// ARSCNView can reset the session delegate when a session is assigned to it.
    func reassertDelegate() {
        arSession.delegate = self
        arSession.delegateQueue = frameQueue
    }

    // MARK: Permissions

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoGranted in
            AVAudioApplication.requestRecordPermission { audioGranted in
                DispatchQueue.main.async { completion(videoGranted && audioGranted) }
            }
        }
    }

    // MARK: Start / stop

    /// `relocalizeAgainst`: a session whose saved ARWorldMap this session must match
    /// before recording begins [F5]. `nil` = first room, records immediately.
    func startRecording(country: String, relocalizeAgainst neighbour: RecordedSession?) {
        guard isDeviceSupported else {
            errorMessage = "This device has no LiDAR scanner. Room Capture requires an iPhone Pro/Pro Max."
            return
        }
        guard status == .idle else { return }

        var initialMap: ARWorldMap?
        relocalizeGhostImage = nil
        if let neighbour {
            guard let data = try? Data(contentsOf: SessionManager.worldMapURL(for: neighbour.url)),
                  let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                errorMessage = "Could not load the saved map from \(neighbour.folderName)."
                return
            }
            initialMap = map
            relocalizeGhostImage = Self.loadGhostImage(for: neighbour)
        }

        pendingStart = PendingStart(country: country, neighbourName: neighbour?.folderName)

        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        config.planeDetection = []
        config.environmentTexturing = .none
        // Required for captureHighResolutionFrame [F1].
        if let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = hiRes
        }
        config.initialWorldMap = initialMap

        frameQueue.sync {
            phase = initialMap == nil ? .starting : .relocalizing
            seenRelocalizing = false
            normalSince = nil
            lastPublishedTracking = ""
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        observeInterruptions()

        if initialMap == nil {
            beginRecording(relocalizedAt: nil)
        } else {
            relocalizeTargetName = neighbour?.folderName
            status = .relocalizing
        }
    }

    /// Stop while recording, or cancel while waiting to relocalize.
    func stopRecording() {
        switch status {
        case .recording: finishRecording()
        case .relocalizing: cancelRelocalization()
        case .idle, .finishing: break
        }
    }

    private func cancelRelocalization() {
        arSession.pause()
        frameQueue.sync { phase = .idle }
        removeInterruptionObservers()
        UIApplication.shared.isIdleTimerDisabled = false
        pendingStart = nil
        relocalizeTargetName = nil
        relocalizeGhostImage = nil
        status = .idle
    }

    private func abortStart(_ message: String) {
        arSession.pause()
        frameQueue.sync { phase = .idle }
        removeInterruptionObservers()
        UIApplication.shared.isIdleTimerDisabled = false
        pendingStart = nil
        relocalizeTargetName = nil
        relocalizeGhostImage = nil
        status = .idle
        errorMessage = message
    }

    /// Saved frames are sensor-native (landscape); `.right` is upright for this
    /// app's portrait-locked UI, matching the convention used for face blurring.
    private static func loadGhostImage(for neighbour: RecordedSession) -> UIImage? {
        guard let data = try? Data(contentsOf: SessionManager.lastFrameURL(for: neighbour.url)),
              let cgImage = UIImage(data: data)?.cgImage else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }

    private func beginRecording(relocalizedAt: Double?) {
        guard let pending = pendingStart, status == .idle || status == .relocalizing else { return }

        let sessionId = "session_\(Self.isoFolderTimestamp(Date()))"
        guard let dir = try? SessionManager.makeSessionDirectory(sessionId: sessionId) else {
            abortStart("Could not create a folder for the new session.")
            return
        }

        let manifest = SessionManifest(
            session_id: sessionId,
            device_model: Self.deviceModelIdentifier(),
            ios_version: UIDevice.current.systemVersion,
            started_at_unix: Date().timeIntervalSince1970,
            country: pending.country,
            relocalized_against: pending.neighbourName,
            relocalized_at_ar_timestamp: relocalizedAt,
            faces_blurred: true,
            audio: AudioInfo(file: "audio.wav", sample_rate: 16000, channels: 1, start_ar_timestamp: CACurrentMediaTime()),
            depth_width: 0, depth_height: 0, rgb_width: 0, rgb_height: 0,
            frames: [], stills: [], notes: [],
            world_map: nil, dropped_frames: 0, complete: false, ended_at_unix: nil
        )
        let builder = ManifestBuilder(sessionDirectory: dir, manifest: manifest)

        do {
            try startAudio(sessionDirectory: dir, builder: builder)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            abortStart("Could not start audio recording: \(error.localizedDescription)")
            return
        }
        builder.writeInitial()
        let writer = FrameWriter(sessionDirectory: dir)

        frameQueue.sync {
            frameWriter = writer
            manifestBuilder = builder
            lastSampledTimestamp = nil
            nextFrameIndex = 0
            dimensionsRecorded = false
            nextStillIndex = 0
            stillInFlight = false
            cumulativePathLength = 0
            lastPathPosition = nil
            coveredVerticalBinsPerHorizontalBin = [:]
            lastFrameJPEGData = nil
            nextNoteIndex = 0
            latestSample = nil
            previousPoseForSpeed = nil
            phase = .recording
        }

        sessionDirectory = dir
        frameCount = 0
        droppedFrameCount = 0
        stillCount = 0
        noteCount = 0
        elapsedSeconds = 0
        liveWarnings = []
        verticalCoverage = Array(repeating: false, count: CoverageSweep.verticalBinCount)
        relocalizeTargetName = nil
        relocalizeGhostImage = nil
        recordingStartDate = Date()
        status = .recording
        startUITimer()
    }

    private func finishRecording() {
        guard status == .recording else { return }
        status = .finishing
        liveWarnings = []

        let (writer, builder, ghostJPEG) = frameQueue.sync { () -> (FrameWriter?, ManifestBuilder?, Data?) in
            phase = .finishing
            return (frameWriter, manifestBuilder, lastFrameJPEGData)
        }
        stopAudio()
        stopUITimer()
        removeInterruptionObservers()

        let dir = sessionDirectory
        // [ghost] Persist the last frame so the next session (if it relocalizes
        // against this one) can show it as an alignment overlay.
        if let dir, let ghostJPEG {
            DispatchQueue.global(qos: .utility).async {
                try? ghostJPEG.write(to: SessionManager.lastFrameURL(for: dir), options: .atomic)
            }
        }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "finalize-session")

        waitForPendingStills { [weak self] in
            guard let self else { return }
            self.saveWorldMap(to: dir) { mapInfo in
                let dropped = writer?.droppedFrameCount ?? 0
                let finalize = {
                    let url = builder?.finalize(droppedFrames: dropped, worldMap: mapInfo)
                    DispatchQueue.main.async { self.completeFinish(manifestURL: url, backgroundTask: backgroundTask) }
                }
                if let writer { writer.flush(finalize) } else { finalize() }
            }
        }
    }

    private func completeFinish(manifestURL: URL?, backgroundTask: UIBackgroundTaskIdentifier) {
        arSession.pause()
        frameQueue.sync {
            frameWriter = nil
            manifestBuilder = nil
            phase = .idle
        }
        sessionDirectory = nil
        pendingStart = nil
        recordingStartDate = nil
        UIApplication.shared.isIdleTimerDisabled = false
        lastFinalizedSessionURL = manifestURL
        status = .idle
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
    }

    /// Waits (max 3s) for an in-flight hi-res still to be written so it lands in the manifest.
    private func waitForPendingStills(then next: @escaping () -> Void) {
        let once = OneShot<Void> { DispatchQueue.main.async(execute: next) }
        stillGroup.notify(queue: .main) { once.fire(()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.fire(()) }
    }

    /// Saves the ARWorldMap [F5] so the next room can relocalize against it. Never blocks
    /// finalization for more than 10s; a failure just means no map for this session.
    private func saveWorldMap(to directory: URL?, completion: @escaping (WorldMapInfo?) -> Void) {
        guard let directory else { completion(nil); return }
        let once = OneShot<WorldMapInfo?> { info in DispatchQueue.main.async { completion(info) } }
        let mappingStatus = Self.describe(arSession.currentFrame?.worldMappingStatus)

        arSession.getCurrentWorldMap { map, _ in
            guard let map else { once.fire(nil); return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    try data.write(to: SessionManager.worldMapURL(for: directory), options: .atomic)
                    once.fire(WorldMapInfo(file: SessionManager.worldMapFileName, status: mappingStatus))
                } catch {
                    once.fire(nil)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { once.fire(nil) }
    }

    // MARK: UI timer

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartDate else { return }
            self.elapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    // MARK: Interruptions

    private func observeInterruptions() {
        removeInterruptionObservers()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppBackgrounding), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    private func removeInterruptionObservers() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
        DispatchQueue.main.async { self.stopRecording() }
    }

    @objc private func handleAppBackgrounding() {
        DispatchQueue.main.async { self.stopRecording() }
    }

    // MARK: Photo / notes (called from the UI)

    /// [F1] Photo button.
    func takePhoto() {
        frameQueue.async { [self] in _ = requestStill(trigger: "button") }
    }

    /// [F2] Typed note, tied to the object the camera is aimed at.
    func addNote(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        frameQueue.async { [self] in
            guard phase == .recording, let builder = manifestBuilder, let sample = latestSample else { return }

            var target: [Float]?
            if let d = sample.centerDepth {
                let fx = sample.intrinsics.columns.0.x, fy = sample.intrinsics.columns.1.y
                let cx = sample.intrinsics.columns.2.x, cy = sample.intrinsics.columns.2.y
                let u = Float(sample.imageWidth) / 2, v = Float(sample.imageHeight) / 2
                let camPoint = SIMD4<Float>((u - cx) / fx * d, -(v - cy) / fy * d, -d, 1)
                let world = sample.transform * camPoint
                target = [world.x, world.y, world.z]
            }

            let index = nextNoteIndex
            nextNoteIndex += 1
            builder.addNote(ManifestNote(
                index: index,
                text: text,
                ar_timestamp: sample.timestamp,
                frame_index: nextFrameIndex > 0 ? nextFrameIndex - 1 : nil,
                transform: Self.rowMajor4x4(sample.transform),
                target_point_world: target,
                target_distance_m: sample.centerDepth
            ))
            DispatchQueue.main.async { self.noteCount = index + 1 }
        }
    }

    // MARK: Hi-res stills [F1]  (frameQueue only)

    /// Returns true if a capture was started.
    @discardableResult
    private func requestStill(trigger: String) -> Bool {
        guard phase == .recording, !stillInFlight, let writer = frameWriter, let builder = manifestBuilder else { return false }
        stillInFlight = true
        stillGroup.enter()
        let index = nextStillIndex
        nextStillIndex += 1

        arSession.captureHighResolutionFrame { [weak self] frame, _ in
            guard let self else { return }
            self.stillQueue.async {
                autoreleasepool {
                    if let frame, let jpeg = Self.jpegData(from: frame.capturedImage, context: self.ciContext, blurFaces: true) {
                        writer.submitStill(index: index, jpeg: jpeg)
                        builder.addStill(ManifestStill(
                            index: index,
                            ar_timestamp: frame.timestamp,
                            file: String(format: "stills/%06d_still.jpg", index),
                            width: CVPixelBufferGetWidth(frame.capturedImage),
                            height: CVPixelBufferGetHeight(frame.capturedImage),
                            transform: Self.rowMajor4x4(frame.camera.transform),
                            intrinsics: Self.rowMajor3x3(frame.camera.intrinsics),
                            tracking_state: Self.describe(frame.camera.trackingState),
                            trigger: trigger
                        ))
                        DispatchQueue.main.async { self.stillCount += 1 }
                    }
                }
                self.frameQueue.async { self.stillInFlight = false }
                self.stillGroup.leave()
            }
        }
        return true
    }

    // MARK: Audio

    private func startAudio(sessionDirectory: URL, builder: ManifestBuilder) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audioSession.setActive(true)

        audioFile = try AVAudioFile(forWriting: sessionDirectory.appendingPathComponent("audio.wav"), settings: audioTargetFormat.settings)

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: audioTargetFormat)
        firstAudioBufferSeen = false
        vadSpeaking = false
        vadLoudBuffers = 0

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            if !self.firstAudioBufferSeen {
                self.firstAudioBufferSeen = true
                // Host time is the same uptime clock as ARFrame.timestamp / CACurrentMediaTime().
                if time.isHostTimeValid {
                    builder.setAudioStart(AVAudioTime.seconds(forHostTime: time.hostTime))
                }
            }
            self.detectSpeech(buffer, at: time)
            self.handleAudioBuffer(buffer, inputFormat: inputFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Runs on the audio tap thread.
    private func detectSpeech(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sumSquares: Float = 0
        for i in 0..<Int(buffer.frameLength) { sumSquares += channel[i] * channel[i] }
        let rms = (sumSquares / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let now = CACurrentMediaTime()

        if db > VoiceTrigger.speechLevelDb {
            vadLastLoudTime = now
            vadLoudBuffers += 1
            if !vadSpeaking && vadLoudBuffers >= VoiceTrigger.onsetBuffers {
                vadSpeaking = true
                frameQueue.async { [self] in _ = requestStill(trigger: "voice") }
            }
        } else {
            vadLoudBuffers = 0
            if vadSpeaking && now - vadLastLoudTime > VoiceTrigger.silenceToEndSeconds {
                vadSpeaking = false
            }
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter = audioConverter, let audioFile else { return }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (audioTargetFormat.sampleRate / inputFormat.sampleRate)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: audioTargetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil else { return }
        try? audioFile.write(from: output)
    }

    private func stopAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioFile = nil
        audioConverter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Metadata helpers

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce("") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(value)))
        }
    }

    private static func isoFolderTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }

    fileprivate static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        }
    }

    private static func describe(_ status: ARFrame.WorldMappingStatus?) -> String {
        switch status {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        case .none: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - ARSessionDelegate (runs on frameQueue)

extension CaptureSession: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let stateDescription = Self.describe(frame.camera.trackingState)
        if stateDescription != lastPublishedTracking {
            lastPublishedTracking = stateDescription
            DispatchQueue.main.async { self.trackingStateDescription = stateDescription }
        }

        switch phase {
        case .idle, .starting, .finishing:
            return
        case .relocalizing:
            handleRelocalizing(frame)
            return
        case .recording:
            break
        }

        guard let writer = frameWriter, let builder = manifestBuilder else { return }

        // [coverage] auto still: bin by horizontal position along the aisle AND
        // by camera pitch, so sweeping up/down to reach the top/bottom shelves
        // triggers a capture even without walking further (distance-only used to
        // miss rows on a tall bookcase). See updateCoverage below.
        let position = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        if case .normal = frame.camera.trackingState {
            updateCoverage(position: position, transform: frame.camera.transform)
        }

        // ~10 fps sampling
        let timestamp = frame.timestamp
        if let last = lastSampledTimestamp, timestamp - last < 0.1 * 0.999 { return }
        lastSampledTimestamp = timestamp

        guard let depthData = frame.sceneDepth else { return }
        let depthMap = depthData.depthMap

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let rgbWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let rgbHeight = CVPixelBufferGetHeight(frame.capturedImage)

        // Quality metrics run on the unblurred image.
        let sharpness = Self.sharpnessScore(frame.capturedImage)

        guard let rgbData = Self.jpegData(from: frame.capturedImage, context: ciContext, blurFaces: true) else { return }
        lastFrameJPEGData = rgbData

        if !dimensionsRecorded {
            dimensionsRecorded = true
            builder.setDimensions(depthWidth: depthWidth, depthHeight: depthHeight, rgbWidth: rgbWidth, rgbHeight: rgbHeight)
        }

        let depthRaw = Self.tightlyPackedData(from: depthMap, bytesPerElement: 4)
        let confidenceRaw = depthData.confidenceMap.map { Self.tightlyPackedData(from: $0, bytesPerElement: 1) } ?? Data()
        let stats = Self.depthStats(depth: depthRaw, confidence: confidenceRaw, width: depthWidth, height: depthHeight)

        // Camera speed between consecutive samples
        var linearSpeed: Float?
        var angularSpeed: Float?
        if let prev = previousPoseForSpeed, timestamp > prev.timestamp {
            let dt = Float(timestamp - prev.timestamp)
            let prevPos = SIMD3<Float>(prev.transform.columns.3.x, prev.transform.columns.3.y, prev.transform.columns.3.z)
            linearSpeed = simd_distance(position, prevPos) / dt
            var angle = (simd_quatf(prev.transform).inverse * simd_quatf(frame.camera.transform)).angle
            if angle > .pi { angle = 2 * .pi - angle }
            angularSpeed = angle / dt
        }
        previousPoseForSpeed = (timestamp, frame.camera.transform)

        latestSample = LatestSample(
            timestamp: timestamp,
            transform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageWidth: rgbWidth,
            imageHeight: rgbHeight,
            centerDepth: stats.centerDepth
        )

        publishWarnings(sharpness: sharpness, stats: stats, linearSpeed: linearSpeed, angularSpeed: angularSpeed, tracking: frame.camera.trackingState)

        let index = nextFrameIndex
        let transform = Self.rowMajor4x4(frame.camera.transform)
        let intrinsics = Self.rowMajor3x3(frame.camera.intrinsics)
        let payload = CapturedFramePayload(
            index: index,
            arTimestamp: timestamp,
            rgbData: rgbData,
            depthData: depthRaw,
            confidenceData: confidenceRaw,
            transform: transform,
            intrinsics: intrinsics,
            trackingState: stateDescription
        )

        if writer.submit(payload) {
            nextFrameIndex += 1
            let name = String(format: "%06d", index)
            builder.addFrame(ManifestFrame(
                index: index,
                ar_timestamp: timestamp,
                rgb: "frames/\(name)_rgb.jpg",
                depth: "frames/\(name)_depth.bin",
                confidence: "frames/\(name)_conf.bin",
                transform: transform,
                intrinsics: intrinsics,
                tracking_state: stateDescription,
                quality: ManifestFrameQuality(
                    blur_score: sharpness,
                    center_depth_m: stats.centerDepth,
                    low_conf_fraction: stats.lowConfFraction,
                    speed_mps: linearSpeed,
                    angular_speed_rps: angularSpeed
                )
            ))
            DispatchQueue.main.async { self.frameCount = index + 1 }
        } else {
            let dropped = writer.droppedFrameCount
            builder.updateDroppedCount(dropped)
            DispatchQueue.main.async { self.droppedFrameCount = dropped }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.errorMessage = "AR session failed: \(error.localizedDescription)"
            self.stopRecording()
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.stopRecording() }
    }

    // MARK: Relocalization gate [F5]

    /// Recording starts only after ARKit reports relocalizing and then holds normal tracking for 0.5s.
    private func handleRelocalizing(_ frame: ARFrame) {
        switch frame.camera.trackingState {
        case .limited(let reason) where reason == .relocalizing:
            seenRelocalizing = true
            normalSince = nil
        case .normal:
            guard seenRelocalizing else { return }
            if let since = normalSince {
                if frame.timestamp - since >= 0.5 {
                    phase = .starting
                    let matchedAt = frame.timestamp
                    DispatchQueue.main.async { self.beginRecording(relocalizedAt: matchedAt) }
                }
            } else {
                normalSince = frame.timestamp
            }
        default:
            normalSince = nil
        }
    }

    // MARK: Vertical sweep coverage

    /// Marks the (horizontal-bin, pitch-bin) cell for the current pose as covered,
    /// requesting an auto still whenever a new cell is entered — whether that's
    /// from walking forward or just tilting the camera up/down in place. Publishes
    /// the current horizontal bin's row coverage so the UI can show what's missing.
    private func updateCoverage(position: SIMD3<Float>, transform: simd_float4x4) {
        if let last = lastPathPosition {
            cumulativePathLength += simd_distance(position, last)
        }
        lastPathPosition = position

        let horizontalBin = Int(cumulativePathLength / CoverageSweep.horizontalBinWidthM)
        let verticalBin = Self.verticalBinIndex(forPitchDegrees: Self.pitchDegrees(transform))

        var covered = coveredVerticalBinsPerHorizontalBin[horizontalBin] ?? []
        if !covered.contains(verticalBin), requestStill(trigger: "auto") {
            covered.insert(verticalBin)
            coveredVerticalBinsPerHorizontalBin[horizontalBin] = covered
        }

        let coverageArray = (0..<CoverageSweep.verticalBinCount).map { covered.contains($0) }
        DispatchQueue.main.async { self.verticalCoverage = coverageArray }
    }

    /// Camera pitch in degrees: positive = tilted up, negative = tilted down.
    private static func pitchDegrees(_ transform: simd_float4x4) -> Float {
        let forward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
        let flatLength = (forward.x * forward.x + forward.z * forward.z).squareRoot()
        return atan2(forward.y, flatLength) * 180 / .pi
    }

    private static func verticalBinIndex(forPitchDegrees pitch: Float) -> Int {
        let half = CoverageSweep.verticalPitchRangeDeg / 2
        let clamped = min(max(pitch, -half), half)
        let fraction = (clamped + half) / CoverageSweep.verticalPitchRangeDeg
        return min(Int(fraction * Float(CoverageSweep.verticalBinCount)), CoverageSweep.verticalBinCount - 1)
    }

    // MARK: Live checks [F3]

    private func publishWarnings(sharpness: Float, stats: (centerDepth: Float?, lowConfFraction: Float), linearSpeed: Float?, angularSpeed: Float?, tracking: ARCamera.TrackingState) {
        var warnings: [String] = []
        let moving = (linearSpeed ?? 0) > LiveCheck.blurMinLinearSpeed || (angularSpeed ?? 0) > LiveCheck.blurMinAngularSpeed
        if sharpness < LiveCheck.blurScoreBelow && moving { warnings.append("Blurry - slow down") }
        if let d = stats.centerDepth {
            if d < LiveCheck.minDistanceM { warnings.append("Too close") }
            if d > LiveCheck.maxDistanceM { warnings.append("Too far") }
        }
        if stats.lowConfFraction > LiveCheck.lowConfFractionAbove { warnings.append("Missing depth - rescan this area") }
        if case .limited = tracking { warnings.append("Tracking limited") }
        DispatchQueue.main.async { if self.liveWarnings != warnings { self.liveWarnings = warnings } }
    }

    // MARK: Conversion helpers

    /// JPEG (quality 0.9). Faces are blurred on-device before anything is saved [F17].
    private static func jpegData(from pixelBuffer: CVPixelBuffer, context: CIContext, blurFaces: Bool) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if blurFaces { image = blurringFaces(in: image) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.9])
    }

    /// Detects faces in the upright image (the sensor image is landscape; portrait use = .right),
    /// blurs them, and returns the image back in sensor orientation.
    private static func blurringFaces(in image: CIImage) -> CIImage {
        let upright = image.oriented(.right)
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: upright, options: [:])
        guard (try? handler.perform([request])) != nil, let faces = request.results, !faces.isEmpty else { return image }

        let extent = upright.extent
        var mask = CIImage(color: .black).cropped(to: extent)
        for face in faces {
            var rect = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            rect = rect.offsetBy(dx: extent.origin.x, dy: extent.origin.y)
            rect = rect.insetBy(dx: -rect.width * 0.3, dy: -rect.height * 0.3).intersection(extent)
            if rect.isNull || rect.isEmpty { continue }
            mask = CIImage(color: .white).cropped(to: rect).composited(over: mask)
        }

        let blurred = upright.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(extent.width, extent.height)) / 40)
            .cropped(to: extent)
        let blended = blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: upright,
            kCIInputMaskImageKey: mask
        ])
        return blended.oriented(.left)
    }

    /// Laplacian variance on the luma plane, sampled on a coarse grid (cheap).
    private static func sharpnessScore(_ pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let step = 4, d = 2

        var sum = 0.0, sumSquares = 0.0, count = 0.0
        for y in stride(from: d, to: height - d, by: step) {
            for x in stride(from: d, to: width - d, by: step) {
                let c = Int(luma[y * bytesPerRow + x])
                let l = Int(luma[y * bytesPerRow + x - d])
                let r = Int(luma[y * bytesPerRow + x + d])
                let u = Int(luma[(y - d) * bytesPerRow + x])
                let b = Int(luma[(y + d) * bytesPerRow + x])
                let lap = Double(4 * c - l - r - u - b)
                sum += lap
                sumSquares += lap * lap
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return Float(sumSquares / count - mean * mean)
    }

    /// Centre-of-view depth (medium+ confidence) and fraction of low-confidence depth pixels.
    private static func depthStats(depth: Data, confidence: Data, width: Int, height: Int) -> (centerDepth: Float?, lowConfFraction: Float) {
        let total = width * height
        guard total > 0, depth.count >= total * 4 else { return (nil, 1) }
        let hasConfidence = confidence.count == total

        return depth.withUnsafeBytes { dp in
            confidence.withUnsafeBytes { cp in
                var low = 0
                if hasConfidence {
                    for i in 0..<total where cp[i] == 0 { low += 1 }
                }

                var sum: Float = 0
                var n: Float = 0
                for y in max(0, height / 2 - 6)..<min(height, height / 2 + 6) {
                    for x in max(0, width / 2 - 8)..<min(width, width / 2 + 8) {
                        let i = y * width + x
                        let d = dp.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
                        let c: UInt8 = hasConfidence ? cp[i] : 2
                        if d.isFinite, d > 0, c >= 1 { sum += d; n += 1 }
                    }
                }
                return (n > 0 ? sum / n : nil, Float(low) / Float(total))
            }
        }
    }

    /// Copies a CVPixelBuffer plane into tightly packed, row-major Data (strips row padding).
    private static func tightlyPackedData(from pixelBuffer: CVPixelBuffer, bytesPerElement: Int) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * bytesPerElement
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return Data() }

        var data = Data(capacity: rowBytes * height)
        for row in 0..<height {
            data.append(Data(bytes: base.advanced(by: row * bytesPerRow), count: rowBytes))
        }
        return data
    }

    fileprivate static func rowMajor4x4(_ m: simd_float4x4) -> [[Float]] {
        (0..<4).map { row in [m.columns.0[row], m.columns.1[row], m.columns.2[row], m.columns.3[row]] }
    }

    fileprivate static func rowMajor3x3(_ m: simd_float3x3) -> [[Float]] {
        (0..<3).map { row in [m.columns.0[row], m.columns.1[row], m.columns.2[row]] }
    }
}

// MARK: - Camera preview

struct CameraPreviewView: UIViewRepresentable {
    let captureSession: CaptureSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = captureSession.arSession
        view.automaticallyUpdatesLighting = false
        view.scene = SCNScene()
        captureSession.reassertDelegate()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
