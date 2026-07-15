import AppKit
import CoreText
import SwiftUI

/// Core Text vertical layout matching the mixed-orientation behavior used by
/// East Asian word processors: CJK glyphs remain upright, punctuation selects
/// the font's `vert` alternate, and Western text runs are set sideways.
struct WordVerticalLyricText: NSViewRepresentable {
    var line: DesktopLyricsDisplayLine
    var playbackTime: TimeInterval
    var pendingColor: Color
    var playedColor: Color
    var secondaryColor: Color
    var shadowColor: Color
    var fontSize: Double
    var alignment: DesktopLyricsAlignment

    func makeNSView(context: Context) -> WordVerticalLyricTextView {
        let view = WordVerticalLyricTextView()
        update(view)
        return view
    }

    func updateNSView(_ view: WordVerticalLyricTextView, context: Context) {
        update(view)
    }

    private func update(_ view: WordVerticalLyricTextView) {
        view.configure(
            line: line,
            playbackTime: playbackTime,
            pendingColor: NSColor(pendingColor),
            playedColor: NSColor(playedColor),
            secondaryColor: NSColor(secondaryColor),
            shadowColor: NSColor(shadowColor),
            fontSize: fontSize,
            alignment: alignment
        )
    }
}

@MainActor
final class WordVerticalLyricTextView: NSView {
    private var configuration: Configuration?

    override var isOpaque: Bool { false }

    func configure(
        line: DesktopLyricsDisplayLine,
        playbackTime: TimeInterval,
        pendingColor: NSColor,
        playedColor: NSColor,
        secondaryColor: NSColor,
        shadowColor: NSColor,
        fontSize: Double,
        alignment: DesktopLyricsAlignment
    ) {
        configuration = Configuration(
            line: line,
            playbackTime: playbackTime,
            pendingColor: pendingColor,
            playedColor: playedColor,
            secondaryColor: secondaryColor,
            shadowColor: shadowColor,
            fontSize: fontSize,
            alignment: alignment
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let configuration,
              !configuration.line.text.isEmpty,
              bounds.width > 0,
              bounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let units = WordVerticalTypesetter.layoutUnits(
            for: configuration.line,
            fontSize: configuration.fontSize
        )
        let contentHeight = max(1, units.reduce(0) { $0 + $1.advance })
        let overflow = max(0, contentHeight - bounds.height)
        let contentBottom: CGFloat
        if overflow > 1 {
            contentBottom = bounds.height - contentHeight
                + overflow * scrollPhase(configuration: configuration)
        } else {
            switch configuration.alignment {
            case .left:
                contentBottom = bounds.height - contentHeight
            case .center:
                contentBottom = (bounds.height - contentHeight) / 2
            case .right:
                contentBottom = 0
            }
        }

        context.saveGState()
        context.textMatrix = .identity
        context.clip(to: bounds)
        var offsetFromTop: CGFloat = 0
        for unit in units {
            let unitBottom = contentBottom + contentHeight - offsetFromTop - unit.advance
            draw(
                unit,
                bottom: unitBottom,
                configuration: configuration,
                context: context
            )
            offsetFromTop += unit.advance
        }
        context.restoreGState()
    }

    private func draw(
        _ unit: WordVerticalTypesetter.LayoutUnit,
        bottom: CGFloat,
        configuration: Configuration,
        context: CGContext
    ) {
        guard !unit.isWhitespace else { return }
        let rect = CGRect(x: 0, y: bottom, width: bounds.width, height: unit.advance)
        let progress = unit.timing.map {
            min(max((configuration.playbackTime - $0.start) / max(0.08, $0.duration), 0), 1)
        }

        context.saveGState()
        if configuration.line.isActive, let progress {
            let transform = WordVerticalTypesetter.karaokeTransform(
                progress: progress,
                fontSize: configuration.fontSize
            )
            let center = CGPoint(x: rect.midX, y: rect.midY)
            // These are the exact scale/lift curves used by the original
            // SwiftUI glyph stack. Core Graphics uses an upward-positive Y axis.
            context.translateBy(x: 0, y: transform.lift)
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: transform.scale, y: transform.scale)
            context.translateBy(x: -center.x, y: -center.y)
            draw(
                unit.attributedText,
                color: configuration.pendingColor,
                alpha: 1,
                in: rect,
                configuration: configuration,
                context: context
            )
            draw(
                unit.attributedText,
                color: configuration.playedColor,
                alpha: CGFloat(progress),
                in: rect,
                configuration: configuration,
                context: context
            )
        } else {
            draw(
                unit.attributedText,
                color: configuration.line.isActive
                    ? configuration.playedColor
                    : configuration.secondaryColor,
                alpha: 1,
                in: rect,
                configuration: configuration,
                context: context
            )
        }
        context.restoreGState()
    }

