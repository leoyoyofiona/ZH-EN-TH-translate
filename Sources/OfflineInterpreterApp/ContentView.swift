import SwiftUI
import AppKit
@preconcurrency import Translation
#if canImport(OfflineInterpreterKit)
import OfflineInterpreterKit
#endif

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("windowPinned") private var keepWindowPinned = false
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var activePreparationID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let contentScale = windowScale(for: geometry.size)
            let toolbarScale = toolbarScale(for: geometry.size)

            VStack(spacing: scaled(10, by: contentScale)) {
                controls(scale: toolbarScale)
                if let preparationStatusText = viewModel.preparationStatusText {
                    translationPreparationBanner(text: preparationStatusText, scale: contentScale)
                }
                subtitles
                footer(scale: contentScale)
            }
            .padding(scaled(12, by: contentScale))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(windowBackground)
        }
        .frame(minWidth: 920, minHeight: 300)
        .background(windowBackground)
        .background(WindowAccessor(isPinned: keepWindowPinned))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if keepWindowPinned {
                    Button("取消置顶") {
                        keepWindowPinned.toggle()
                    }
                } else {
                    Button("置顶") {
                        keepWindowPinned.toggle()
                    }
                }

                Button("清空") {
                    viewModel.clearSubtitles()
                }

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

                Button(viewModel.startButtonTitle) {
                    viewModel.startOrStop()
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isRunning ? .red : .gray)
                .disabled(!viewModel.canTriggerPrimaryAction)
            }
        }
        .onChange(of: viewModel.translationPreparationRequest?.id) { _, _ in
            guard let request = viewModel.translationPreparationRequest else {
                translationConfiguration = nil
                activePreparationID = nil
                return
            }

            activePreparationID = request.id
            translationConfiguration = TranslationSession.Configuration(
                source: request.pair.source.localeLanguage,
                target: request.pair.target.localeLanguage
            )
        }
        .translationTask(translationConfiguration) { session in
            let requestID = activePreparationID
            do {
                try await prepareTranslation(session)
                await MainActor.run {
                    guard requestID == activePreparationID else { return }
                    translationConfiguration = nil
                    activePreparationID = nil
                    viewModel.completeTranslationPreparation()
                }
            } catch {
                await MainActor.run {
                    guard requestID == activePreparationID else { return }
                    translationConfiguration = nil
                    activePreparationID = nil
                    viewModel.failTranslationPreparation(error)
                }
            }
        }
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

    private func prepareTranslation(_ session: TranslationSession) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await session.prepareTranslation()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw TranslationPreparationTimeoutError()
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func controls(scale: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: scaled(12, by: scale)) {
                inlineToolbarField(title: "音频", scale: scale) {
                    Picker("", selection: $viewModel.audioSource) {
                        Text("系统音频").tag(AudioSourceKind.systemAudio)
                        Text("麦克风").tag(AudioSourceKind.microphone)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210 * scale)
                    .onChange(of: viewModel.audioSource) { _, _ in
                        viewModel.handleAudioSourceChanged()
                    }
                }

                inlineToolbarField(title: "源", scale: scale) {
                    compactMenuPicker(
                        selection: Binding(
                            get: { viewModel.selectedSourceLanguage },
                            set: { viewModel.configureSourceLanguage($0) }
                        ),
                        width: 120 * scale
                    )
                }

                inlineToolbarField(title: "目标", scale: scale) {
                    compactMenuPicker(
                        selection: Binding(
                            get: { viewModel.targetLanguage },
                            set: { viewModel.configureTargetLanguage($0) }
                        ),
                        disabledLanguage: viewModel.selectedSourceLanguage,
                        width: 120 * scale
                    )
                }

                inlineToolbarField(title: "原文色", scale: scale) {
                    compactColorPicker(selection: $viewModel.sourceSubtitleColorStyle, width: 112 * scale)
                }

                inlineToolbarField(title: "译文色", scale: scale) {
                    compactColorPicker(selection: $viewModel.translationSubtitleColorStyle, width: 112 * scale)
                }

                inlineFontSizeControl(
                    title: "原文",
                    selection: $viewModel.sourceFontSize,
                    range: 14...34,
                    width: 120 * scale
                )

                inlineFontSizeControl(
                    title: "译文",
                    selection: $viewModel.translationFontSize,
                    range: 18...42,
                    width: 120 * scale
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .controlSize(scale < 0.84 ? .small : .regular)
        .padding(.horizontal, scaled(14, by: scale))
        .padding(.vertical, scaled(9, by: scale))
        .background(sectionBackground(cornerRadius: 14))
    }

    private func inlineToolbarField<Content: View>(
        title: String,
        scale: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: scaled(6, by: scale)) {
            Text(title)
                .font(.system(size: max(11, 11 * scale), weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func compactMenuPicker(
        selection: Binding<SupportedLanguage>,
        disabledLanguage: SupportedLanguage? = nil,
        width: CGFloat
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(SupportedLanguage.allCases) { language in
                Text(language.displayName)
                    .tag(language)
                    .disabled(language == disabledLanguage)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: width)
    }

    private func compactColorPicker(
        selection: Binding<SubtitleColorStyle>,
        width: CGFloat
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(SubtitleColorStyle.allCases) { style in
                Text(style.displayName).tag(style)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: width)
    }

    private func inlineFontSizeControl(
        title: String,
        selection: Binding<Double>,
        range: ClosedRange<Double>,
        width: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("-") {
                    selection.wrappedValue = max(range.lowerBound, selection.wrappedValue - 1)
                }
                .buttonStyle(.bordered)
                .disabled(selection.wrappedValue <= range.lowerBound)

                Button("+") {
                    selection.wrappedValue = min(range.upperBound, selection.wrappedValue + 1)
                }
                .buttonStyle(.bordered)
                .disabled(selection.wrappedValue >= range.upperBound)
            }
            .frame(width: width, alignment: .leading)
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

    private func translationPreparationBanner(text: String, scale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: scaled(10, by: scale)) {
            ProgressView()
                .controlSize(scale < 0.84 ? .small : .regular)

            VStack(alignment: .leading, spacing: 4) {
                Text("正在准备语言资源")
                    .font(.system(size: 12, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("当前阶段只显示系统准备状态，macOS 不会提供下载百分比。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, scaled(14, by: scale))
        .padding(.vertical, scaled(10, by: scale))
        .background(sectionBackground(cornerRadius: 14))
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
            let contentSignature = transcriptSignature(for: segments, text: text)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollViewReader { proxy in
                    let bottomAnchorID = "bottom-anchor"
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
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

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .id(contentSignature)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        scrollToBottom(in: proxy, bottomAnchorID: bottomAnchorID)
                    }
                    .onChange(of: viewModel.transcriptRevision) { _, _ in
                        scrollToBottom(in: proxy, bottomAnchorID: bottomAnchorID)
                    }
                    .onChange(of: contentSignature) { _, _ in
                        scrollToBottom(in: proxy, bottomAnchorID: bottomAnchorID)
                    }
                }
            }
            .padding(14)
            .background(sectionBackground(cornerRadius: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(scale: CGFloat) -> some View {
        HStack(spacing: 10) {
            if viewModel.canOpenSettings {
                Button("打开权限设置") {
                    viewModel.openRelevantSettings()
                }
                .buttonStyle(.borderless)
            }

            if viewModel.needsManualTranslationDownload {
                Button("下载翻译语言") {
                    viewModel.openTranslationLanguageSettings()
                }
                .buttonStyle(.borderless)
            }

            Text("输入：\(viewModel.audioSourceDisplayName)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Text(viewModel.compactStatusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if viewModel.latencyMilliseconds > 0 {
                Text("· \(viewModel.latencyMilliseconds) ms")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, scaled(14, by: scale))
        .padding(.vertical, scaled(7, by: scale))
        .background(sectionBackground(cornerRadius: 14))
    }

    private func scrollToBottom(in proxy: ScrollViewProxy, bottomAnchorID: String) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func transcriptSignature(
        for segments: [TranslationSegment],
        text: KeyPath<TranslationSegment, String>
    ) -> String {
        segments
            .map { segment in
                "\(segment.id.uuidString)|\(segment.isStable ? 1 : 0)|\(segment[keyPath: text])"
            }
            .joined(separator: "\n")
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
        let scale = min(max(min(widthScale, heightScale), 0.78), 1.32)
        return max(12, base * scale)
    }

    private func windowScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / 1100
        let heightScale = size.height / 620
        return min(max(min(widthScale, heightScale), 0.8), 1.2)
    }

    private func toolbarScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / 1280
        return min(max(widthScale, 0.58), 1.0)
    }

    private func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
        value * scale
    }

    private var windowBackground: some View {
        Color(nsColor: .windowBackgroundColor)
    }

    private func sectionBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.85 : 0.55),
                        lineWidth: 1
                    )
            )
    }

}

private struct TranslationPreparationTimeoutError: LocalizedError {
    var errorDescription: String? {
        "语言资源准备超时。系统在 45 秒内没有完成下载准备，通常是系统下载未开始、网络不可用，或系统确认框没有出现。请保持联网后重试。"
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let isPinned: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            OverlayWindowConfigurator.configure(window: window, isPinned: isPinned)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            OverlayWindowConfigurator.configure(window: window, isPinned: isPinned)
        }
    }
}

@MainActor
private enum OverlayWindowConfigurator {
    private static var configuredWindows = Set<ObjectIdentifier>()
    private static var positionedWindows = Set<ObjectIdentifier>()

    static func configure(window: NSWindow, isPinned: Bool) {
        let identifier = ObjectIdentifier(window)
        if !configuredWindows.contains(identifier) {
            configuredWindows.insert(identifier)

            window.title = "多国语言同声翻译"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .automatic
                window.toolbarStyle = .unifiedCompact
            }
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.styleMask.insert(.resizable)
            window.styleMask.insert(.miniaturizable)
            window.styleMask.insert(.closable)
            window.styleMask.insert(.titled)
            window.minSize = NSSize(width: 920, height: 300)
        }

        window.level = isPinned ? .floating : .normal
        window.isMovableByWindowBackground = true

        if !positionedWindows.contains(identifier),
           let screen = window.screen ?? NSScreen.main {
            positionedWindows.insert(identifier)
            let width: CGFloat = 1040
            let height: CGFloat = 430
            let origin = CGPoint(
                x: screen.frame.midX - width / 2,
                y: screen.frame.midY - height / 2 - 80
            )
            window.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        }
    }
}
