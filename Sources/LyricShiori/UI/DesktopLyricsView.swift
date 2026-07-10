import SwiftUI

struct DesktopLyricsView: View {
    @Bindable var store: LyricShioriStore
    @State private var mouseOverLyrics = false
    @State private var refreshTick = Date()

    private let refreshTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = refreshTick
        let lines = store.desktopLyricsDisplayLines()
        let palette = store.desktopLyricsPalette()
        let fontSize = store.settings.desktopLyricsFontSize
        let alignment = store.settings.desktopLyricsAlignment

        VStack(alignment: alignment.horizontalAlignment, spacing: max(6, fontSize * 0.18)) {
            ForEach(lines) { line in
                DesktopLyricLineView(
                    line: line,
                    palette: palette,
                    fontSize: fontSize,
                    alignment: alignment
                )
                .id(line.id)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: line.distanceFromActive < 0 ? .top : .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    )
                )
            }
        }
        .padding(.horizontal, max(8, fontSize * 0.35))
        .padding(.vertical, max(4, fontSize * 0.16))
        .frame(maxWidth: .infinity)
        .opacity(store.settings.hideLyricsWhenMousePassingBy && mouseOverLyrics ? 0 : 1)
        .animation(.easeOut(duration: 0.10), value: store.currentLineIndex)
        .animation(.easeInOut(duration: 0.22), value: mouseOverLyrics)
        .onReceive(refreshTimer) { date in
            refreshTick = date
            store.updateCurrentLine()
        }
        .onHover { mouseOverLyrics = $0 }
    }
}

private struct DesktopLyricLineView: View {
    var line: DesktopLyricsDisplayLine
    var palette: DesktopLyricsPalette
    var fontSize: Double
    var alignment: DesktopLyricsAlignment

    var body: some View {
        DesktopLyricText(
            line: line,
            pendingColor: line.isActive ? palette.pending : palette.secondary.opacity(0.56),
            playedColor: line.isActive ? palette.played : palette.secondary,
            shadowColor: palette.shadow.opacity(line.isActive ? 0.70 : 0.42),
            fontSize: lineFontSize,
            fontWeight: line.isActive ? .semibold : .regular,
            alignment: alignment
        )
        .opacity(opacity)
        .scaleEffect(scale)
        .blur(radius: blurRadius)
        .animation(.easeOut(duration: 0.08), value: line.isActive)
    }

    private var opacity: Double {
        line.isActive ? 1.0 : max(0.34, 0.70 - Double(abs(line.distanceFromActive) - 1) * 0.14)
    }

    private var scale: Double {
        line.isActive ? 1.0 : max(0.92, 0.98 - Double(abs(line.distanceFromActive) - 1) * 0.03)
    }

    private var blurRadius: Double {
        line.isActive ? 0 : min(1.2, Double(abs(line.distanceFromActive)) * 0.18)
    }

    private var lineFontSize: Double {
        if line.isActive {
            return fontSize
        }
        return max(11, fontSize * 0.75)
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
        if line.isActive, let words = karaokeWords, !words.isEmpty {
            KaraokeDesktopLyricText(
                words: words,
                playbackTime: line.playbackTime,
                pendingColor: pendingColor,
                playedColor: playedColor,
                shadowColor: shadowColor,
                fontSize: fontSize,
                fontWeight: fontWeight,
                alignment: alignment,
                scrollProgress: line.progress
            )
        } else {
            PlainDesktopLyricText(
                text: line.text,
                textColor: line.isActive ? playedColor : pendingColor,
                shadowColor: shadowColor,
                fontSize: fontSize,
                fontWeight: fontWeight,
                alignment: alignment,
                scrollProgress: line.progress
            )
        }
    }