    private func draw(
        _ attributedText: NSAttributedString,
        color: NSColor,
        alpha: CGFloat,
        in rect: CGRect,
        configuration: Configuration,
        context: CGContext
    ) {
        let coloredText = NSMutableAttributedString(attributedString: attributedText)
        coloredText.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: 0, length: coloredText.length)
        )
        let framesetter = CTFramesetterCreateWithAttributedString(coloredText)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: rect, transform: nil),
            [
                kCTFrameProgressionAttributeName: NSNumber(value: CTFrameProgression.rightToLeft.rawValue),
            ] as CFDictionary
        )

        context.saveGState()
        context.setAlpha(alpha)
        context.setShadow(
            offset: CGSize(width: 0, height: -configuration.fontSize * 0.025),
            blur: configuration.fontSize * 0.065,
            color: configuration.shadowColor.withAlphaComponent(
                configuration.line.isActive ? 0.42 : 0.28
            ).cgColor
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func scrollPhase(configuration: Configuration) -> CGFloat {
        let line = configuration.line
        let rawProgress: Double
        if let lineEnd = line.lineEnd, lineEnd > line.lineStart {
            rawProgress = (configuration.playbackTime - line.lineStart) / (lineEnd - line.lineStart)
        } else {
            rawProgress = line.progress
        }
        let progress = min(max(rawProgress, 0), 1)
        guard let lineEnd = line.lineEnd else { return CGFloat(progress) }
        let duration = lineEnd - line.lineStart
        guard duration > 0.2 else { return CGFloat(progress) }

        let startHold = min(0.45, max(0.18, duration * 0.10))
        let endHold = min(0.65, max(0.20, duration * 0.08))
        let movingDuration = max(0.12, duration - startHold - endHold)
        let currentTime = progress * duration
        return CGFloat(min(max((currentTime - startHold) / movingDuration, 0), 1))
    }

    private struct Configuration {
        var line: DesktopLyricsDisplayLine
        var playbackTime: TimeInterval
        var pendingColor: NSColor
        var playedColor: NSColor
        var secondaryColor: NSColor
        var shadowColor: NSColor
        var fontSize: Double
        var alignment: DesktopLyricsAlignment
    }
}

enum WordVerticalTypesetter {
    private static let verticalFormsKey = NSAttributedString.Key(
        rawValue: kCTVerticalFormsAttributeName as String
    )

    static func attributedString(
        for line: DesktopLyricsDisplayLine,
        playbackTime: TimeInterval,
        pendingColor: NSColor,
        playedColor: NSColor,
        secondaryColor: NSColor,
        fontSize: Double
    ) -> NSAttributedString {
        let baseColor = line.isActive ? playedColor : secondaryColor
        let output = baseAttributedString(
            for: line,
            fontSize: fontSize,
            color: baseColor
        )
        let timings = characterTimings(for: line)

        let characterRanges = line.text.indicesWithRanges
        for (index, range) in characterRanges.enumerated() {
            let nsRange = NSRange(range, in: line.text)
            guard line.isActive, timings.indices.contains(index) else { continue }
            let timing = timings[index]
            let progress = min(
                max((playbackTime - timing.start) / max(0.08, timing.duration), 0),
                1
            )
            output.addAttribute(
                .foregroundColor,
                value: blendedColor(from: pendingColor, to: playedColor, progress: progress),
                range: nsRange
            )
        }
        return output
    }

