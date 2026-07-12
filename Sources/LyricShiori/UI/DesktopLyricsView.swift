import AppKit
import QuartzCore
import SwiftUI

struct DesktopLyricsView: View {
    @Bindable var store: LyricShioriStore
    @State private var mouseOverLyrics = false

    private let linePromotionAnimation = Animation.timingCurve(
        // Match Full Screen Playing's lyric track: it settles briskly without
        // the spring-like rebound that makes the destination feel unstable.
        0.30, 0.15, 0.20, 1,
        duration: 0.25
    )

    var body: some View {
        lyricsContent
            .onHover { mouseOverLyrics = $0 }
    }

    private var lyricsContent: some View {
        let lines = store.desktopLyricsDisplayLines()
        let palette = store.desktopLyricsPalette()
        let fontSize = store.settings.desktopLyricsFontSize
        let alignment = store.settings.desktopLyricsAlignment
        let lineCount = max(1, lines.count)
        // The renderer's frame is intentionally taller than its glyphs for
        // karaoke effects. The movement slot should track the glyphs instead,
        // otherwise two visible lines look far apart even with a zero Stack
        // spacing. Frames may overlap; their text does not.
        let slotHeight = DesktopLyricsLayout.slotHeight(for: fontSize)
        let contentHeight = DesktopLyricsLayout.glyphStackHeight(for: fontSize, lineCount: lineCount)
        let verticalPadding = DesktopLyricsLayout.verticalPadding(for: fontSize)

        // Use a fixed vertical slot for each relative lyric position. SwiftUI
        // animates this parent transform for both native Text and the AppKit
        // karaoke view, avoiding the layout snap that affected CJK karaoke lines.
        return ZStack(alignment: .top) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { offset, line in
                DesktopLyricLineView(
                    line: line,
                    palette: palette,
                    fontSize: fontSize,
                    alignment: alignment
                )
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
                .offset(y: Double(offset) * slotHeight)
            }
        }
        .frame(maxWidth: .infinity, minHeight: contentHeight, alignment: .top)
        .padding(.horizontal, max(8, fontSize * 0.35))
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
        .overlay {
            if store.isDesktopLyricsDragging {
                let shape = RoundedRectangle(
                    cornerRadius: max(8, fontSize * 0.35),
                    style: .continuous
                )
                shape
                    .stroke(Color.black.opacity(0.78), lineWidth: 3)
                    .overlay {
                        shape.stroke(Color.white.opacity(0.9), lineWidth: 1)
                    }
            }
        }
        .opacity(store.settings.hideLyricsWhenMousePassingBy && mouseOverLyrics ? 0 : 1)
        // The retained views keep their identity, so the upcoming line glides into
        // the active position instead of being replaced in place.
        // Keep every retained row on one shared, non-bouncy track. The next row
        // therefore occupies the active row's exact position instead of being
        // visually replaced there.
        .animation(linePromotionAnimation, value: store.currentLineIndex)
        .animation(.easeInOut(duration: 0.22), value: mouseOverLyrics)
    }
}

private struct DesktopLyricLineView: View {
    var line: DesktopLyricsDisplayLine
    var palette: DesktopLyricsPalette
    var fontSize: Double
    var alignment: DesktopLyricsAlignment

    private let promotionAnimation = Animation.timingCurve(
        0.30, 0.15, 0.20, 1,
        duration: 0.25
    )

    var body: some View {
        DesktopLyricText(
            line: line,
            pendingColor: line.isActive ? palette.pending : palette.secondary.opacity(0.56),
            playedColor: line.isActive ? palette.played : palette.secondary,
            shadowColor: palette.shadow.opacity(line.isActive ? 0.42 : 0.28),
            // Keep the glyph layout at the active size for both rows. The
            // external scale below then grows the *whole line* smoothly when
            // the upcoming lyric is promoted, rather than snapping fonts.
            fontSize: fontSize,
            fontWeight: line.isActive ? .semibold : .regular,
            alignment: alignment
        )
        .opacity(opacity)
        .scaleEffect(scale, anchor: alignment.scaleAnchor)
        .blur(radius: blurRadius)
        .animation(promotionAnimation, value: line.isActive)
    }

    private var opacity: Double {
        // A promoted line must remain visible for the full trip. Focus comes
        // from scale, colour, and clarity rather than a fade through zero.
        1
    }

