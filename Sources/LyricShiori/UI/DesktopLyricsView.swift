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

        VStack(spacing: max(6, fontSize * 0.18)) {
            ForEach(lines) { line in
                DesktopLyricLineView(
                    line: line,
                    palette: palette,
                    fontSize: fontSize
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
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: store.currentLineIndex)
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

    var body: some View {
        ProgressiveDesktopLyricText(
            text: line.text,
            progress: line.progress,
            pendingColor: line.isActive ? palette.pending : palette.secondary.opacity(0.56),
            playedColor: line.isActive ? palette.played : palette.secondary,
            shadowColor: palette.shadow.opacity(line.isActive ? 0.70 : 0.42),
            fontSize: line.isActive ? fontSize : max(12, fontSize * 0.70),
            fontWeight: line.isActive ? .semibold : .regular
        )
        .opacity(opacity)
        .scaleEffect(scale)
        .blur(radius: blurRadius)
        .animation(.easeInOut(duration: 0.34), value: line.isActive)
    }

    private var opacity: Double {
        line.isActive ? 1.0 : max(0.34, 0.70 - Double(abs(line.distanceFromActive) - 1) * 0.14)
    }

    private var scale: Double {
        line.isActive ? 1.0 : max(0.88, 0.94 - Double(abs(line.distanceFromActive) - 1) * 0.03)
    }

    private var blurRadius: Double {
        line.isActive ? 0 : min(1.2, Double(abs(line.distanceFromActive)) * 0.18)
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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                lyricText
                    .foregroundStyle(pendingColor)
                lyricText
                    .foregroundStyle(playedColor)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: proxy.size.width * min(max(progress, 0), 1))
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: max(fontSize * 1.35, 24))
    }

    private var lyricText: some View {
        Text(text)
            .font(.system(size: fontSize, weight: fontWeight, design: .default))
            .shadow(color: shadowColor, radius: fontSize * 0.12, x: 0, y: fontSize * 0.04)
            .lineLimit(2)
            .minimumScaleFactor(0.62)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
