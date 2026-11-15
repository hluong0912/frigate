# Frigate Viewer (iOS)

A small native SwiftUI app for watching this Frigate NVR from an iPhone or iPad:

- **Live**: camera grid with refreshing snapshots; tap a camera for live video over
  WebRTC (via go2rtc, through Frigate's own `/live/webrtc/api/ws` signalling path),
  with a low-bandwidth snapshot mode as fallback. Main/sub stream picker when the
  camera has `live.streams` configured.
- **Review**: Frigate's alerts and detections (last 24h / 3 days / 7 days), filter by
  camera, tap to play the clip.
- **Recordings**: pick a camera and a day, see which hours have footage and how many
  alerts/detections each hour had, tap to play. The player shows the real clock time,
  a coverage strip (tap to jump), ±10 s, earlier/later hour, and picture-in-picture.

No third-party dependencies. iOS 17+, Xcode 16+.

## Build and run

1. Open `ios/FrigateViewer.xcodeproj` in Xcode 16 or newer.
2. Select the **FrigateViewer** target → *Signing & Capabilities* → pick your team
   (a free personal team works for your own devices; change the bundle id
   `com.hluong.frigateviewer` if Xcode says it's taken).
3. Choose your iPhone and press Run.

From the command line (simulator, no signing):

```sh
cd ios
xcodebuild -project FrigateViewer.xcodeproj -scheme FrigateViewer \
  -destination 'generic/platform=iOS Simulator' build
```

## Connecting

On first launch, enter the Frigate address and an account:

| Port | Address example | Sign-in |
|------|-----------------|---------|
| 8971 | `http://192.168.40.249:8971` | Frigate username + password (recommended) |
| 5000 | `http://192.168.40.249:5000` | none; only if you expose it on a trusted network |

The app signs in with `POST /api/login`, keeps the JWT in the Keychain and sends it
as `Authorization: Bearer …` (and as the session cookie for video). It re-signs in
automatically when the token expires.

### TLS on port 8971

Frigate serves 8971 over HTTPS with a **self-signed** certificate by default. iOS
video playback (AVPlayer) and WebRTC signalling will not accept that certificate, so
pick one of:

- **Disable TLS for LAN use** (simplest; auth stays on):
  ```yaml
  tls:
    enabled: false
  ```
  then use `http://<host>:8971`.
- Put Frigate behind a reverse proxy with a real certificate (e.g. Tailscale Serve,
  Caddy, Traefik) and use that `https://` address.

The *Allow self-signed certificate* switch in the app only covers the camera list,
thumbnails and snapshots.

### Live video (WebRTC) requirements

WebRTC media flows directly from go2rtc on port **8555** (TCP and UDP), which the
deploy compose file already publishes. go2rtc must advertise an address the phone can
reach, otherwise the app shows "Timed out" and offers snapshot mode:

```yaml
go2rtc:
  webrtc:
    candidates:
      - 192.168.40.249:8555
      - stun:8555
```

Away from home, use a VPN (WireGuard/Tailscale) into the LAN rather than exposing ports.

## Recordings moved to the NAS

The offload job in `deploy/nvr/offload` moves the oldest hour folders from local disk
to `/mnt/archive/frigate/recordings`. Frigate's database still points at the old local
paths, so **anything that has been offloaded can't be played from the app (or Frigate's
own UI)**: those hours appear in the recordings list but playback fails, and Frigate's
retention cleanup will eventually drop their database rows.

To keep archived footage playable, the offload has to leave it reachable at the path
Frigate knows, for example by mounting the NAS into the Frigate container and leaving
a symlink behind for each moved hour folder (or updating `recordings.path` in the DB).
That's a change to the deploy bundle, not to this app. Until then, browse archived
footage directly on the Synology share.

## How it maps to Frigate's API

| Feature | Endpoint |
|---|---|
| Camera list | `GET /api/config` (`cameras.*`, `live.streams`, `ui.order`) |
| Snapshots | `GET /api/<camera>/latest.jpg?height=…` |
| Live video | WebSocket `/live/webrtc/api/ws?src=<go2rtc stream>` (`webrtc/offer` → `webrtc/answer`) |
| Review list | `GET /api/review?cameras=…&severity=…&after=…&before=…` |
| Thumbnails | `/clips/review/thumb-….webp` (from `thumb_path`) |
| Recording coverage | `GET /api/<camera>/recordings?after=…&before=…` |
| Playback | HLS `GET /vod/<camera>/start/<ts>/end/<ts>/index.m3u8` |

Frigate's VOD playlist concatenates segments and skips gaps, so the app maps player
time to wall-clock time from the segment list (`PlaybackTimeline` in `Models.swift`).
Expect the shown time to be off by up to a second or two around a seek, because the
server snaps the start to the previous keyframe.

## Layout

```
ios/
  FrigateViewer.xcodeproj     Xcode 16 project (folder-synchronised; new files are picked up automatically)
  Support/Info.plist          ATS + local network permission
  FrigateViewer/
    App/                      app entry, shared state
    Networking/               API client, Keychain, settings
    Models/                   Frigate config/review/recording models, playback timeline
    Views/                    Live, Review, Recordings, player, settings
```