    private var karaokeWords: [DesktopKaraokeWord]? {
        DesktopKaraokeWord.words(
            text: line.text,
            timings: line.wordTimings,
            lineStart: line.lineStart,
            lineEnd: line.lineEnd
        )
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
            progress: scrollProgress,
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
            .shadow(color: shadowColor, radius: fontSize * 0.12, x: 0, y: fontSize * 0.04)
            .lineLimit(1)
            .multilineTextAlignment(alignment.textAlignment)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PlainDesktopLyricText: View {
    var text: String
    var textColor: Color
    var shadowColor: Color
    var fontSize: Double
    var fontWeight: Font.Weight
    var alignment: DesktopLyricsAlignment
    var scrollProgress: Double

    var body: some View {
        HorizontalScrollingLine(
            alignment: alignment,
            progress: scrollProgress,
            height: max(fontSize * 1.35, 24)
        ) {
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight, design: .default))
                .foregroundStyle(textColor)
                .shadow(color: shadowColor, radius: fontSize * 0.12, x: 0, y: fontSize * 0.04)
                .lineLimit(1)
                .multilineTextAlignment(alignment.textAlignment)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct KaraokeDesktopLyricText: View {
    var words: [DesktopKaraokeWord]
    var playbackTime: TimeInterval
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
            progress: scrollProgress,
            height: max(fontSize * 1.35, 24)
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(words) { word in
                    KaraokeDesktopWordView(
                        word: word,
                        playbackTime: playbackTime,
                        pendingColor: pendingColor,
                        playedColor: playedColor,
                        shadowColor: shadowColor,
                        fontSize: fontSize,
                        fontWeight: fontWeight
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct HorizontalScrollingLine<Content: View>: View {
    var alignment: DesktopLyricsAlignment
    var progress: Double
    var height: CGFloat
    @ViewBuilder var content: Content
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let overflow = max(0, contentWidth - viewportWidth)
            let xOffset = overflow > 1 ? -overflow * scrollPhase : 0

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

    private var scrollPhase: CGFloat {
        let clamped = min(max(progress, 0), 1)
        let startHold = 0.12
        let endHold = 0.12
        let moving = max(0.01, 1 - startHold - endHold)
        return CGFloat(min(max((clamped - startHold) / moving, 0), 1))
    }
}

private struct DesktopLineWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WrappingKaraokeLayout: Layout {
    var alignment: DesktopLyricsAlignment
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + xOffset(for: row.width, in: bounds.width)
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat?) -> [Row] {
        let availableWidth = maxWidth ?? .greatestFiniteMagnitude
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let shouldWrap = !current.items.isEmpty && current.width + size.width > availableWidth
            if shouldWrap {
                rows.append(current)
                current = Row()
            }
            current.items.append(.init(index: index, size: size))
            current.width += size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private func xOffset(for rowWidth: CGFloat, in availableWidth: CGFloat) -> CGFloat {
        switch alignment {
        case .left:
            return 0
        case .center:
            return max(0, (availableWidth - rowWidth) / 2)
        case .right:
            return max(0, availableWidth - rowWidth)
        }
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct Item {
        var index: Int
        var size: CGSize
    }
}

private struct KaraokeDesktopWordView: View {
    var word: DesktopKaraokeWord
    var playbackTime: TimeInterval
    var pendingColor: Color
    var playedColor: Color
    var shadowColor: Color
    var fontSize: Double
    var fontWeight: Font.Weight

    var body: some View {
        let state = visualState
        Text(word.text)
            .font(.system(size: fontSize, weight: fontWeight, design: .default))
            .foregroundStyle(state.progress >= 1 ? playedColor : pendingColor)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Text(word.text)
                        .font(.system(size: fontSize, weight: fontWeight, design: .default))
                        .foregroundStyle(playedColor)
                        .frame(width: proxy.size.width, alignment: .leading)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: proxy.size.width * min(max(state.progress, 0), 1))
                        }
                }
                .allowsHitTesting(false)
            }
            .shadow(color: shadowColor.opacity(0.35 + 0.65 * state.glow), radius: fontSize * (0.10 + 0.30 * state.glow), x: 0, y: fontSize * 0.03)
            .offset(y: fontSize * state.liftEm)
            .fixedSize(horizontal: true, vertical: false)
            .animation(.linear(duration: 0.016), value: state.progress)
    }

    private var visualState: (progress: Double, glow: Double, liftEm: Double) {
        let elapsed = playbackTime - word.start
        let activeDuration = max(0.08, word.duration)
        let rawProgress = elapsed / activeDuration
        let progress = min(max(rawProgress, 0), 1)
        let releaseDuration = max(0.7, min(1.2, activeDuration * 1.6))
        let releaseProgress = min(max((elapsed - activeDuration) / releaseDuration, 0), 1)
        let activeEase = smooth(progress)
        let releaseEase = smooth(releaseProgress)
        let activeGlow = word.peakGlow * progress
        let releaseGlow = word.peakGlow * (1 - releaseEase)
        let glow = rawProgress < 1 ? activeGlow : max(0, releaseGlow)
        let lift = rawProgress <= 0 ? 0 : 0.05 + (-0.07 - 0.05) * (rawProgress < 1 ? activeEase : 1)
        return (progress, glow, lift)
    }

    private func smooth(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
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
