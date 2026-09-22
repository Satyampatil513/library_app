# Room Capture

Single-purpose iOS app: records a LiDAR room walkthrough (RGB + depth + confidence +
camera pose + intrinsics + continuous audio) and saves it to disk as a session folder.
It does no processing or reconstruction — it only captures, writes, and lets you
share/upload/delete the resulting folder.

Requires a physical iPhone Pro/Pro Max (LiDAR). Will not work in the Simulator
(no scene depth) and needs a Mac with Xcode to build — this repo was authored on
Windows, so there's no `.xcodeproj` checked in; generate one with XcodeGen.

## Build

On a Mac:

```bash
brew install xcodegen
cd library_app
xcodegen generate
open RoomCapture.xcodeproj
```

In Xcode: select your Team under Signing & Capabilities, plug in a LiDAR-equipped
iPhone, and run.

## Installing a build without a Mac or paid Apple Developer account

`.github/workflows/ios-build.yml` builds the app **unsigned** on a macOS GitHub
runner on every push to `master`, and publishes the resulting `.ipa` to a rolling
[`latest` release](../../releases/tag/latest) — always the same link, overwritten
each build. No Apple Developer Program membership is needed for this path; the
signing happens on-device at install time instead:

1. Download `RoomCapture-unsigned.ipa` from the `latest` release (repo access
   required — send the file directly to whoever's installing it if they don't
   have access to this repo).
2. On the install machine: install [Sideloadly](https://sideloadly.io), plug in
   the iPhone via USB, drag the `.ipa` in, sign in with a free Apple ID, hit Start.
3. On the phone: Settings → General → VPN & Device Management → trust the
   developer profile, then launch the app and allow the Camera/Microphone prompts.

Apps signed this way with a free Apple ID expire after **7 days** — repeat step 2
with a fresh (or the same) `.ipa` to keep it working. A paid Developer Program
membership + TestFlight avoids that expiry if this needs to stay installed
long-term.

## Before you record

Open the app, tap the gear icon (Settings), and set:

- **Upload server URL** — e.g. your server's Cloudflare/ngrok tunnel URL plus `/upload`
  (`https://your-tunnel.trycloudflare.com/upload`). Tap **Test Connection** to confirm
  it's reachable before recording — this catches a stale or mistyped URL immediately
  instead of failing on the first real upload.
- **Auth token** (optional) — must match the server's `UPLOAD_TOKEN` if it has one set.

This is stored on-device (`UserDefaults`) and takes effect immediately, no rebuild
needed — you don't have to touch source or reinstall the app when the tunnel URL
changes (which a free Cloudflare/ngrok tunnel does on every restart). It defaults to
the URL hardcoded in `Uploader.swift` if never set.

The app does a `PUT` of a zipped session folder to that URL, with header
`X-Session-Name: <folder name>` and (if set) `Authorization: Bearer <token>`.

## What the app captures (per the pipeline diagram, step 1)

- **ARKit depth + pose, audio** - ~10 fps frames (rgb jpg, raw depth/conf, pose, intrinsics) + continuous 16kHz mono WAV.
- **Hi-res stills [F1]** - `stills/NNNNNN_still.jpg` with their own pose/intrinsics. Auto-triggered by vertical sweep coverage (see below), plus the on-screen camera button (manual capture, for when the operator wants to be sure), or whenever someone starts speaking (any words; level-based voice detection on the mic, no speech recognition or extra permission).
- **Vertical sweep coverage [coverage]** - auto-stills are binned by horizontal position along the aisle (~40cm bins) *and* camera pitch (`CoverageSweep` in `CaptureSession.swift`, currently 7 pitch bins over ~70°), so panning up/down to reach the top/bottom shelves of a tall bookcase triggers a capture even without walking further — a distance-only trigger could miss rows. The current position's row coverage is shown live on-screen so the operator can see what's still uncovered; the camera button remains available for a manual capture at any time.
- **Typed notes [F2]** - stored in `notes[]` with the camera pose, nearest frame index and the 3D world point at the centre of view (the "current object").
- **Live checks [F3]** - on-screen warnings for blur (Laplacian variance while moving), too close/far (centre depth), missing depth (share of low-confidence depth pixels), limited tracking. Raw metrics are saved per frame in `frames[].quality` so thresholds (`LiveCheck` in `CaptureSession.swift`, currently untuned) can be tuned from real data.
- **Face blur [F17]** - faces are detected (Vision) and blurred on device before any frame or still is written.
- **Country [F8]** - picked once per session before recording; saved as `country` (ISO alpha-2).
- **Relocalize [F5]** - optionally pick a previous session (with a saved map); Record then waits for ARKit to match it. The operator is instructed, while recording, to end the session on a distinct, identifiable object rather than mid-aisle or anywhere generic — ambiguous stopping points (e.g. two visually identical stacks) are the main cause of relocalization mismatches. A low-opacity ghost overlay of that session's last frame (`last_frame.jpg`) is then shown over the live camera view for the next session, so the operator can visually line up the same physical spot before recording starts automatically once ARKit confirms the match. Every session saves `worldmap.arworldmap` at the end so the next room can chain off it.

## What each file does

- `RoomCaptureApp.swift` / `ContentView.swift` — SwiftUI entry point and the single
  screen: live preview, Record/Stop, elapsed time, frame count, session list
  (tap for Share/Delete, dedicated icon button to Upload).
- `CaptureSession.swift` — **the only file that imports ARKit/AVFoundation.**
  Runs the `ARSession` (world tracking + `.sceneDepth`), samples ~10 fps from the
  60 fps frame stream, converts `CVPixelBuffer`s to tightly-packed raw `Data`
  and JPEG, records continuous 16kHz mono audio via `AVAudioEngine`, and hands
  off plain Foundation values (`Data`, `[[Float]]`, `Double`, `String`) to the
  writer/manifest layer below. Also owns LiDAR capability checks, permissions,
  the idle-timer lock, and interruption/backgrounding handling.
- `FrameWriter.swift` — Foundation-only. Writes each frame's rgb/depth/conf files
  on a background queue; drops (and counts) frames if the queue backs up rather
  than blocking capture or buffering in memory.
- `ManifestBuilder.swift` — Foundation-only. Builds and periodically checkpoints
  `manifest.json`, so a killed/interrupted session still leaves a valid,
  readable manifest for whatever frames were written.
- `SessionManager.swift` — Foundation-only. Lists/sizes/deletes session folders
  under the Documents directory, and checks free disk space.
- `Uploader.swift` — Foundation-only. Zips a session folder (via
  `NSFileCoordinator(.forUploading)`) and PUTs it to the configured server URL
  (see "Before you record").
- `SettingsView.swift` — SwiftUI. The gear-icon screen: server URL/token fields
  (`UserDefaults`, same keys `Uploader.swift` reads) and a Test Connection check.
- `Models.swift` — shared Codable/plain structs used across the above.

## Session folder layout

```
session_2026-09-21T14-32-10Z/
  manifest.json
  audio.wav
  worldmap.arworldmap   (if the map saved successfully)
  last_frame.jpg        (last captured frame, used as the next session's alignment ghost)
  frames/
    000000_rgb.jpg
    000000_depth.bin   (raw Float32, row-major, actual depth_width x depth_height)
    000000_conf.bin    (raw UInt8, row-major)
    ...
```

`manifest.json` matches the required shape plus additive fields: `dropped_frames`,
`complete`, `ended_at_unix`, `country`, `relocalized_against`,
`relocalized_at_ar_timestamp`, `faces_blurred`, `world_map`, `stills[]`, `notes[]`,
and per-frame `quality`.
