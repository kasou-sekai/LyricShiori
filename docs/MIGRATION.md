# LyricShiori Migration Scope

This workspace is a focused SwiftUI port inspired by `MxIris-LyricsX-Project/LyricsX` 1.8.8.

## Implemented in this first pass

- SwiftPM macOS SwiftUI app target.
- Menu bar extra, main lyrics window, desktop lyrics window, search window and Settings scene.
- LRC/LRCX-compatible timed line parsing, metadata parsing, offset handling and current-line lookup.
- Local lyrics loading/saving, file import/export and drag-and-drop import.
- Lyrics filter defaults ported from the upstream `UserDefaults.plist`.
- Spotify playback reading and control through macOS Automation.
- NetEase Cloud Music and QQ Music lyrics search through the upstream `LyricsKit` provider logic.

## Current scope

- Player: Spotify only.
- Lyrics sources: NetEase Cloud Music and QQ Music only.
- Local LRC/LRCX import/export remains available.

Spotify reading requires macOS Automation permission for LyricShiori to send Apple events to Spotify. The app has an explicit Settings > Authorize Spotify button to trigger the prompt. For stable TCC registration as "LyricShiori", build/run it as a macOS app bundle using the provided `Supporting/Info.plist` usage description.

## Remaining logic differences from LyricsX

- The app intentionally keeps only Spotify, QQ Music and NetEase per current product scope.
- Spotify updates listen to Spotify's distributed playback notification and keep a polling fallback; this mirrors the original Spotify notification source without pulling in non-Spotify players.
- Chinese conversion is still pass-through; OpenCC conversion is not wired.

## Parser test cases to restore under a full XCTest-capable toolchain

- Metadata: `[ti:]`, `[ar:]`, `[al:]`, `[offset:]`.
- Multiple timestamps on one line, for example `[00:01.00][00:02.50]Hello`.
- Invalid untimed plain text rejection.
- Offset-aware current-line lookup.
