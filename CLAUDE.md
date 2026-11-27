# TubeRemote

iPhone and iPad app (SwiftUI, iOS 16+, built with the newest Xcode). One app, two roles: a viewer plays YouTube on its screen and holds the queue; a remote browses YouTube and sends commands. README.md covers what the app does and how it connects. This file covers what is not obvious from the code.

## Working in this repo

- There is no Xcode in the cloud session. CI is the compiler: `.github/workflows/build.yml` runs XcodeGen, the unit tests on a simulator, and an unsigned Release device build. Write Swift carefully; mistakes show up only in CI.
- GitHub bills macOS runners at 10 times. A full Build run is 8 to 12 minutes, so 80 to 120 allowance minutes. Open PRs as drafts, keep committing, mark ready once. `build.yml` skips drafts, skips `site/`, `AppStore/` and `*.md`, and cancels a run when a newer commit arrives. Do not push while a build is mid-run unless the change must be in it. `[skip ci]` in the head commit skips the PR build, so never merge unbuilt code that way.
- Develop on `claude/fervent-gates-c10mfs` only. Merges are squash merges. After a merge: `git fetch`, `git checkout -B claude/fervent-gates-c10mfs origin/main`, `git push --force-with-lease`. Deleting remote branches from the session is blocked (HTTP 403).
- Ship = merge the PR, then run `testflight.yml` on `main` with `upload: true`. It skips the unit tests by default because the PR build ran them. Its build number is the run number.
- Comments in code: none, except one line for a reason, limit or trap the code cannot show. Never restate the code. Project-wide reasons belong here.
- The user does not read the code. Explain changes in plain words, say what was not checked, and say what you could not test on a device.

## Map

- `Sources/Models.swift`: `Command`, `ViewerState`, `ServerMessage`, `VideoItem`, `VideoDetails`, `ScanRamp`, `SavedQueue`.
- `Sources/Transport.swift`: Bonjour, framing, the sealed `Channel`, the viewer's server. `Sources/Remote.swift`: the remote's client per viewer. `Sources/Pairing.swift`: six-digit code pairing.
- `Sources/ViewerController.swift`: owns queue, history, player, the page bridge (`bridge` JavaScript string), autoplay, sleep timer, scanning, details and comments.
- `Sources/ViewerViews.swift`, `RemoteViews.swift`, `SharedViews.swift`, `Pro.swift`, `TubeRemoteApp.swift` (root, Settings, onboarding), `Browser.swift` (the remote's YouTube browser and the viewer's cookie sharing).
- `Sources/LockScreenControls.swift`: the remote's lock screen and Control Center controls through a silent sound. `Sources/NowPlayingBridge.swift`, `Sources/NowPlayingShared.swift` and `NowPlayingExtension/`: the iOS 27 Now Playing remote session, which shows the viewer on the Lock Screen and sends the system's commands to it.
- `Sources/Storyboard.swift`: seek preview frames. `Sources/QueueKeeper.swift`: the remote's saved queue. `Share/`: the share extension, which compiles `Models.swift`, `Transport.swift`, `Log.swift` and `SharedConfig.swift`.
- `project.yml` is the source of the Xcode project. `Config/` is generated. `site/` is the privacy and support website, published by `pages.yml`.

## Protocol rules

- `Transport.version` is 3. A different version on the two devices shows "Update TubeRemote on both devices". Add message fields as optionals. Changing the payload of an existing `Command` or `ServerMessage` case breaks builds that differ, and a new case is ignored by old builds (logged as a decode failure).
- Sealed messages are counted. Every sealed message must be opened in order, and `ShareSender` waits for the first `.state` after sign-in, so extra messages before it must be harmless.
- The once-a-second `ViewerState` goes out with `queue` and `history` empty. `.lists` carries them, sent only when they change or to a newly signed-in remote, and `RemoteClient` puts them back. `.details` (description, storyboard, comments, replies) is a separate message for the same reason.
- The viewer is the single source of truth. Remotes only send commands. Pro on the viewer or any connected remote unlocks all remotes.

## Things that depend on YouTube's pages (they will break)

Each has a log line in the Debug Log. Ask the user for it when something stops working. The log is hidden: Settings, then tap the Build row five times. It starts with the app version, iOS version and device model, and also shows what the extensions wrote (tag `N` for the Now Playing extension, `?` for Share), which lives in `nowplaying/extension.log` in the App Group folder. Lines never hold names or video titles.

