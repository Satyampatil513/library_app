import Foundation
import Combine

struct RecordedSession: Identifiable, Equatable {
    var id: String { folderName }
    let folderName: String
    let url: URL
    let sizeBytes: Int64
    let createdAt: Date
    /// True if this session saved an ARWorldMap that another room can relocalize against.
    let hasWorldMap: Bool
}

/// Lists, sizes, and deletes recorded session folders. Foundation-only so it
/// is testable without ARKit/AVFoundation.
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [RecordedSession] = []

    static var sessionsRootDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static let lowDiskSpaceThresholdBytes: Int64 = 2_000_000_000 // ~2 GB

    static let worldMapFileName = "worldmap.arworldmap"

    static func worldMapURL(for sessionURL: URL) -> URL {
        sessionURL.appendingPathComponent(worldMapFileName)
    }

    /// [ghost] The last frame captured in a session, saved so the next session
    /// can show it as a low-opacity alignment overlay when relocalizing against it.
    static let lastFrameFileName = "last_frame.jpg"

    static func lastFrameURL(for sessionURL: URL) -> URL {
        sessionURL.appendingPathComponent(lastFrameFileName)
    }

    static func makeSessionDirectory(sessionId: String) throws -> URL {
        let dir = sessionsRootDirectory.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("frames", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("stills", isDirectory: true), withIntermediateDirectories: true)
        return dir
    }

    static func freeDiskSpaceBytes() -> Int64? {
        let values = try? sessionsRootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return nil
    }

    func refresh() {
        let fm = FileManager.default
        let root = Self.sessionsRootDirectory
        let contents = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []

        let found: [RecordedSession] = contents.compactMap { url in
            guard url.lastPathComponent.hasPrefix("session_") else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let size = Self.folderSizeBytes(at: url)
            let hasMap = fm.fileExists(atPath: Self.worldMapURL(for: url).path)
            return RecordedSession(folderName: url.lastPathComponent, url: url, sizeBytes: size, createdAt: created, hasWorldMap: hasMap)
        }

        sessions = found.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ session: RecordedSession) {
        try? FileManager.default.removeItem(at: session.url)
        refresh()
    }

    private static func folderSizeBytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
