import AppKit
import CoreText
import SwiftUI

/// Ruby and inline font-size runs need attributed CoreText drawing rather than
/// the uniform-font karaoke renderer. The source tree remains unchanged.
struct AppleMusicStyledText: NSViewRepresentable {
    var line: DesktopLyricsDisplayLine
    var fontSize: Double
    var pending: Color
    var played: Color
    var alignment: DesktopLyricsAlignment

    func makeNSView(context: Context) -> AppleMusicStyledTextView { AppleMusicStyledTextView() }
    func updateNSView(_ view: AppleMusicStyledTextView, context: Context) {
        view.line = line
        view.fontSize = fontSize
        view.pending = NSColor(pending)
        view.played = NSColor(played)
        view.alignment = alignment
        view.needsDisplay = true
    }
}

extension TimedTextElement {
    var needsAttributedRendering: Bool {
        attribute("ruby") != nil || attribute("fontSize") != nil
            || attribute("fontStyle") != nil || attribute("fontWeight") != nil
            || children.contains(where: \.needsAttributedRendering)
    }
}

final class AppleMusicStyledTextView: NSView {
    var line: DesktopLyricsDisplayLine?
    var fontSize: Double = 24
    var pending: NSColor = .white
    var played: NSColor = .cyan
    var alignment: DesktopLyricsAlignment = .left

    func attributedText(for line: DesktopLyricsDisplayLine) -> NSAttributedString {
        guard let element = line.presentation?.element else { return NSAttributedString(string: line.text) }
        let output = NSMutableAttributedString(string: "")
        func append(_ node: TimedTextElement, size: Double, italic: Bool, bold: Bool) {
            if node.attribute("role") == "x-bg", line.presentation?.isBackground != true { return }
            if ["text", "textContainer", "delimiter"].contains(node.attribute("ruby") ?? "") { return }
            var size = size
            if let value = node.attribute("fontSize") {
                if value.hasSuffix("%"), let percent = Double(value.dropLast()) { size *= percent / 100 }
                else if value.hasSuffix("px"), let pixels = Double(value.dropLast(2)) { size = pixels }
            }
            size = min(max(size, fontSize * 0.35), fontSize * 2)
            let italic = node.attribute("fontStyle").map { $0 == "italic" } ?? italic
            let bold = node.attribute("fontWeight").map { $0 == "bold" } ?? bold
            if let text = node.text {
                if text.allSatisfy(\.isWhitespace), text.contains("\n") { return }
                var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
                if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                output.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: line.isActive && line.wordTimings.isEmpty ? played : pending]))
                return
            }
            let start = output.length
            node.children.forEach { append($0, size: size, italic: italic, bold: bold) }
            let range = NSRange(location: start, length: output.length - start)
            if node.attribute("ruby") == "container", range.length > 0 {
                let reading = node.children.filter { ["text", "textContainer"].contains($0.attribute("ruby") ?? "") }.map(\.content).joined()
                if !reading.isEmpty {
                    let annotation = CTRubyAnnotationCreateWithAttributes(.auto, .auto, .before, reading as CFString,
                        [kCTRubyAnnotationSizeFactorAttributeName: 0.5] as CFDictionary)
                    output.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: annotation, range: range)
                }
            }
        }
        append(element, size: fontSize, italic: false, bold: line.isActive)
        guard output.length > 0 else { return output }
        // Replace only changed graphemes so ruby ranges and inline font sizes
        // keep their attributes. Whole-string mutation would collapse them.
        if output.string != line.text, output.string.count == line.text.count {
            var replacements: [(NSRange, String)] = []
            var offset = 0
            for (original, converted) in zip(output.string, line.text) {
                let originalText = String(original)
                let convertedText = String(converted)
                let length = originalText.utf16.count
                if originalText != convertedText, length == convertedText.utf16.count {
                    replacements.append((NSRange(location: offset, length: length), convertedText))
                }
                offset += length
            }
            for (range, text) in replacements.reversed() { output.replaceCharacters(in: range, with: text) }
        }
        return output
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let context = NSGraphicsContext.current?.cgContext else { return }
        let output = attributedText(for: line)
        guard output.length > 0 else { return }
        let ctLine = CTLineCreateWithAttributedString(output)
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        let x: CGFloat = alignment == .right ? max(0, bounds.width - width)
            : alignment == .center ? max(0, (bounds.width - width) / 2) : 0
        let y = max(0, (bounds.height - fontSize) / 2)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: NSColor.black.cgColor)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine, context)
        let filled = NSMutableAttributedString(attributedString: output)
        filled.addAttribute(.foregroundColor, value: played, range: NSRange(location: 0, length: filled.length))
        let playedLine = CTLineCreateWithAttributedString(filled)
        var cursor = 0
        let source = output.string as NSString
        for word in line.wordTimings {
            let range = source.range(of: word.text, range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound else { continue }
            cursor = NSMaxRange(range)
            let duration = max(0.001, word.duration ?? ((line.lineEnd ?? word.start + 1) - word.start))
            let progress = min(1, max(0, (line.playbackTime - word.start) / duration))
            guard progress > 0 else { continue }
            let left = CTLineGetOffsetForStringIndex(ctLine, range.location, nil)
            let right = CTLineGetOffsetForStringIndex(ctLine, NSMaxRange(range), nil)
            context.saveGState()
            context.clip(to: CGRect(x: x + left, y: 0, width: max(0, right - left) * progress, height: bounds.height))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(playedLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
