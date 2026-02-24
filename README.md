# AirplayExample

Self-contained iOS/macOS example for generating frames, encoding them to HLS, serving them locally over HTTP, and sending playback to AirPlay via `AVPlayer`.

<img width="744" height="1133" alt="image" src="https://github.com/user-attachments/assets/1665f771-378a-43e0-a311-982e382d2b1a" />


## 1. Using `AirplayService` in another app

`AirplayService` is the transport layer. It owns:

- `HLSEncoder` (turns `CVPixelBuffer` frames into HLS segments)
- `HLSServer` (serves `/hls.m3u8`, `/init.mp4`, `/files/...`)
- local/LAN playlist URLs for local preview and AirPlay playback

### What you need to copy

From `AirplayExample/AirplayService/`:

- `AirplayService.swift`
- `HLSEncoder.swift`
- `HLSServer.swift`
- `HttpServer.swift`
- `AirPlayRoutePicker.swift` (iOS UI only, optional)

If your app already produces `CVPixelBuffer` frames, you do not need the example engine/renderer files.

### Drop-in UI option: `AirplayServiceView` + `AirplayServiceViewModel`

If you want a reusable local preview/player layer (instead of wiring `AVPlayer` yourself), you can also copy:

- `AirplayExample/AirplayService/Views/AirplayServiceView.swift`

This gives you:

- `AirplayServiceViewModel`
  - owns `AirplayService`
  - owns local `AVPlayer`
  - applies AirPlay playback flags
  - starts/reloads playback when the HLS playlist becomes ready
- `AirplayServiceView`
  - a drop-in SwiftUI `VideoPlayer`/placeholder view for local preview

This is intended to be reusable in another app. Your app still owns:

- frame production (`CVPixelBuffer` source)
- when to start/stop sending frames
- any app-specific controls (route picker button placement, compare/debug UI, etc.)

### Minimal integration flow

1. Create an `AirplayService`.
2. Start a stream for the current output size/FPS.
3. Wait for `onPlaylistReady` before calling `play()` on your `AVPlayer`.
4. Feed frames as `CVPixelBuffer`.
5. Play `airPlayPlaylistURLString` in an `AVPlayer` with external playback enabled.
6. Use `AVRoutePickerView` (wrapped here as `AirPlayRoutePicker`) to choose the AirPlay target.

### Minimal example (if you already have `CVPixelBuffer` frames)

```swift
let airplay = AirplayService()

airplay.onPlaylistReady = {
    // Start local AVPlayer playback here, then route to AirPlay.
}

airplay.startStream(outputSize: CGSize(width: 1280, height: 720), fps: 30)

// Call this repeatedly with your rendered frames
airplay.addPixelBuffer(pixelBuffer)
```

### Minimal example (drop-in SwiftUI view + view model)

```swift
@State private var airplayViewModel = AirplayServiceViewModel(
    automaticallyWaitsToMinimizeStalling: false
)

var body: some View {
    VStack {
        AirplayServiceView(viewModel: airplayViewModel)
        AirPlayRoutePicker()
            .frame(width: 72, height: 72)
    }
}
```

`AirPlayRoutePicker()` is just the small wrapper used by this example. You can use Apple's `AVRoutePickerView` directly instead (for example in UIKit, or via your own SwiftUI wrapper).

Then wire your frame pipeline to the owned service:

```swift
let airplay = airplayViewModel.airplayService

airplay.onPlaylistReady = { [weak airplayViewModel] in
    Task { @MainActor in
        airplayViewModel?.setReady(true)
        airplayViewModel?.handlePlaylistReadyChanged(true)
    }
}

airplay.startStream(outputSize: CGSize(width: 1280, height: 720), fps: 30)
airplay.addPixelBuffer(pixelBuffer)
```

If you already have your own readiness/state model, you can call:

- `airplayViewModel.setReady(_:)`
- `airplayViewModel.setRunning(_:)`
- `airplayViewModel.handlePlaylistReadyChanged(_:)`

from your existing engine callbacks.

### Playback / AirPlay requirements (iOS)

- Local playback should use `AVPlayer` with `allowsExternalPlayback = true`
- For iOS/tvOS, also set `usesExternalPlaybackWhileExternalScreenIsActive = true`
- Add `NSLocalNetworkUsageDescription` to your app target
- Device and AirPlay target must be on the same network

### What `AVPlayer` needs (in practice)

The app does not send video directly to AirPlay. It plays the local HLS URL with `AVPlayer`, then iOS routes that playback to an AirPlay target.

Minimum setup:

