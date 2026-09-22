import SwiftUI

enum ConnectionCheck: Equatable {
    case idle
    case checking
    case ok
    case failed(String)
}

/// Lets the upload server URL/token be changed at runtime (UserDefaults, same keys Uploader.swift reads) so a
/// new tunnel URL can be pasted in without rebuilding the app in Xcode. Reachable via the gear icon.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("uploadServerURL") private var serverURL: String = Uploader.defaultURLString
    @AppStorage("uploadToken") private var token: String = ""
    @State private var check: ConnectionCheck = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section("Upload server") {
                    TextField("https://your-tunnel-or-host/upload", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Auth token (optional, matches server's UPLOAD_TOKEN)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("This is where each Upload button sends a recorded session. A Cloudflare/ngrok tunnel URL changes every time that tunnel is restarted on the server side - paste the new one here, no rebuild needed.")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            switch check {
                            case .idle: EmptyView()
                            case .checking: ProgressView()
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                            }
                        }
                    }
                    if case .failed(let message) = check {
                        Text(message).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// GETs the server's root (strips the trailing /upload) as a quick reachability check, independent of
    /// actually uploading anything - catches a stale/mistyped URL immediately instead of on the next real upload.
    private func testConnection() {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed) else {
            check = .failed("Not a valid URL")
            return
        }
        comps.path = ""
        guard let base = comps.url else {
            check = .failed("Not a valid URL")
            return
        }
        check = .checking
        var request = URLRequest(url: base)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    check = .failed(error.localizedDescription)
                } else if let http = response as? HTTPURLResponse {
                    // any response at all (even a 404 for "/") means the host is reachable and serving
                    check = http.statusCode < 500 ? .ok : .failed("Server error \(http.statusCode)")
                } else {
                    check = .failed("No response")
                }
            }
        }.resume()
    }
}
