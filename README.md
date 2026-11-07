# TubeRemote

iPhone/iPad app: browse YouTube in an embedded web view, send videos to another device running the same app, and control playback and the queue from the first device.

- **Viewer mode**: full-screen player, holds the queue and history, accepts commands from any number of remotes.
- **Remote mode**: YouTube browser, device picker, mini-player, Now Playing screen (controls, queue, history).
- Switch modes any time from the mode menu. Defaults are in Settings.

## Build without a Mac

GitHub Actions (`.github/workflows/build.yml`) generates the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` and builds an **unsigned** `.ipa`. Download it from the run's artifacts, then sign and install it with Sideloadly or AltStore using your Apple ID (free accounts: 7-day expiry). TestFlight needs a paid developer account plus signing secrets, not set up yet.

Change the bundle id in `project.yml` if signing complains it is taken.

## How it works

- Discovery: Bonjour `_ytremote._tcp`; service name is `<device name>#<device key>`.
- Transport: JSON over WebSocket (Network.framework), see `Sources/Transport.swift` and `Sources/Models.swift` (`Command`, `ViewerState`). The viewer broadcasts its full state at least once a second; remotes treat 6 s of silence as a dead link and reconnect.
- The viewer is the single source of truth for queue/history. Remotes only send commands.
- Playback runs in the YouTube IFrame player on the viewer. Volume is the system volume (iOS web views cannot set their own).
- Internet/account control later: keep the same messages and put a relay server between viewer and remote.

## Known limits

- No authentication: anyone on the same network running the app can control a viewer.
- Videos with embedding disabled cannot play on a viewer; they are skipped with a notice.
- Volume changes only work on a real device, not the simulator.
- Viewer stops advertising when the app is backgrounded or the screen locks.