1. Build the player item from `airPlayPlaylistURLString`
2. Set `allowsExternalPlayback = true`
3. On iOS/tvOS, set `usesExternalPlaybackWhileExternalScreenIsActive = true`
4. Call `play()`
5. Let the user choose an AirPlay route (`AVRoutePickerView`)

Recommended iOS audio session setup (used by the example):

```swift
try AVAudioSession.sharedInstance().setCategory(
    .playback,
    mode: .moviePlayback,
    options: [.allowAirPlay]
)
try AVAudioSession.sharedInstance().setActive(true)
```

Then create the player:

```swift
let player = AVPlayer()
player.allowsExternalPlayback = true
#if os(iOS) || os(tvOS)
player.usesExternalPlaybackWhileExternalScreenIsActive = true
#endif
player.replaceCurrentItem(with: AVPlayerItem(url: URL(string: airplay.airPlayPlaylistURLString)!))
player.play()
```

Notes:

- Start playback after `AirplayService.onPlaylistReady` (or your own readiness signal) to avoid trying to play before segments exist.
- `AVRoutePickerView` is iOS/tvOS UI. On macOS, route selection is usually done from system controls.

### Reconfiguration (resolution / FPS)

`HLSEncoder` setup is tied to output size + FPS. When those change, reset and start a new stream:

1. stop frame production
2. `airplay.resetStream()`
3. `airplay.startStream(outputSize:fps:)`
4. resume frame production

This is exactly what the example engine does.

## 2. How this example app uses `AirplayService`

This app is an example consumer of the service, not a separate architecture.

### File layout

- `AirplayExample/AirplayService/`
  - transport + HLS server + local HTTP server + route picker wrapper
- `AirplayExample/AirplayService/Views/AirplayServiceView.swift`
  - reusable local preview view (`VideoPlayer`) + `AirplayServiceViewModel` (`AirplayService` + `AVPlayer`)
- `AirplayExample/ExampleEngine/CounterBroadcastEngine.swift`
  - queue-backed engine that drives frame timing and emits callbacks (transport-agnostic)
- `AirplayExample/ExampleEngine/CounterFrameRenderer.swift`
  - Core Image renderer that draws a timecode-style counter/grid into a `CVPixelBuffer`
- `AirplayExample/ContentView.swift`
  - `ContentViewModel` (app orchestration + example UI state) and `ContentView`

### Runtime flow in this example

1. `ContentViewModel` creates `AirplayServiceViewModel` (owns `AirplayService` + `AVPlayer`)
2. `ContentViewModel` creates `CounterBroadcastEngine`
3. `CounterBroadcastEngine` creates a reusable `CVPixelBuffer`
4. Timer fires at selected FPS (30 / 60)
5. `CounterFrameRenderer` draws a timecode-style counter frame into the pixel buffer
6. Engine emits callbacks (`onStreamConfigureRequested`, `onPixelBufferRendered`, etc.)
7. `ContentViewModel` wires those callbacks to `AirplayService`
8. `AirplayService` encodes segments and feeds `HLSServer`
9. `AirplayService.onPlaylistReady` notifies the engine, which notifies the UI models
10. `AirplayServiceViewModel` starts/reloads local `AVPlayer` playback using `airPlayPlaylistURLString`
11. User picks an AirPlay route with `AirPlayRoutePicker`

### Current defaults (optimized for lower latency)

The example now starts with lower-latency defaults (no preset selector):

- HLS segment duration: `0.25s`
- Minimum startup buffer: `1.0s`
- `AVPlayer.automaticallyWaitsToMinimizeStalling = false`

You can still change:

- Resolution (`720p` / `1080p`)
- FPS (`30` / `60`)
- Startup buffer (slider)
- `AVPlayer waits to minimize stalling` toggle

### START / STOP behavior

- `START` begins (or resumes) frame production.
- `STOP` pauses frame production only.
- The HLS/AirPlay session is intentionally kept alive on `STOP` so repeated tests can reuse the current route without rebuilding the stream unless configuration changes.

### Why the example is split this way

- `AirplayService`: transport concerns only (HLS + HTTP + URLs)
- `CounterBroadcastEngine`: timing + rendering + callback output (no transport dependency)
- `AirplayServiceViewModel`: `AirplayService` + local `AVPlayer` playback behavior
- `ContentViewModel`: app orchestration + example/debug UI state
- `ContentView`: SwiftUI layout only

This split is intentional so you can replace the counter renderer/engine with your own pipeline while keeping `AirplayService` unchanged.

### References
Derived from [swifter](https://github.com/httpswift/swifter)  and [VideoCreator](https://github.com/fuziki/VideoCreator)

Thanks!
