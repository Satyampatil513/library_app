import Foundation

enum UploadError: Error {
    case zipFailed
    case serverError(Int)
}

/// Zips a session folder and PUTs it to a hardcoded server endpoint.
/// Foundation-only (NSFileCoordinator + URLSession); no ARKit/AVFoundation.
enum Uploader {
    /// Editable in-app under Settings (gear icon), stored in UserDefaults via the same keys @AppStorage uses
    /// there - so a URL/token typed into the settings sheet takes effect immediately, no rebuild needed. This
    /// is the fallback the settings field starts pre-filled with; it's a Cloudflare quick tunnel URL, which
    /// changes every time that tunnel process restarts, so it will usually need to be replaced via Settings
    /// rather than relied on as-is.
    static let defaultURLString = "https://noted-minneapolis-emma-displaying.trycloudflare.com/upload"

    static var uploadURLString: String {
        let stored = UserDefaults.standard.string(forKey: "uploadServerURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false ? stored : nil) ?? defaultURLString
    }

    /// Must match the server's UPLOAD_TOKEN in .env, or be left empty if UPLOAD_TOKEN is unset there.
    static var uploadToken: String {
        UserDefaults.standard.string(forKey: "uploadToken") ?? ""
    }

    static func upload(
        session: RecordedSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> Progress {
        let overallProgress = Progress(totalUnitCount: 100)

        DispatchQueue.global(qos: .utility).async {
            var coordinatorError: NSError?
            var copyError: Error?
            var preparedZipURL: URL?

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: session.url, options: [.forUploading], error: &coordinatorError) { zipURL in
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(zipURL.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try FileManager.default.removeItem(at: tempURL)
                    }
                    try FileManager.default.copyItem(at: zipURL, to: tempURL)
                    preparedZipURL = tempURL
                } catch {
                    copyError = error
                }
            }

            if let coordinatorError {
                DispatchQueue.main.async { completion(.failure(coordinatorError)) }
                return
            }
            if let copyError {
                DispatchQueue.main.async { completion(.failure(copyError)) }
                return
            }
            guard let zipFile = preparedZipURL, let endpoint = URL(string: uploadURLString) else {
                DispatchQueue.main.async { completion(.failure(UploadError.zipFailed)) }
                return
            }

            overallProgress.completedUnitCount = 20

            var request = URLRequest(url: endpoint)
            request.httpMethod = "PUT"
            request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
            request.setValue(session.folderName, forHTTPHeaderField: "X-Session-Name")
            if !uploadToken.isEmpty {
                request.setValue("Bearer \(uploadToken)", forHTTPHeaderField: "Authorization")
            }

            let task = URLSession.shared.uploadTask(with: request, fromFile: zipFile) { _, response, error in
                try? FileManager.default.removeItem(at: zipFile)

                if let error {
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    DispatchQueue.main.async { completion(.failure(UploadError.serverError(http.statusCode))) }
                    return
                }
                overallProgress.completedUnitCount = 100
                DispatchQueue.main.async { completion(.success(())) }
            }
            overallProgress.addChild(task.progress, withPendingUnitCount: 80)
            task.resume()
        }

        return overallProgress
    }
}