- Player control and ads: `#movie_player`, `.ad-showing`, `.ytp-*` in `bridge`.
- Skip Ad from the remote: YouTube ignores a script's click, so the bridge sends a full press and then moves the ad to its end. Log: `page: skip ad: ...` lines say which step ran and whether the ad went away.
- Description: `ytInitialPlayerResponse.videoDetails` and `microformat`. Log: none; Details stays a spinner.
- Comments and replies: `/youtubei/v1/next` with a continuation token found in `ytInitialData`. Two response shapes are read. Log: `comments N comments, next ..., mutations ...` and `replies ...`.
- Seek previews: `storyboards.playerStoryboardSpecRenderer.spec`. Log: `storyboard: WxH, N frames`.
- Autoplay next: `ytInitialData` autoplay sets, then the first related link. Log: `autoplay candidate <id>` or `null`.
- Live streams: `getVideoData().isLive`, `getProgressState().isAtLiveHead`, `seekToLiveHead`. A stream that stops moving for 20 seconds is reloaded once as a video.
- Playlists are read from the signed-in page, up to 1000 videos. That is also `ViewerController.maxQueue`: the queue goes to every remote in one message of at most 1 MiB, and a video takes about 250 to 400 bytes, so do not raise it past about 1500 without sending the queue in pieces.

## Decisions that are easy to undo by accident

- Toggle pills keep their label and fill with the accent colour when on. One `Pill` view styles them all.
- The viewer stage is dark through the environment and `preferredColorScheme(.dark)`, except while Settings, Browse or Pair is open. Do not hide the status bar in light mode on iPad: it hides the iPadOS menu bar and window controls. Hiding is the user's setting.
- Floating controls use `glassBackground` (Liquid Glass on iOS 26 and later, no switch). Docked side panels stay on material.
- Docked or floating side panel is decided by width (700 points), not size class, because the iPhone Duo's inner display reports regular size classes.
- Panels slide by transform and the web view scales. Resizing the web view per frame makes the video judder.
- The viewer controls card stays laid out and fades by opacity and offset. Inserting and removing it makes the blur and the pills appear out of step.
- A single tap on the video waits 320 ms so a second tap can be a double tap.
- Hold to scan uses `ScanRamp` on both devices. On release the remote sends how long it was held and the viewer seeks to where that distance leaves it, so a late stop does not overshoot.
- The hidden volume slider must stay inside the window, in the top-left corner. Do not move it off screen: iOS then shows its own volume HUD.
- Lock screen controls (Pro, Settings, off by default) play a silent looping sound so iOS treats the remote as the Now Playing app, and that also keeps it connected in the background. It must not mix with other audio or iOS ignores it, and `VolumeKeys` must not change the audio category while it runs. Pausing the silent sound makes iOS drop the controls within seconds, and while it plays Control Center shows pause even when the video is paused. On iOS 27 and later the silent sound is not used: the Now Playing framework's remote session replaces it (no audio, state taken from what the app reports), and the silent sound stays only for older iOS. On iOS 27 and later the app plays a silent sound that mixes with other audio while a session is on, only to stay running in the background so it can keep the card current; it does not take over Now Playing or pause other apps, and `VolumeKeys` must not change the audio category while it plays. The extension (`NowPlayingExtension/`, bundle id `com.exaltedpixels.TubeRemote.NowPlaying`, App Group) signs in as this device, so it replaces the app's own connection to the viewer; it opens the link per burst of commands and closes it after 8 seconds.
- Do not use `UIScreen.main`, the device idiom, or orientation to lay out. Apple's iPhone Duo guidance asks for width and size from the container.

## Not verified on a device

Storyboard parsing, autoplay candidate, the 8x scan rate, the viewer's light-mode status bar and menu bar on iPad, and anything on an iPhone Duo. Lock screen controls work on a device through the Now Playing extension (iOS 27 and later); the silent-sound mode for older iOS is only verified up to the Control Center icon issue, and App Review's view of the silent audio is unknown. Also unchecked: the viewer's web view recovery after a failed load or a killed web process, hold-to-scan stopping when its button disappears, and the Speed and Quality menus no longer redrawing while open.
