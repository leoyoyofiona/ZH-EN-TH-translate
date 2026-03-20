import SwiftUI
import AppKit
#if canImport(OfflineInterpreterKit)
import OfflineInterpreterKit
#endif

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let contentScale = windowScale(for: geometry.size)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(
                                Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.12), radius: 28, x: 0, y: 16)

                VStack(spacing: scaled(12, by: contentScale)) {
                    controls(scale: contentScale)
                    subtitles
                    footer(scale: contentScale)
                }
                .padding(scaled(14, by: contentScale))
            }
            .padding(14)
        }
        .frame(minWidth: 760, minHeight: 340)
        .background(Color.clear)
        .background(WindowAccessor())
        .alert("运行错误", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.dismissError()
                }
            }
        )) {
            Button("继续翻译", role: .cancel) {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
    }

    private func controls(scale: CGFloat) -> some View {
        VStack(spacing: scaled(10, by: scale)) {
            HStack(spacing: scaled(12, by: scale)) {
                Picker("音频", selection: $viewModel.audioSource) {
                    Text("系统音频").tag(AudioSourceKind.systemAudio)
                    Text("麦克风").tag(AudioSourceKind.microphone)
                }
                .pickerStyle(.segmented)
                .frame(width: 190 * scale)
                .onChange(of: viewModel.audioSource) { _, _ in
                    viewModel.handleAudioSourceChanged()
                }

                compactMenuPicker(
                    title: "源语言",
                    selection: Binding(
                        get: { viewModel.selectedSourceLanguage },
                        set: { viewModel.configureSourceLanguage($0) }
                    ),
                    scale: scale
                )

                compactMenuPicker(
                    title: "目标语言",
                    selection: Binding(
                        get: { viewModel.targetLanguage },
                        set: { viewModel.configureTargetLanguage($0) }
                    ),
                    disabledLanguage: viewModel.selectedSourceLanguage,
                    scale: scale
                )

                Spacer(minLength: scaled(8, by: scale))

                Button("清空") {
                    viewModel.clearSubtitles()
                }
                .buttonStyle(.bordered)

                Menu("导出") {
                    Button("导出 Word (.docx)") {
                        viewModel.exportTranscript(as: .word)
                    }
                    Button("导出 TXT (.txt)") {
                        viewModel.exportTranscript(as: .txt)
                    }
                    Button("导出 Markdown (.md)") {
                        viewModel.exportTranscript(as: .markdown)
                    }
                }

                Button(viewModel.isRunning ? "停止" : "开始") {
                    viewModel.startOrStop()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: scaled(12, by: scale)) {
                compactColorPicker(title: "原文颜色", selection: $viewModel.sourceSubtitleColorStyle, scale: scale)
                compactColorPicker(title: "译文颜色", selection: $viewModel.translationSubtitleColorStyle, scale: scale)

                Stepper(
                    "原文 \(Int(viewModel.sourceFontSize))",
                    value: $viewModel.sourceFontSize,
                    in: 14...34,
                    step: 1
                )
                .frame(width: 124 * scale)

                Stepper(
                    "译文 \(Int(viewModel.translationFontSize))",
                    value: $viewModel.translationFontSize,
                    in: 18...42,
                    step: 1
                )
                .frame(width: 124 * scale)

                Spacer()
            }
        }
        .controlSize(scale < 0.84 ? .small : .regular)
        .padding(.horizontal, scaled(14, by: scale))
        .padding(.vertical, scaled(10, by: scale))
        .background(panelBackground(cornerRadius: 18))
    }

    private func compactMenuPicker(
        title: String,
        selection: Binding<SupportedLanguage>,
        disabledLanguage: SupportedLanguage? = nil,
        scale: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker(title, selection: selection) {
                ForEach(SupportedLanguage.allCases) { language in
                    Text(language.displayName)
                        .tag(language)
                        .disabled(language == disabledLanguage)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 132 * scale)
        }
    }

    private func compactColorPicker(
        title: String,
        selection: Binding<SubtitleColorStyle>,
        scale: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker(title, selection: selection) {
                ForEach(SubtitleColorStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 116 * scale)
        }
    }

    private var subtitles: some View {
        HSplitView {
            transcriptPane(
                title: "原文（\(viewModel.selectedSourceLanguage.displayName)）",
                segments: viewModel.displayedSegments,
                placeholder: "Waiting for audio...",
                text: \.sourceText,
                fontSize: viewModel.sourceFontSize,
                color: sourceColor
            )
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)

            transcriptPane(
                title: "译文（\(viewModel.targetLanguage.displayName)）",
                segments: viewModel.displayedSegments,
                placeholder: "等待翻译...",
                text: \.translatedText,
                fontSize: viewModel.translationFontSize,
                color: translationColor
            )
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptPane(
        title: String,
        segments: [TranslationSegment],
        placeholder: String,
        text: KeyPath<TranslationSegment, String>,
        fontSize: Double,
        color: Color
    ) -> some View {
        GeometryReader { geometry in
            let effectiveFontSize = adaptiveFontSize(base: fontSize, containerSize: geometry.size)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if segments.isEmpty {
                                Text(placeholder)
                                    .font(.system(size: effectiveFontSize, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: max(geometry.size.width - 16, 0), alignment: .leading)
                            } else {
                                ForEach(segments) { segment in
                                    Text(segment[keyPath: text])
                                        .font(.system(size: effectiveFontSize, weight: .semibold, design: .default))
                                        .foregroundStyle(color)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(width: max(geometry.size.width - 16, 0), alignment: .leading)
                                        .textSelection(.enabled)
                                        .opacity(segment.isStable ? 1 : 0.76)
                                        .id(segment.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        scrollToBottom(in: proxy, segments: segments)
                    }
                    .onChange(of: viewModel.transcriptRevision) { _, _ in
                        scrollToBottom(in: proxy, segments: segments)
                    }
                }
            }
            .padding(14)
            .background(panelBackground(cornerRadius: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if viewModel.canOpenSettings {
                    Button("打开权限设置") {
                        viewModel.openRelevantSettings()
                    }
                    .buttonStyle(.borderless)
                }

                Text("输入：\(viewModel.audioSourceDisplayName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(viewModel.compactStatusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if viewModel.latencyMilliseconds > 0 {
                    Text("· \(viewModel.latencyMilliseconds) ms")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(viewModel.translationDirectionStatusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(viewModel.sourceRecognitionStatusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, scaled(14, by: scale))
        .padding(.vertical, scaled(10, by: scale))
        .background(panelBackground(cornerRadius: 18))
    }

    private func scrollToBottom(in proxy: ScrollViewProxy, segments: [TranslationSegment]) {
        guard let lastID = segments.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private var sourceColor: Color {
        switch viewModel.sourceSubtitleColorStyle {
        case .system:
            return Color(nsColor: .secondaryLabelColor)
        case .black:
            return .black
        case .white:
            return .white
        case .yellow:
            return .yellow
        case .cyan:
            return .cyan
        case .magenta:
            return .pink
        case .red:
            return .red
        case .orange:
            return .orange
        case .green:
            return .green
        case .blue:
            return .blue
        case .indigo:
            return .indigo
        }
    }

    private var translationColor: Color {
        switch viewModel.translationSubtitleColorStyle {
        case .system:
            return Color(nsColor: .labelColor)
        case .black:
            return .black
        case .white:
            return .white
        case .yellow:
            return .yellow
        case .cyan:
            return .cyan
        case .magenta:
            return .pink
        case .red:
            return .red
        case .orange:
            return .orange
        case .green:
            return .green
        case .blue:
            return .blue
        case .indigo:
            return .indigo
        }
    }

    private func adaptiveFontSize(base: Double, containerSize: CGSize) -> Double {
        let widthScale = containerSize.width / 520
        let heightScale = containerSize.height / 320
        let scale = min(max(min(widthScale, heightScale), 0.72), 1.35)
        return max(12, base * scale)
    }

    private func windowScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / 1180
        let heightScale = size.height / 560
        return min(max(min(widthScale, heightScale), 0.72), 1.22)
    }

    private func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
        value * scale
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.thinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                        lineWidth: 1
                    )
            )
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            OverlayWindowConfigurator.configure(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            OverlayWindowConfigurator.configure(window: window)
        }
    }
}

@MainActor
private enum OverlayWindowConfigurator {
    private static var configuredWindows = Set<ObjectIdentifier>()

    static func configure(window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard !configuredWindows.contains(identifier) else { return }
        configuredWindows.insert(identifier)

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.titled)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 760, height: 340)

        if let screen = window.screen ?? NSScreen.main {
            let width: CGFloat = 1180
            let height: CGFloat = 560
            let origin = CGPoint(
                x: screen.frame.midX - width / 2,
                y: screen.visibleFrame.minY + 36
            )
            window.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        }
    }
}
