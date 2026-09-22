// Frozen pre-optimization renderer for pixel regression tests.
import AppKit
import CoreText
@testable import LyricShiori

@MainActor
final class ReferenceVerticalLyricTextView: NSView {
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