    private var scale: Double {
        if line.isActive { return 1 }
        // Keep the upcoming line recognisable throughout the move. Its subtle
        // 12% size difference mirrors the reference player's lyric track,
        // while avoiding a distracting grow-at-the-destination effect.
        return max(0.72, 1 - Double(abs(line.distanceFromActive)) * 0.12)
    }

    private var blurRadius: Double {
        line.isActive ? 0 : min(1.2, Double(abs(line.distanceFromActive)) * 0.18)
    }

}

private struct DesktopLyricText: View {
    var line: DesktopLyricsDisplayLine
    var pendingColor: Color
    var playedColor: Color
    var shadowColor: Color
    var fontSize: Double
    var fontWeight: Font.Weight
    var alignment: DesktopLyricsAlignment

    var body: some View {
        // Do not replace an upcoming Text view with a different AppKit view at
        // the line boundary. Keeping one renderer alive lets its actual glyphs
        // travel into the active slot instead of fading out and back in.
        if hasKaraokeTimings {
            CoreAnimationKaraokeLine(
                line: renderedLine,
                playbackTime: renderedLine.playbackTime,
                isPlaying: renderedLine.isPlaying,
                pendingColor: pendingColor,
                playedColor: playedColor,
                shadowColor: shadowColor,
                fontSize: fontSize,
                fontWeight: fontWeight,
                alignment: alignment
            )
            .frame(maxWidth: .infinity)
            .frame(height: max(fontSize * 1.58, 30))
        } else {
            CoreAnimationPlainLine(
                line: renderedLine,
                textColor: line.isActive ? playedColor : pendingColor,
                shadowColor: shadowColor,
                fontSize: fontSize,
                fontWeight: fontWeight,
                alignment: alignment
            )
            .frame(maxWidth: .infinity)
            .frame(height: max(fontSize * 1.58, 30))
        }
    }

    private var hasKaraokeTimings: Bool {
        line.wordTimings.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var renderedLine: DesktopLyricsDisplayLine {
        guard !line.isActive else { return line }

        // Inactive lines remain in the same renderer but use a stationary
        // playback snapshot, so their text never begins its own animation
        // before it is promoted to the active slot.
        var snapshot = line
        snapshot.playbackTime = line.distanceFromActive < 0
            ? (line.lineEnd ?? line.lineStart)
            : line.lineStart
        snapshot.isPlaying = false
        return snapshot
    }

}

private struct ProgressiveDesktopLyricText: View {
    var text: String
    var progress: Double
    var pendingColor: Color
    var playedColor: Color
    var shadowColor: Color
    var fontSize: Double
    var fontWeight: Font.Weight
    var alignment: DesktopLyricsAlignment
    var scrollProgress: Double

