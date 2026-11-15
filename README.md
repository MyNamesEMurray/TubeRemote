# TubeRemote

iPhone/iPad app: browse YouTube in an embedded web view, send videos to another device running the same app, and control playback and the queue from the first device.

- **Viewer mode**: full-screen player, holds the queue and history, accepts commands from any number of remotes.
- **Remote mode**: YouTube browser, device picker, one bottom bar (now playing, play/pause, Send), Now Playing screen (controls, queue, history). Tapping play on a YouTube page plays that video on the viewer.
- Choose the mode in Settings ("Use this device as").
- While Now Playing is open on a remote, its hardware volume buttons change the viewer's volume (`Sources/VolumeKeys.swift`).

## Build without a Mac

GitHub Actions (`.github/workflows/build.yml`) generates the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` and builds an **unsigned** `.ipa`. Download it from the run's artifacts, then sign and install it with Sideloadly or AltStore using your Apple ID (free accounts: 7-day expiry).

TestFlight: `.github/workflows/testflight.yml` runs the tests, archives and uploads. Push a tag such as `v1.0` (the tag sets the app version) or run it by hand. It needs the secrets `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `APPLE_TEAM_ID`.

Change the bundle id in `project.yml` if signing complains it is taken.

## How it works

- Discovery: Bonjour `_ytremote._tcp`; service name is `<device name>#<device key>`.
- Transport: length-prefixed JSON over TCP (Network.framework), see `Sources/Transport.swift` and `Sources/Models.swift` (`Command`, `ViewerState`). The viewer broadcasts its full state at least once a second; remotes treat 6 s of silence as a dead link and reconnect.
- Pairing: a remote and a viewer compare a six-digit code once (`Sources/Pairing.swift`). Each side commits to its key before seeing the other's, so the code cannot be forced to match. The shared secret is saved on both devices.
- Sign-in: the viewer challenges each remote; a paired remote proves it holds the secret. After that every state and command message is encrypted and counted (`Channel` in `Sources/Transport.swift`). Unpaired devices can only ask to pair.
- Versions: `hello` carries `Transport.version`. Devices on different versions show "Update TubeRemote on both devices" instead of failing silently. Add new message fields as optionals.
- The viewer is the single source of truth for queue/history. Remotes only send commands.
- Playback runs on the real YouTube watch page in the viewer's web view, styled to fill the screen and driven by a small script (`bridge` in `Sources/ViewerController.swift`). It shares the YouTube sign-in with the viewer's Browse YouTube screen, so sign in there once and Premium applies. Volume is the system volume (iOS web views cannot set their own).
- Internet/account control later: keep the same messages and put a relay server between viewer and remote.

## Known limits

- Any device on the network can ask a viewer to pair; a person must confirm the code on both screens.
- Sign-in is per device: sign in to YouTube on the viewer itself (menu, Browse YouTube). The remote's sign-in is not copied over.
- The viewer script depends on YouTube's page markup (`#movie_player`, `.ytp-unmute`, `.ad-showing`); a YouTube redesign can break it.
- A video that never starts within 20 seconds (private, removed, region-blocked) is skipped with a notice.
- Volume changes only work on a real device, not the simulator.
- Viewer stops advertising when the app is backgrounded or the screen locks.
