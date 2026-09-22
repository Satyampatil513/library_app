import SwiftUI
import UIKit

enum SessionUploadState {
    case idle
    case uploading
    case done
    case failed(String)
}

struct CountryOption: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [CountryOption] = Locale.Region.isoRegions
        .filter { $0.identifier.count == 2 }
        .map { CountryOption(code: $0.identifier, name: Locale.current.localizedString(forRegionCode: $0.identifier) ?? $0.identifier) }
        .sorted { $0.name < $1.name }
}

struct ContentView: View {
    @StateObject private var captureSession = CaptureSession()
    @StateObject private var sessionManager = SessionManager()

    /// [F8] chosen once per session; persisted only as a convenience default.
    @AppStorage("captureCountry") private var country: String = Locale.current.region?.identifier ?? "US"
    /// [F5] session to relocalize against ("" = none, first room).
    @State private var relocalizeSessionID: String = ""
    @State private var noteText = ""

    @State private var shareItem: IdentifiableURL?
    @State private var actionSheetSession: RecordedSession?
    @State private var showPermissionDenied = false
    @State private var showLowDiskWarning = false
    @State private var showSettings = false
    @State private var uploadStates: [String: SessionUploadState] = [:]

    private var selectedNeighbour: RecordedSession? {
        sessionManager.sessions.first { $0.id == relocalizeSessionID && $0.hasWorldMap }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                    .frame(height: 300)
                    .clipped()

                statsRow

                controls
                    .padding(.horizontal)

                recordButton
                    .padding(.vertical, 8)

                Divider()

                sessionsList
            }
            .navigationTitle("Room Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { sessionManager.refresh() }
        .onChange(of: captureSession.status) { _, status in
            if status == .idle { sessionManager.refresh() }
        }
        .alert("Error", isPresented: Binding(
            get: { captureSession.errorMessage != nil },
            set: { if !$0 { captureSession.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(captureSession.errorMessage ?? "")
        }
        .alert("Camera & Microphone Access Needed", isPresented: $showPermissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable camera and microphone access in Settings to record a session.")
        }
        .alert("Low Disk Space", isPresented: $showLowDiskWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Record Anyway") { beginCapture() }
        } message: {
            Text("Your device is low on free storage. A room walkthrough can use several gigabytes.")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .confirmationDialog(
            actionSheetSession?.folderName ?? "",
            isPresented: Binding(
                get: { actionSheetSession != nil },
                set: { if !$0 { actionSheetSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let session = actionSheetSession {
                Button("Share") { shareItem = IdentifiableURL(url: session.url) }
                Button("Delete", role: .destructive) { sessionManager.delete(session) }
            }
        }
    }

    // MARK: Preview + overlays

    private var preview: some View {
        ZStack {
            if captureSession.isDeviceSupported {
                CameraPreviewView(captureSession: captureSession)
            } else {
                Color.black
                Text("No LiDAR sensor detected.\nThis app requires an iPhone Pro/Pro Max.")
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }

            if captureSession.status == .relocalizing, let ghost = captureSession.relocalizeGhostImage {
                Image(uiImage: ghost)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.35)
                    .allowsHitTesting(false)
                    .clipped()
            }

            VStack(spacing: 6) {
                if captureSession.status == .relocalizing {
                    banner("Line up the live view with the faint image from \(captureSession.relocalizeTargetName ?? "the previous session")'s last frame, holding on the same landmark. Recording starts automatically once matched.", color: .blue)
                }
                if captureSession.status == .finishing {
                    banner("Saving session...", color: .gray)
                }
                Spacer()
                if captureSession.status == .recording {
                    ForEach(captureSession.liveWarnings, id: \.self) { warning in
                        banner(warning, color: .orange)
                    }
                    coverageIndicator
                }
            }
            .padding(8)
        }
    }

    /// [coverage] Shows which shelf-row bins are still uncovered at the operator's
    /// current position along the aisle (green = captured, dim = missing).
    private var coverageIndicator: some View {
        HStack(spacing: 3) {
            Text("Rows").font(.caption2).foregroundColor(.white)
            ForEach(Array(captureSession.verticalCoverage.reversed().enumerated()), id: \.offset) { _, covered in
                RoundedRectangle(cornerRadius: 2)
                    .fill(covered ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 14, height: 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.5))
        .cornerRadius(6)
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.9))
            .cornerRadius(8)
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack(spacing: 20) {
            statLabel(title: "Time", value: formattedElapsed(captureSession.elapsedSeconds))
            statLabel(title: "Frames", value: "\(captureSession.frameCount)")
            statLabel(title: "Stills", value: "\(captureSession.stillCount)")
            statLabel(title: "Notes", value: "\(captureSession.noteCount)")
            if captureSession.droppedFrameCount > 0 {
                statLabel(title: "Dropped", value: "\(captureSession.droppedFrameCount)")
                    .foregroundColor(.orange)
            }
        }
        .padding(.top, 8)
    }

    private func statLabel(title: String, value: String) -> some View {
        VStack {
            Text(value).font(.title3).monospacedDigit().bold()
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: Controls (pre-record pickers / in-record photo + note)

    @ViewBuilder
    private var controls: some View {
        switch captureSession.status {
        case .idle:
            VStack(spacing: 4) {
                HStack {
                    Text("Country").font(.subheadline)
                    Spacer()
                    Picker("Country", selection: $country) {
                        ForEach(CountryOption.all) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("Relocalize against").font(.subheadline)
                    Spacer()
                    Picker("Relocalize against", selection: $relocalizeSessionID) {
                        Text("None (first room)").tag("")
                        ForEach(sessionManager.sessions.filter(\.hasWorldMap)) { Text($0.folderName).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                }
            }
        case .recording:
            VStack(spacing: 4) {
                Text("When you're done, stop at a distinct, identifiable object — not mid-aisle or anywhere generic.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Button {
                        captureSession.takePhoto()
                    } label: {
                        Image(systemName: "camera.fill").frame(width: 40, height: 34)
                    }
                    .buttonStyle(.borderedProminent)

                    TextField("Note about what you're looking at", text: $noteText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit(submitNote)

                    Button("Add", action: submitNote)
                        .buttonStyle(.bordered)
                        .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        case .relocalizing, .finishing:
            EmptyView()
        }
    }

    private func submitNote() {
        captureSession.addNote(noteText)
        noteText = ""
    }

    private var recordButton: some View {
        let active = captureSession.status == .recording || captureSession.status == .relocalizing
        return Button(action: handleRecordTap) {
            Circle()
                .fill(Color.red)
                .frame(width: 72, height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: active ? 6 : 36)
                        .fill(Color.white)
                        .frame(width: active ? 26 : 58, height: active ? 26 : 58)
                )
        }
        .disabled(!captureSession.isDeviceSupported || captureSession.status == .finishing)
        .opacity(captureSession.status == .finishing ? 0.4 : 1)
    }

    // MARK: Sessions list

    private var sessionsList: some View {
        List {
            Section("Recorded Sessions") {
                if sessionManager.sessions.isEmpty {
                    Text("No sessions yet").foregroundColor(.secondary)
                }
                ForEach(sessionManager.sessions) { session in
                    Button {
                        actionSheetSession = session
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) { sessionManager.delete(session) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func sessionRow(_ session: RecordedSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.folderName).font(.body)
                HStack(spacing: 6) {
                    Text(SessionManager.formattedSize(session.sizeBytes))
                    if session.hasWorldMap { Image(systemName: "map") }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            uploadButton(for: session)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func uploadButton(for session: RecordedSession) -> some View {
        switch uploadStates[session.id] ?? .idle {
        case .idle:
            Button { startUpload(session) } label: { Image(systemName: "icloud.and.arrow.up") }
                .buttonStyle(.borderless)
        case .uploading:
            ProgressView().scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark.icloud").foregroundColor(.green)
        case .failed:
            Button { startUpload(session) } label: { Image(systemName: "exclamationmark.icloud").foregroundColor(.red) }
                .buttonStyle(.borderless)
        }
    }

    private func startUpload(_ session: RecordedSession) {
        uploadStates[session.id] = .uploading
        _ = Uploader.upload(session: session) { result in
            switch result {
            case .success: uploadStates[session.id] = .done
            case .failure(let error): uploadStates[session.id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Actions

    private func handleRecordTap() {
        switch captureSession.status {
        case .recording, .relocalizing:
            captureSession.stopRecording()
        case .finishing:
            return
        case .idle:
            guard captureSession.isDeviceSupported else { return }
            captureSession.requestPermissions { granted in
                guard granted else { showPermissionDenied = true; return }
                if let free = SessionManager.freeDiskSpaceBytes(), free < SessionManager.lowDiskSpaceThresholdBytes {
                    showLowDiskWarning = true
                } else {
                    beginCapture()
                }
            }
        }
    }

    private func beginCapture() {
        noteText = ""
        captureSession.startRecording(country: country, relocalizeAgainst: selectedNeighbour)
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
