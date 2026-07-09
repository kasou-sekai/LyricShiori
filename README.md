# LyricShiori

LyricShiori is a focused macOS SwiftUI lyrics app inspired by `MxIris-LyricsX-Project/LyricsX`.

Open this folder in Xcode as a Swift Package, or build from Terminal:

```sh
swift build
```

Current scope:

- Spotify playback reading and control.
- NetEase Cloud Music and QQ Music lyrics search.
- Menu bar lyrics, desktop lyrics window and main lyrics window.
- Local LRC/LRCX parsing, import/export and drag-and-drop import.

Spotify access uses macOS Automation. Open Settings in LyricShiori and click "Authorize Spotify" to trigger the system prompt. If it still does not appear, run the app as a real macOS app bundle from Xcode, not as a raw SwiftPM executable, so macOS can register LyricShiori as the requesting app.