    var body: some View {
        HorizontalScrollingLine(
            alignment: alignment,
            strategy: .timed(
                progress: scrollProgress,
                lineDuration: nil
            ),
            height: max(fontSize * 1.35, 24)
        ) {
            lyricText
                .foregroundStyle(pendingColor)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        lyricText
                            .foregroundStyle(playedColor)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
                            }
                        }
                    .allowsHitTesting(false)
                }
        }
    }

    private var lyricText: some View {
        Text(text)
            .font(.system(size: fontSize, weight: fontWeight, design: .default))
            .shadow(color: shadowColor, radius: fontSize * 0.065, x: 0, y: fontSize * 0.025)
            .lineLimit(1)
            .multilineTextAlignment(alignment.textAlignment)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PlainDesktopLyricText: View {
    var text: String
    var lineStart: TimeInterval
    var lineEnd: TimeInterval?
    var textColor: Color
    var shadowColor: Color
    var fontSize: Double
    var fontWeight: Font.Weight
    var alignment: DesktopLyricsAlignment
    var scrollProgress: Double

    var body: some View {
        HorizontalScrollingLine(
            alignment: alignment,
            strategy: .timed(
                progress: scrollProgress,
                lineDuration: lineEnd.map { max(0, $0 - lineStart) }
            ),
            height: max(fontSize * 1.35, 24)
        ) {
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight, design: .default))
                .foregroundStyle(textColor)
                .shadow(color: shadowColor, radius: fontSize * 0.065, x: 0, y: fontSize * 0.025)
                .lineLimit(1)
                .multilineTextAlignment(alignment.textAlignment)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Renders karaoke words with Core Animation rather than rebuilding a SwiftUI
/// word tree every frame. The compositor advances the wipe, lift, and scroll
/// animations independently of the SwiftUI update cycle.
private struct CoreAnimationKaraokeLine: NSViewRepresentable {
    var line: DesktopLyricsDisplayLine
    var playbackTime: TimeInterval
    var isPlaying: Bool
    var pendingColor: Color
    var playedColor: Color
    var shadowColor: Color
    var fontSize: Double
    var fontWeight: Font.Weight
    var alignment: DesktopLyricsAlignment

    func makeNSView(context: Context) -> CoreAnimationKaraokeView {
        let view = CoreAnimationKaraokeView()
        view.configure(
            line: line,
            playbackTime: playbackTime,
            isPlaying: isPlaying,
            pendingColor: pendingColor,
            playedColor: playedColor,
            shadowColor: shadowColor,
            fontSize: fontSize,
            fontWeight: fontWeight,
            alignment: alignment
        )
        return view
    }

    func updateNSView(_ view: CoreAnimationKaraokeView, context: Context) {
        view.configure(
            line: line,
            playbackTime: playbackTime,
            isPlaying: isPlaying,
            pendingColor: pendingColor,
            playedColor: playedColor,
            shadowColor: shadowColor,
            fontSize: fontSize,
            fontWeight: fontWeight,
            alignment: alignment
        )
    }

    static func dismantleNSView(_ nsView: CoreAnimationKaraokeView, coordinator: ()) {
        nsView.stopAnimations()
    }
}

@MainActor
private final class CoreAnimationKaraokeView: NSView {
    private let viewportLayer = CALayer()
    private let contentLayer = CALayer()
    private var configuration: Configuration?
    private var sourceKey: String?
    private var lastPlaybackTime: TimeInterval = 0
    private var lastMediaTime: CFTimeInterval = 0
    private var lastIsPlaying = false

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        viewportLayer.isGeometryFlipped = true
        viewportLayer.masksToBounds = true
        contentLayer.isGeometryFlipped = true
        contentLayer.anchorPoint = .zero
        viewportLayer.addSublayer(contentLayer)
        layer?.addSublayer(viewportLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        viewportLayer.frame = bounds
        renderCurrentConfiguration()
    }

    func configure(
        line: DesktopLyricsDisplayLine,
        playbackTime: TimeInterval,
        isPlaying: Bool,
        pendingColor: Color,
        playedColor: Color,
        shadowColor: Color,
        fontSize: Double,
        fontWeight: Font.Weight,
        alignment: DesktopLyricsAlignment
    ) {
        let next = Configuration(
            line: line,
            playbackTime: playbackTime,
            isPlaying: isPlaying,
            pendingColor: NSColor(pendingColor),
            playedColor: NSColor(playedColor),
            shadowColor: NSColor(shadowColor),
            fontSize: fontSize,
            fontWeight: fontWeight,
            alignment: alignment
        )
        let nextSourceKey = next.sourceKey
        let mediaTime = CACurrentMediaTime()
        let predictedPlayback = lastPlaybackTime + max(0, mediaTime - lastMediaTime)
        let requiresResync = sourceKey != nextSourceKey
            || lastIsPlaying != isPlaying
            || (isPlaying && abs(predictedPlayback - playbackTime) > 0.50)
            || (!isPlaying && abs(lastPlaybackTime - playbackTime) > 0.01)

        configuration = next
        guard requiresResync else { return }
        sourceKey = nextSourceKey
        lastPlaybackTime = playbackTime
        lastMediaTime = mediaTime
        lastIsPlaying = isPlaying
        renderCurrentConfiguration()
    }

    func stopAnimations() {
        contentLayer.removeAllAnimations()
        contentLayer.sublayers?.forEach { $0.removeAllAnimations() }
    }

    private func renderCurrentConfiguration() {
        guard let configuration,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        let words = DesktopKaraokeWord.words(
            text: configuration.line.text,
            timings: configuration.line.wordTimings,
            lineStart: configuration.line.lineStart,
            lineEnd: configuration.line.lineEnd
        ) ?? [
            DesktopKaraokeWord(
                id: 0,
                text: configuration.line.text,
                start: configuration.line.lineStart,
                duration: max(0.08, (configuration.line.lineEnd ?? configuration.line.lineStart + 3) - configuration.line.lineStart)
            ),
        ]
        guard !words.isEmpty else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.removeAllAnimations()
        contentLayer.sublayers = nil

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let weight: NSFont.Weight = configuration.fontWeight == .semibold ? .semibold : .regular
        // CATextLayer's plain-font path does not match SwiftUI's text metrics
        // reliably. Use an attributed system font and retain the active line's
        // visual prominence from the original renderer.
        let font = NSFont.systemFont(ofSize: configuration.fontSize * 1.12, weight: weight)
        let textHeight = max(CGFloat(font.pointSize * 1.38), 30)
        let textY = max(0, (bounds.height - textHeight) / 2)
        let widths = words.map { word in
            ceil((word.text as NSString).size(withAttributes: [.font: font]).width)
        }
        let xOrigins = widths.reduce(into: [CGFloat]()) { origins, width in
            origins.append((origins.last ?? 0) + (origins.isEmpty ? 0 : widths[origins.count - 1]))
        }
        let contentWidth = max(widths.reduce(0, +), 1)
        let overflow = max(0, contentWidth - bounds.width)
        let currentOffset = scrollOffset(
            at: configuration.playbackTime,
            words: words,
            xOrigins: xOrigins,
            widths: widths,
            overflow: overflow
        )
        let fixedX: CGFloat
        if overflow > 1 {
            fixedX = -currentOffset
        } else {
            switch configuration.alignment {
            case .left: fixedX = 0
            case .center: fixedX = max(0, (bounds.width - contentWidth) / 2)
            case .right: fixedX = max(0, bounds.width - contentWidth)
            }
        }
        contentLayer.bounds = CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        contentLayer.position = CGPoint(x: fixedX, y: 0)

        let mediaTime = CACurrentMediaTime()
        for index in words.indices {
            let word = words[index]
            let width = widths[index]
            let wordLayer = CALayer()
            wordLayer.anchorPoint = .zero
            wordLayer.frame = CGRect(x: xOrigins[index], y: 0, width: width, height: bounds.height)
            let wordProgress = word.progress(at: configuration.playbackTime)
            let playedWidth = width * wordProgress

            let pendingText = textLayer(
                text: word.text,
                font: font,
                color: configuration.pendingColor,
                shadow: configuration.shadowColor,
                scale: scale,
                frame: CGRect(x: 0, y: textY, width: width, height: textHeight)
            )
            wordLayer.addSublayer(pendingText)

            let clipLayer = CALayer()
            clipLayer.anchorPoint = .zero
            clipLayer.position = .zero
            clipLayer.bounds = CGRect(x: 0, y: 0, width: playedWidth, height: bounds.height)
            clipLayer.masksToBounds = true
            let playedText = textLayer(
                text: word.text,
                font: font,
                color: configuration.playedColor,
                shadow: configuration.shadowColor,
                scale: scale,
                frame: CGRect(x: 0, y: textY, width: width, height: textHeight)
            )
            clipLayer.addSublayer(playedText)
            wordLayer.addSublayer(clipLayer)
            contentLayer.addSublayer(wordLayer)

            guard configuration.isPlaying, wordProgress < 1 else { continue }
            let beginTime = mediaTime + word.start - configuration.playbackTime
            let wipe = CABasicAnimation(keyPath: "bounds.size.width")
            wipe.fromValue = 0
            wipe.toValue = width
            wipe.beginTime = beginTime
            wipe.duration = max(0.08, word.duration)
            wipe.timingFunction = CAMediaTimingFunction(name: .linear)
            wipe.fillMode = .both
            wipe.isRemovedOnCompletion = false
            clipLayer.add(wipe, forKey: "karaoke-wipe")

            let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
            lift.values = [0, -configuration.fontSize * 0.065, 0]
            lift.keyTimes = [0, 0.5, 1]
            lift.beginTime = beginTime
            lift.duration = max(0.08, word.duration)
            lift.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            lift.fillMode = .both
            lift.isRemovedOnCompletion = false
            wordLayer.add(lift, forKey: "karaoke-lift")
        }
        CATransaction.commit()

        guard configuration.isPlaying, overflow > 1 else { return }
        scheduleScroll(
            from: configuration.playbackTime,
            mediaTime: mediaTime,
            words: words,
            xOrigins: xOrigins,
            widths: widths,
            overflow: overflow,
            currentOffset: currentOffset
        )
    }

    private func textLayer(
        text: String,
        font: NSFont,
        color: NSColor,
        shadow: NSColor,
        scale: CGFloat,
        frame: CGRect
    ) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
        layer.shadowColor = shadow.cgColor
        layer.shadowOpacity = 0.38
        layer.shadowRadius = font.pointSize * 0.065
        layer.shadowOffset = CGSize(width: 0, height: font.pointSize * 0.025)
        layer.alignmentMode = .left
        layer.truncationMode = .none
        layer.isWrapped = false
        layer.contentsScale = scale
        layer.frame = frame
        return layer
    }

    private func scheduleScroll(
        from playbackTime: TimeInterval,
        mediaTime: CFTimeInterval,
        words: [DesktopKaraokeWord],
        xOrigins: [CGFloat],
        widths: [CGFloat],
        overflow: CGFloat,
        currentOffset: CGFloat
    ) {
        guard let lastWord = words.last else {
            return
        }

        let endTime = lastWord.start + max(0.08, lastWord.duration)
        guard endTime > playbackTime + 0.02 else { return }

        // A dense, time-based track is intentionally used instead of a keyframe
        // per word. The old word-boundary track changed velocity abruptly and was
        // perceived as a series of small jolts on long lyrics.
        let duration = endTime - playbackTime
        let interval = max(1.0 / 60.0, duration / 1_200)
        var samples: [CGFloat] = [currentOffset]
        var time = playbackTime + interval
        while time < endTime {
            samples.append(
                scrollOffset(
                    at: time,
                    words: words,
                    xOrigins: xOrigins,
                    widths: widths,
                    overflow: overflow
                )
            )
            time += interval
        }
        samples.append(
            scrollOffset(
                at: endTime,
                words: words,
                xOrigins: xOrigins,
                widths: widths,
                overflow: overflow
            )
        )

        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = samples.map { -$0 }
        animation.duration = duration
        animation.beginTime = mediaTime
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        contentLayer.add(animation, forKey: "karaoke-scroll")
    }

    private func scrollOffset(
        at playbackTime: TimeInterval,
        words: [DesktopKaraokeWord],
        xOrigins: [CGFloat],
        widths: [CGFloat],
        overflow: CGFloat
    ) -> CGFloat {
        guard let index = wordIndex(at: playbackTime, in: words) else { return 0 }
        let currentCenter = xOrigins[index] + widths[index] / 2
        guard index + 1 < words.count else {
            return offset(forCenter: currentCenter, overflow: overflow)
        }
        let nextCenter = xOrigins[index + 1] + widths[index + 1] / 2
        // Pass through each word's visual centre at its timing midpoint. This
        // gives an uninterrupted path even when word durations vary widely.
        let currentFocus = words[index].start + words[index].duration * 0.5
        let nextFocus = words[index + 1].start + words[index + 1].duration * 0.5
        let transition = min(max((playbackTime - currentFocus) / max(0.01, nextFocus - currentFocus), 0), 1)
        return offset(forCenter: currentCenter + (nextCenter - currentCenter) * transition, overflow: overflow)
    }

    private func offset(forCenter center: CGFloat, overflow: CGFloat) -> CGFloat {
        min(max(center - bounds.width / 2, 0), overflow)
    }

    private func wordIndex(at playbackTime: TimeInterval, in words: [DesktopKaraokeWord]) -> Int? {
        if let index = words.firstIndex(where: {
            playbackTime >= $0.start && playbackTime < $0.start + max(0.08, $0.duration)
        }) {
            return index
        }
        if playbackTime < words.first?.start ?? 0 { return 0 }
        return words.lastIndex(where: { $0.start <= playbackTime })
    }

    private struct Configuration {
        var line: DesktopLyricsDisplayLine
        var playbackTime: TimeInterval
        var isPlaying: Bool
        var pendingColor: NSColor
        var playedColor: NSColor
        var shadowColor: NSColor
        var fontSize: Double
        var fontWeight: Font.Weight
        var alignment: DesktopLyricsAlignment

        var sourceKey: String {
            "\(line.id)|\(line.text)|\(line.wordTimings)|\(fontSize)|\(fontWeight)|\(alignment.rawValue)|\(pendingColor.hash)|\(playedColor.hash)|\(shadowColor.hash)"
        }
    }
}

/// A lightweight layer-backed renderer for active, line-timed lyrics. It keeps
/// long plain lines moving even when there are no word timestamps to animate.
private struct CoreAnimationPlainLine: NSViewRepresentable {
    var line: DesktopLyricsDisplayLine
    var textColor: Color
    var shadowColor: Color
    var fontSize: Double
    var fontWeight: Font.Weight
    var alignment: DesktopLyricsAlignment

    func makeNSView(context: Context) -> CoreAnimationPlainLineView {
        let view = CoreAnimationPlainLineView()
        view.configure(
            line: line,
            textColor: textColor,
            shadowColor: shadowColor,
            fontSize: fontSize,
            fontWeight: fontWeight,
            alignment: alignment
        )
        return view
    }

    func updateNSView(_ view: CoreAnimationPlainLineView, context: Context) {
        view.configure(
            line: line,
            textColor: textColor,
            shadowColor: shadowColor,
            fontSize: fontSize,
            fontWeight: fontWeight,
            alignment: alignment
        )
    }
}

@MainActor
private final class CoreAnimationPlainLineView: NSView {
    private let viewportLayer = CALayer()
    private let contentLayer = CALayer()
    private var configuration: Configuration?
    private var sourceKey: String?
    private var lastPlaybackTime: TimeInterval = 0
    private var lastMediaTime: CFTimeInterval = 0
    private var lastIsPlaying = false

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        viewportLayer.isGeometryFlipped = true
        viewportLayer.masksToBounds = true
        contentLayer.isGeometryFlipped = true
        contentLayer.anchorPoint = .zero
        viewportLayer.addSublayer(contentLayer)
        layer?.addSublayer(viewportLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        viewportLayer.frame = bounds
        render()
    }

    func configure(
        line: DesktopLyricsDisplayLine,
        textColor: Color,
        shadowColor: Color,
        fontSize: Double,
        fontWeight: Font.Weight,
        alignment: DesktopLyricsAlignment
    ) {
        let next = Configuration(
            line: line,
            textColor: NSColor(textColor),
            shadowColor: NSColor(shadowColor),
            fontSize: fontSize,
            fontWeight: fontWeight,
            alignment: alignment
        )
        let mediaTime = CACurrentMediaTime()
        let predictedPlayback = lastPlaybackTime + max(0, mediaTime - lastMediaTime)
        let requiresResync = sourceKey != next.sourceKey
            || lastIsPlaying != line.isPlaying
            || (line.isPlaying && abs(predictedPlayback - line.playbackTime) > 0.50)
            || (!line.isPlaying && abs(lastPlaybackTime - line.playbackTime) > 0.01)

        configuration = next
        guard requiresResync else { return }
        sourceKey = next.sourceKey
        lastPlaybackTime = line.playbackTime
        lastMediaTime = mediaTime
        lastIsPlaying = line.isPlaying
        render()
    }

    private func render() {
        guard let configuration,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.removeAllAnimations()
        contentLayer.sublayers = nil

        let weight: NSFont.Weight = configuration.fontWeight == .semibold ? .semibold : .regular
        let font = NSFont.systemFont(ofSize: configuration.fontSize, weight: weight)
        let width = max(ceil((configuration.line.text as NSString).size(withAttributes: [.font: font]).width), 1)
        let overflow = max(0, width - bounds.width)
        let currentPhase = scrollPhase(
            playbackTime: configuration.line.playbackTime,
            lineStart: configuration.line.lineStart,
            lineEnd: configuration.line.lineEnd
        )
        let x: CGFloat
        if overflow > 1 {
            x = -overflow * currentPhase.phase
        } else {
            switch configuration.alignment {
            case .left: x = 0
            case .center: x = max(0, (bounds.width - width) / 2)
            case .right: x = max(0, bounds.width - width)
            }
        }
        contentLayer.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        contentLayer.position = CGPoint(x: x, y: 0)

        let textLayer = CATextLayer()
        textLayer.string = NSAttributedString(
            string: configuration.line.text,
            attributes: [.font: font, .foregroundColor: configuration.textColor]
        )
        textLayer.shadowColor = configuration.shadowColor.cgColor
        textLayer.shadowOpacity = 0.42
        textLayer.shadowRadius = font.pointSize * 0.065
        textLayer.shadowOffset = CGSize(width: 0, height: font.pointSize * 0.025)
        textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        textLayer.frame = CGRect(x: 0, y: max(0, (bounds.height - font.pointSize * 1.35) / 2), width: width, height: max(font.pointSize * 1.35, 24))
        contentLayer.addSublayer(textLayer)
        CATransaction.commit()

        guard configuration.line.isPlaying,
              overflow > 1,
              currentPhase.remainingDuration > 0.02 else {
            return
        }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = x
        animation.toValue = -overflow
        animation.beginTime = CACurrentMediaTime() + currentPhase.delay
        animation.duration = currentPhase.remainingDuration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        contentLayer.add(animation, forKey: "plain-scroll")
    }

    private func scrollPhase(
        playbackTime: TimeInterval,
        lineStart: TimeInterval,
        lineEnd: TimeInterval?
    ) -> (phase: CGFloat, delay: TimeInterval, remainingDuration: TimeInterval) {
        guard let lineEnd else { return (0, 0, 0) }
        let lineDuration = lineEnd - lineStart
        guard lineDuration > 0.2 else { return (0, 0, 0) }
        let startHold = min(0.45, max(0.18, lineDuration * 0.10))
        let endHold = min(0.65, max(0.20, lineDuration * 0.08))
        let availableMovingDuration = max(0.12, lineDuration - startHold - endHold)
        // Use the complete usable line duration. Finishing based on character
        // count made long lines sprint to the end, pause, then jump to the next
        // line; a constant track reads much more naturally.
        let movingDuration = availableMovingDuration
        let elapsed = min(max(playbackTime - lineStart, 0), lineDuration)
        let movingElapsed = min(max(elapsed - startHold, 0), movingDuration)
        let phase = CGFloat(movingElapsed / movingDuration)
        let delay = max(0, startHold - elapsed)
        return (phase, delay, max(0, movingDuration - movingElapsed))
    }

    private struct Configuration {
        var line: DesktopLyricsDisplayLine
        var textColor: NSColor
        var shadowColor: NSColor
        var fontSize: Double
        var fontWeight: Font.Weight
        var alignment: DesktopLyricsAlignment

        var sourceKey: String {
            "\(line.id)|\(line.text)|\(line.lineEnd ?? -1)|\(fontSize)|\(fontWeight)|\(alignment.rawValue)|\(textColor.hash)|\(shadowColor.hash)"
        }
    }
}

private struct HorizontalScrollingLine<Content: View>: View {
    var alignment: DesktopLyricsAlignment
    var strategy: HorizontalScrollStrategy
    var height: CGFloat
    @ViewBuilder var content: Content
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let overflow = max(0, contentWidth - viewportWidth)
            let xOffset = overflow > 1 ? -scrollOffset(viewportWidth: viewportWidth, overflow: overflow) : 0

            content
                .background(
                    GeometryReader { contentProxy in
                        Color.clear.preference(key: DesktopLineWidthPreferenceKey.self, value: contentProxy.size.width)
                    }
                )
                .frame(width: overflow > 1 ? contentWidth : viewportWidth, alignment: overflow > 1 ? .leading : alignment.frameAlignment)
                .offset(x: xOffset)
                .frame(width: viewportWidth, height: height, alignment: .leading)
                .clipped()
        }
        .frame(height: height)
        .onPreferenceChange(DesktopLineWidthPreferenceKey.self) { contentWidth = $0 }
    }

    private func scrollOffset(viewportWidth: CGFloat, overflow: CGFloat) -> CGFloat {
        switch strategy {
        case .timed(let progress, let lineDuration):
            return overflow * timedScrollPhase(progress: progress, lineDuration: lineDuration)
        }
    }

    private func timedScrollPhase(progress: Double, lineDuration: TimeInterval?) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        guard let lineDuration, lineDuration > 0.2 else {
            return CGFloat(clamped)
        }

        let startHold = min(0.45, max(0.18, lineDuration * 0.10))
        let endHold = min(0.65, max(0.20, lineDuration * 0.08))
        let availableMovingDuration = max(0.12, lineDuration - startHold - endHold)
        let movingDuration = availableMovingDuration
        let currentTime = clamped * lineDuration
        let movingProgress = (currentTime - startHold) / movingDuration
        return CGFloat(min(max(movingProgress, 0), 1))
    }
}