    static func layoutUnits(
        for line: DesktopLyricsDisplayLine,
        fontSize: Double
    ) -> [LayoutUnit] {
        let attributedText = baseAttributedString(
            for: line,
            fontSize: fontSize,
            color: .white
        )
        let characterRanges = line.text.indicesWithRanges
        let characters = characterRanges.compactMap { line.text[$0].first }
        let timings = characterTimings(for: line)

        return displayUnitRanges(in: characters).map { range in
            let stringRange = characterRanges[range.lowerBound].lowerBound..<characterRanges[range.upperBound - 1].upperBound
            let attributedRange = NSRange(stringRange, in: line.text)
            let text = attributedText.attributedSubstring(from: attributedRange)
            return LayoutUnit(
                attributedText: text,
                advance: unitAdvance(of: text),
                timing: timing(for: range, in: timings),
                isWhitespace: characters[range].allSatisfy { $0.isWhitespace }
            )
        }
    }

    static func karaokeTransform(
        progress: Double,
        fontSize: Double
    ) -> (scale: CGFloat, lift: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        let peak = sin(.pi * clamped)
        return (
            scale: CGFloat(1 + 0.08 * peak),
            lift: CGFloat(fontSize * 0.065 * peak)
        )
    }

    struct LayoutUnit {
        var attributedText: NSAttributedString
        var advance: CGFloat
        var timing: CharacterTiming?
        var isWhitespace: Bool
    }

    struct CharacterTiming {
        var start: TimeInterval
        var duration: TimeInterval
    }

