# LyricShiori

LyricShiori is a lightweight macOS lyrics companion for Spotify. It displays the current lyrics in the menu bar and as desktop lyrics.

## Features

- Display synchronized lyrics in the menu bar.
- Show customizable desktop lyrics while you listen.
- Search, import, export, and adjust lyrics when needed.

## Recommended companion

LyricShiori works best together with [**Spotify-Full-Screen-Playing**](https://github.com/kasou-sekai/Spotify-Full-Screen-Playing), which provides a richer Spotify lyrics synchronization experience.

Enable **Connect to Full-Screen Playing plugin** in **Settings → General** to connect it.

## Spotify permission

LyricShiori uses macOS Automation to communicate with Spotify. Start Spotify, then select **Authorize Spotify** in **Settings → General** and approve the system prompt. If permission was previously denied, allow LyricShiori in **System Settings → Privacy & Security → Automation**.

## Updates and releases

LyricShiori checks the latest public GitHub Release at launch by default. You can turn this off or use **Check for Updates** from **Settings → General** or the app menu. When an update is available, choose **Install**: the app downloads the matching `LyricShiori-v<version>-macos-arm64.zip`, quits, replaces `/Applications/LyricShiori.app`, and removes both the archive and its temporary extraction folder whether installation succeeds or fails.

The development version is stored in `Sources/LyricShiori/Supporting/Info.plist`. To publish, push a numeric `v<version>` tag such as `v0.2.0`; the release workflow writes that tag into the app bundle before signing it, gives the build a monotonically increasing GitHub run number, and attaches the update archive automatically. For a local release archive, run:

```sh
Scripts/package-release.sh
```

## Acknowledgements

The interaction and lyrics presentation of this project were inspired by [ddddxxx/LyricsX](https://github.com/ddddxxx/LyricsX).
