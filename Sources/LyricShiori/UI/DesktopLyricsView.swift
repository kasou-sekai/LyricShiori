import SwiftUI

struct DesktopLyricsView: View {
    @Bindable var store: LyricShioriStore
    @State private var mouseOverLyrics = false

    var body: some View {
        let lines = store.desktopLyricsLines()

        VStack(spacing: 8) {
            ProgressiveLyricText(
                text: lines.first,
                progress: store.currentLineProgress(),
                fontName: store.settings.desktopLyricsFontName,
                fontSize: store.settings.desktopLyricsFontSize,
                textColor: store.settings.desktopLyricsColor,
                progressColor: store.settings.desktopLyricsProgressColor,
                shadowColor: store.settings.desktopLyricsShadowColor
            )
            if !lines.second.isEmpty {
                Text(lines.second)
                    .font(.custom(store.settings.desktopLyricsFontName, size: max(12, store.settings.desktopLyricsFontSize * 0.66)))
                    .foregroundStyle(store.settings.desktopLyricsColor.opacity(0.82))
                    .shadow(color: store.settings.desktopLyricsShadowColor.opacity(0.7), radius: 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, max(18, store.settings.desktopLyricsFontSize))
        .padding(.vertical, max(10, store.settings.desktopLyricsFontSize / 3))
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: max(8, store.settings.desktopLyricsFontSize / 2))
                .fill(store.settings.desktopLyricsBackgroundColor)
        }
        .opacity(store.settings.hideLyricsWhenMousePassingBy && mouseOverLyrics ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: mouseOverLyrics)
        .onHover { mouseOverLyrics = $0 }
    }
}

private struct ProgressiveLyricText: View {
    var text: String
    var progress: Double
    var fontName: String
    var fontSize: Double
    var textColor: Color
    var progressColor: Color
    var shadowColor: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                lyricText
                    .foregroundStyle(textColor)
                lyricText
                    .foregroundStyle(progressColor)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: proxy.size.width * progress)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: max(fontSize * 1.35, 30))
    }

    private var lyricText: some View {
        Text(text)
            .font(.custom(fontName, size: fontSize))
            .shadow(color: shadowColor, radius: 4)
            .lineLimit(2)
            .minimumScaleFactor(0.65)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
