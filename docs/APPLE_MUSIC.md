# Apple Music lyrics

Enable **Apple Music** in Settings → Lyrics sources. Open **Sign in to Apple
Music…**, sign in to an account with an Apple Music subscription, and use
**Check Apple Music connection**. Then search for the current Spotify song.
The source is opt-in; the existing saved provider selection is unchanged.
Playback remains controlled by Spotify.

The transport uses the Apple Music web player's signed-in MusicKit session.
Credentials remain in WebKit's persistent website data store; the app does not
embed or export developer tokens, user tokens, or cookies. Apple controls the
private `syllable-lyrics` endpoint and can change its availability. Both `ttml`
and `ttmlLocalizations` response fields are accepted, with language and
`extend=ttmlLocalizations` requested for translations.

## Data and display

The format follows the upstream [LyricsX Apple Music design](https://github.com/MxIris-LyricsX-Project/LyricsX/blob/develop/docs/apple-music-lyrics.md)
and [LyricsKit TTML implementation](https://github.com/MxIris-LyricsX-Project/LyricsKit/blob/develop/Sources/LyricsService/Lyrics%2BTTML.swift).
Unlike a flat LRC conversion, LRCS keeps:

- `appleMusic`: version 1, original **unchanged** TTML, catalog ID, storefront.
- Per-line `presentation`: source XML element tree, Apple line key, vocal agent,
  alignment, background flag, parent key and explicit end time.
- Every nested span's attributes, text, start and end, even if the current
  renderer does not recognize that extension. Character content is Unicode.
- Translation metadata keyed by language and Apple line key.

Desktop horizontal rendering supports simultaneous active lines, left/right
alignment, smaller background vocals, explicit word/syllable endings and gaps,
inline font sizes, bold/italic and ruby readings. The existing vertical layout
continues to use its uniform-font renderer; ruby/inline styling is retained in
the file but is not drawn in that layout. Apple-specific animation and arbitrary
TTML styling are not fully reproduced. Keeping the raw TTML makes later renderer
upgrades lossless. This is not a claim of complete Apple Music visual parity.

XML imports (`.ttml` or `.xml`) can also be decoded through the parser/storage
API; the import picker accepts XML alongside LRCS. LRCS stays version 1 because
these fields are optional; existing LRCS files remain readable.

## Independent storage

Ordinary LRCS files keep the existing root directory. Apple Music LRCS files
use its `Apple Music/` subdirectory. Each track can keep both variants at once;
`loadLyrics(for:family:)` reads a specific variant independently of the active
choice. `Selections/<SHA256 of full track ID>.json` remembers the active family,
so switching survives relaunches and localized title changes. Downloaded
candidates do not change that choice or overwrite a manually chosen variant.
Only strict matches for the current recording are cached automatically.

A root-level Apple Music file from an earlier build is still readable. On the
next write it is copied to the Apple Music directory before the root file is
removed; existing Apple Music files are preserved on a migration name collision.
The reset action clears both variants and their selection. The Fullscape local
v1 reader explicitly reads the ordinary variant. Rich Apple Music documents are
only exported through the negotiated v2 route.

## Fullscape v2 integration

The upgraded FullScape negotiates `apple-music-v2` through `/bridge-session`.
The original v1 cache route continues to serve ordinary lyrics only. FullScape
never receives Apple login credentials or raw TTML. `prepare` receives a readiness
manifest; `activate` delivers the normalized rich document for the current song.
A stable `documentRevision` lets later polls return `unchanged` without repeating
the full lyrics. `release` retires obsolete current/next queue interests; revision
checks prevent an old release from removing a newer interest in the same URI.

FullScape owns Spotify/QQ/NetEase acquisition in collaboration mode; Shiori only
acquires Apple Music. Turn off **Connect to Fullscape** to use Shiori's standalone
automatic provider search. Manual app searches remain available. A shared
JavaScriptCore matcher bundle reuses FullScape's normalization and matching rules;
protocol requests must advertise the matching generated hash. Apple prefetch uses
the existing relaxed path after the strict check, with 12s duration / 2.5s first
line tolerances and the existing first-second exception.

A single background acquisition worker and URL-level single-flight cache combine
prefetch, activation and manual lookup requests. Released queued tracks do not
start a request. In-flight lookups stop between candidates if no consumer remains.
Prefetch never changes the desktop selection and cannot overwrite a manual source
slot. Activation rechecks local selection, offset and hidden state.

Ordinary and rich browser caches remain independent. FullScape offers Auto,
Apple Music and Other sources; changing this choice reuses available files.
Rich browser documents use IndexedDB, not the ordinary localStorage size budget.
All bridge line/word times use milliseconds; the preserved `presentation.end`
field is explicitly absolute seconds, converted by the browser adapter. Original
XML timing strings stay unchanged in LRCS. QQ's provider correction is never
applied to Apple Music, and the user offset is applied once.

To regenerate matching artifacts from the FullScape checkout:

```sh
node scripts/build-shiori-matcher.mjs /path/to/LyricShiori/Sources/LyricShiori/Resources
```

The generated JS, hash and OpenCC license are versioned in Shiori. FullScape's
`npm run check` verifies its generated matcher hash has not drifted.

## Verification

Automated fixtures contain synthetic text, not a fetched copy of 珊瑚海. They
cover a two-agent duet, overlapping vocal intervals, background voices, nested
syllables, ruby, translations, namespace prefixes, Unicode, invalid XML/times,
legacy LRCS compatibility, round trips and the bridge export gate. A mocked
catalog test uses 珊瑚海 / 周杰伦 metadata and checks localized TTML fetching,
query escaping and rejection of recordings with incompatible durations.

For the live acceptance check, sign in with a subscription, play 周杰伦 & Lara's
珊瑚海 in Spotify, search and manually choose the Apple Music result. Check the
overlapping duet section, right-aligned singer, background vocals, seek/pause,
and reopen the LRCS file. Confirm Fullscape receives no Apple Music payload.
The optional `FULLSCAPE_APPLE_FIXTURE` Swift/browser acceptance checks use a
read-only local Coral Sea cache, including its 68 lines and 14 right-aligned lines.
They also verify overlap and compare against the locally cached Spotify baseline.
The source fixture and rendered lyrics are never committed. These checks validate
cached real data; they do not force a second download of an already cached song.

### Automatic selection and desktop synchronization

Auto uses the same preference module in Chromium and JavaScriptCore. Chinese
lyrics prefer Apple Music. Otherwise the order is rich Apple Music (right-aligned
voices, background/small text, ruby, or overlapping intervals), syllable lyrics
with Chinese translation, syllable lyrics, line lyrics with Chinese translation,
line lyrics, then untimed text. Explicit manual selections and source settings
remain authoritative. Richness is detected from content, not just the existence
of a TTML payload.

`POST /lyrics-v2/selection` confirms the document FullScape actually displays.
A per-client revision rejects out-of-order selections, document revisions protect
against stale Apple candidates, and the app accepts only its current Spotify
track. Confirmation selects the independent LRCS family and immediately updates
the desktop. Prefetch never selects a family. Ordinary cache writes cannot
replace the committed Apple family. Cache-only refresh detects manual source
changes without starting additional provider requests.

Paragraph begin/end timestamps are line timing, never syllable timing. Explicit
`itunes:timing="Line"` disables karaoke even if styling spans are present. Only
authored timed spans can supply word clocks; old LRCS and browser caches are
normalized on read without changing source timestamps or manual offsets. A
same-voice tail overlap in line-only data does not count as a rich duet, and
sub-millisecond rounding overlap is ignored by automatic source ranking.

Offset edits are resolved by full Spotify track ID and source family, across all
localized filename aliases. A manual variant takes priority over automatic files;
when multiple manual aliases exist, the most recently edited one wins. Rendering
applies the offset once to sentence, syllable and background clocks, including
negative timestamps needed to advance the beginning of a song.