    private static func baseAttributedString(
        for line: DesktopLyricsDisplayLine,
        fontSize: Double,
        color: NSColor
    ) -> NSMutableAttributedString {
        let font = verticalFont(for: line.text, fontSize: fontSize, emphasized: line.isActive)
        let output = NSMutableAttributedString(
            string: line.text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                verticalFormsKey: true,
            ]
        )
        let characterRanges = line.text.indicesWithRanges
        let characters = characterRanges.compactMap { line.text[$0].first }
        for (index, range) in characterRanges.enumerated() {
            guard characters.indices.contains(index) else { continue }
            output.addAttribute(
                verticalFormsKey,
                value: usesVerticalGlyphForm(
                    characters[index],
                    previous: index > 0 ? characters[index - 1] : nil,
                    next: characters.indices.contains(index + 1) ? characters[index + 1] : nil
                ) as NSNumber,
                range: NSRange(range, in: line.text)
            )
        }
        return output
    }

    static func usesVerticalGlyphForm(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars.filter {
            !$0.properties.isJoinControl && !$0.properties.isVariationSelector
        }
        guard let base = scalars.first else { return true }

        // ASCII and non-East-Asian alphabetic/numeric text stays on its normal
        // baseline. The vertical frame rotates that baseline as one continuous
        // Western run, preserving Word-like word spacing and punctuation.
        if base.isASCII { return false }
        if CharacterSet.letters.contains(base) || CharacterSet.decimalDigits.contains(base) {
            return isEastAsian(base)
        }
        return true
    }

    private static func usesVerticalGlyphForm(
        _ character: Character,
        previous: Character?,
        next: Character?
    ) -> Bool {
        guard usesVerticalGlyphForm(character) else { return false }
        guard character.unicodeScalars.allSatisfy({ contextualWesternPunctuation.contains($0.value) }) else {
            return true
        }
        // Smart quotes, dashes, and ellipses follow a neighboring Western word
        // when used as its punctuation, but keep their vertical CJK form in a
        // Chinese/Japanese phrase.
        return ![previous, next].compactMap { $0 }.contains(where: isWesternLetterOrDigit)
    }

    private static let contextualWesternPunctuation: ClosedRange<UInt32> = 0x2010...0x2026

    private static func isWesternLetterOrDigit(_ character: Character) -> Bool {
        guard let base = character.unicodeScalars.first else { return false }
        let isLetterOrDigit = CharacterSet.letters.contains(base)
            || CharacterSet.decimalDigits.contains(base)
        return isLetterOrDigit && !isEastAsian(base)
    }

    static func advance(of attributedText: NSAttributedString) -> CGFloat {
        guard attributedText.length > 0 else { return 1 }
        let line = CTLineCreateWithAttributedString(attributedText)
        return max(1, CGFloat(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 1))
    }

    private static func unitAdvance(of attributedText: NSAttributedString) -> CGFloat {
        guard attributedText.length > 0 else { return 1 }
        let line = CTLineCreateWithAttributedString(attributedText)
        return max(1, CGFloat(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))))
    }

    private static func displayUnitRanges(in characters: [Character]) -> [Range<Int>] {
        var output: [Range<Int>] = []
        var index = 0
        while index < characters.count {
            let start = index
            index += 1
            // Preserve the original animation unit boundaries exactly: ASCII
            // Latin letters animate as one word; every other character,
            // including digits and punctuation, animates independently.
            if isASCIILatinLetter(characters[start]) {
                while index < characters.count, isASCIILatinLetter(characters[index]) {
                    index += 1
                }
            }
            output.append(start..<index)
        }
        return output
    }

    private static func isASCIILatinLetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func timing(
        for range: Range<Int>,
        in timings: [CharacterTiming]
    ) -> CharacterTiming? {
        let values = range.compactMap { timings.indices.contains($0) ? timings[$0] : nil }
        guard let first = values.first, let last = values.last else { return nil }
        return CharacterTiming(
            start: first.start,
            duration: last.start + last.duration - first.start
        )
    }

    /// SF Pro does not contain the vertical metrics Core Text requires to
    /// construct a vertical frame. Start with the matching macOS CJK family;
    /// Core Text still performs normal font fallback for missing characters.
    private static func verticalFont(
        for text: String,
        fontSize: Double,
        emphasized: Bool
    ) -> NSFont {
        let scalars = text.unicodeScalars
        let fontName: String
        if scalars.contains(where: { (0xAC00...0xD7FF).contains($0.value) }) {
            fontName = emphasized ? "AppleSDGothicNeo-SemiBold" : "AppleSDGothicNeo-Regular"
        } else if scalars.contains(where: {
            (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value)
        }) {
            fontName = emphasized ? "HiraginoSans-W6" : "HiraginoSans-W3"
        } else {
            fontName = emphasized ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        }
        return NSFont(name: fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: emphasized ? .semibold : .regular)
    }

    private static func isEastAsian(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FFF, // CJK radicals and ideographic punctuation
             0x3040...0x30FF, // Hiragana and Katakana
             0x3100...0x31FF, // Bopomofo and Katakana extensions
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xA960...0xA97F, // Hangul Jamo Extended-A
             0xAC00...0xD7FF, // Hangul syllables and Jamo
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFE10...0xFE1F, // Vertical presentation forms
             0xFE30...0xFE4F, // CJK compatibility forms
             0xFF00...0xFFEF, // Fullwidth and halfwidth forms
             0x20000...0x323AF: // CJK extensions B through I
            true
        default:
            false
        }
    }

    private static func characterTimings(for line: DesktopLyricsDisplayLine) -> [CharacterTiming] {
        guard let words = DesktopKaraokeWord.words(
            text: line.text,
            timings: line.wordTimings,
            lineStart: line.lineStart,
            lineEnd: line.lineEnd
        ) else {
            return []
        }
        return words.flatMap { word in
            let count = word.text.count
            guard count > 0 else { return [CharacterTiming]() }
            let duration = word.duration / Double(count)
            return (0..<count).map { index in
                CharacterTiming(
                    start: word.start + duration * Double(index),
                    duration: duration
                )
            }
        }
    }

    private static func blendedColor(
        from start: NSColor,
        to end: NSColor,
        progress: Double
    ) -> NSColor {
        start.blended(withFraction: progress, of: end) ?? (progress < 0.5 ? start : end)
    }

}

private extension Character {
    var isWhitespace: Bool {
        unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }
}

private extension String {
    var indicesWithRanges: [Range<String.Index>] {
        indices.map { index in
            index..<self.index(after: index)
        }
    }
}
