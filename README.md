# AirplayExample

Self-contained iOS/macOS example for generating frames, encoding them to HLS, serving them locally over HTTP, and sending playback to AirPlay via `AVPlayer`.

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

### Minimal integration flow

1. Create an `AirplayService`.
2. Configure the encoder once for the current output size/FPS.
3. Start the local HLS server.
4. Feed frames as `CVPixelBuffer`.
5. Play `airPlayPlaylistURLString` in an `AVPlayer` with external playback enabled.
6. Use `AVRoutePickerView` (wrapped here as `AirPlayRoutePicker`) to choose the AirPlay target.

### Minimal example (if you already have `CVPixelBuffer` frames)

```swift
let airplay = AirplayService(port: 8080)

airplay.onPlaylistReady = {
    // Start local AVPlayer playback here, then route to AirPlay.
}

airplay.configureEncoder(outputSize: CGSize(width: 1280, height: 720), fps: 30)
airplay.startServerIfNeeded()

// Call this repeatedly with your rendered frames
airplay.addPixelBuffer(pixelBuffer)
```

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

`HLSEncoder` setup is tied to output size + FPS. When those change, reset and reconfigure:

1. stop frame production
2. `airplay.resetStream()`
3. `airplay.configureEncoder(outputSize:fps:)`
4. resume frame production

This is exactly what the example engine does.

## 2. How this example app uses `AirplayService`

This app is an example consumer of the service, not a separate architecture.

### File layout

- `AirplayExample/AirplayService/`
  - transport + HLS server + local HTTP server + route picker wrapper
- `AirplayExample/ExampleEngine/CounterBroadcastEngine.swift`
  - queue-backed engine that drives frame timing and feeds `AirplayService`
- `AirplayExample/ExampleEngine/CounterFrameRenderer.swift`
  - Core Image renderer that draws a counter/grid into a `CVPixelBuffer`
- `AirplayExample/ContentView.swift`
  - `ContentViewModel` (UI state + local `AVPlayer`) and `ContentView`

### Runtime flow in this example

1. `ContentViewModel` creates `AirplayService`
2. `ContentViewModel` creates `CounterBroadcastEngine`, injecting `AirplayService`
3. `CounterBroadcastEngine` creates a reusable `CVPixelBuffer`
4. Timer fires at selected FPS (30 / 60)
5. `CounterFrameRenderer` draws the counter frame into the pixel buffer
6. Engine sends the buffer to `AirplayService.addPixelBuffer(_:)`
7. `AirplayService` encodes segments and feeds `HLSServer`
8. After enough segments are buffered, `AirplayService.onPlaylistReady` fires
9. Engine marks itself ready and notifies `ContentViewModel`
10. `ContentViewModel` starts local `AVPlayer` playback using `airPlayPlaylistURLString`
11. User picks an AirPlay route with `AirPlayRoutePicker`

### Why the example is split this way

- `AirplayService`: transport concerns only (HLS + HTTP + URLs)
- `CounterBroadcastEngine`: timing + rendering + feeding frames
- `ContentViewModel`: UI state and local playback behavior
- `ContentView`: SwiftUI layout only

This split is intentional so you can replace the counter renderer/engine with your own pipeline while keeping `AirplayService` unchanged.