private enum HorizontalScrollStrategy {
    case timed(progress: Double, lineDuration: TimeInterval?)
}

private struct DesktopLineWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DesktopKaraokeWord: Identifiable, Equatable {
    var id: Int
    var text: String
    var start: TimeInterval
    var duration: TimeInterval

    var peakGlow: Double {
        min(1, ceil(duration * 10) / 10)
    }

    func progress(at playbackTime: TimeInterval) -> Double {
        let elapsed = playbackTime - start
        return min(max(elapsed / max(0.08, duration), 0), 1)
    }

    static func displayUnitCount(in text: String) -> Int {
        displayUnits(from: text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    static func words(
        text: String,
        timings: [WordTiming],
        lineStart: TimeInterval,
        lineEnd: TimeInterval?
    ) -> [DesktopKaraokeWord]? {
        guard !timings.isEmpty else { return nil }
        let characters = Array(text).map(String.init)
        guard !characters.isEmpty else { return nil }
        let timingTexts = timings.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let hasTimingText = timingTexts.contains { !$0.isEmpty }
        guard hasTimingText else { return nil }

        var output: [DesktopKaraokeWord] = []
        var outputID = 0

        for index in timings.indices {
            let timing = timings[index]
            let wordText = timing.text.isEmpty ? characters[safe: index] ?? "" : timing.text
            guard !wordText.isEmpty else { continue }
            let nextStart = timings[safe: index + 1]?.start
            let fallbackEnd = nextStart ?? lineEnd ?? (lineStart + 3)
            let duration = timing.duration ?? max(0.08, fallbackEnd - timing.start)
            output.append(
                contentsOf: wordsFromTimedText(
                    text: wordText,
                    start: max(lineStart, timing.start),
                    duration: max(0.08, duration),
                    nextID: &outputID
                )
            )
        }

        return output
    }

    private static func wordsFromTimedText(
        text: String,
        start: TimeInterval,
        duration: TimeInterval,
        nextID: inout Int
    ) -> [DesktopKaraokeWord] {
        let units = displayUnits(from: text)
        guard !units.isEmpty else { return [] }
        guard units.count > 1 else {
            defer { nextID += 1 }
            return [
                DesktopKaraokeWord(
                    id: nextID,
                    text: units[0],
                    start: start,
                    duration: max(0.08, duration)
                ),
            ]
        }

        let weights = units.map(timingWeight)
        let totalWeight = max(0.01, weights.reduce(0, +))
        var elapsed: TimeInterval = 0
        return units.indices.map { index in
            let unitDuration = index == units.indices.last
                ? max(0.08, duration - elapsed)
                : max(0.08, duration * weights[index] / totalWeight)
            defer {
                elapsed += unitDuration
                nextID += 1
            }
            return DesktopKaraokeWord(
                id: nextID,
                text: units[index],
                start: start + elapsed,
                duration: unitDuration
            )
        }
    }

    private static func displayUnits(from text: String) -> [String] {
        let characters = Array(text).map(String.init)
        var units: [String] = []
        var index = 0
        while index < characters.count {
            let start = index
            if isLatinWordCharacter(characters[index]) {
                index += 1
                while index < characters.count, isLatinWordCharacter(characters[index]) {
                    index += 1
                }
            } else if characters[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                while index < characters.count, characters[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    index += 1
                }
            } else {
                index += 1
            }
            units.append(characters[start..<index].joined())
        }
        return units
    }

    private static func timingWeight(for text: String) -> TimeInterval {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 0.35
        }
        if text.allSatisfy({ String($0).range(of: #"^[A-Za-z0-9'’_-]$"#, options: .regularExpression) != nil }) {
            return max(1, TimeInterval(text.count))
        }
        return max(1, TimeInterval(text.count))
    }

    private static func isLatinWordCharacter(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9'’_-]$"#, options: .regularExpression) != nil
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension DesktopLyricsAlignment {
    /// Preserve the lyric's reading start while the whole upcoming line grows.
    /// This is especially important for left- and right-aligned desktop lyrics.
    var scaleAnchor: UnitPoint {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}
