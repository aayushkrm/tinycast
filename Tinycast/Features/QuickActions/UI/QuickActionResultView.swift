import SwiftUI
@preconcurrency import Translation

struct QuickActionResultView: View {

    @Environment(\.metrics) private var metrics
    let state: QuickActionPanelState
    let languages: [Locale.Language]
    let onReplace: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void
    let onRetranslate: (Locale.Language) -> Void
    let onDownloaded: () -> Void
    let onHeight: (CGFloat) -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var downloadStorage: Any?

    /// Explicit overlays, not `safeAreaBar`: that lays its bars over the content instead of inset.
    var body: some View {
        ScrollView {
            body(for: state.phase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.spacing.xxl)
                // A `ScrollView` has no ideal height, so the frame below is set, not merely capped.
                .fixedSize(horizontal: false, vertical: true)
                // Measured before the insets, so `isScrollable` cannot depend on its own answer.
                .sonomaOnHeight {
                    contentHeight = $0
                }
                .padding(.top, inset(headerHeight))
                .padding(.bottom, inset(footerHeight))
        }
        .sonomaScrollBounceBasedOnSize()
        .mask(scrollFade)
        .overlay(alignment: .top) { measured(header) { headerHeight = $0 } }
        .overlay(alignment: .bottom) { measured(footer) { footerHeight = $0 } }
        .frame(width: metrics.size.quickActionPanel, height: panelHeight)
        .background(Theme.Colors.panelScrim)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.dialog, style: .continuous))
        .panelEntrance()
        // Reported, not measured: the frame above is ours, so reading it back would feed itself.
        .onChange(of: panelHeight, initial: true) { onHeight(panelHeight) }
        .sonomaTranslationTask($downloadStorage, onDownloaded: onDownloaded)
    }

    private func measured(_ bar: some View, action: @escaping (CGFloat) -> Void) -> some View {
        bar.sonomaOnHeight(action)
    }

    /// Clears the bar and its ramp, so the first line is opaque until it scrolls into the gradient.
    private func inset(_ bar: CGFloat) -> CGFloat {
        bar + (isScrollable ? metrics.size.quickActionScrollFade : 0)
    }

    /// A mask, not `scrollEdgeEffectStyle`: its material composited to nothing over this vibrancy.
    @ViewBuilder
    private var scrollFade: some View {
        if isScrollable {
            VStack(spacing: 0) {
                // Fully clear behind each bar, or text bleeds around the title and the buttons.
                Color.clear.frame(height: headerHeight)
                ramp(from: .clear, to: .black)
                Color.black
                ramp(from: .black, to: .clear)
                Color.clear.frame(height: footerHeight)
            }
        } else {
            // Dissolving a result that already fits would dim it for nothing.
            Color.black
        }
    }

    private func ramp(from start: Color, to end: Color) -> some View {
        LinearGradient(colors: [start, end], startPoint: .top, endPoint: .bottom)
            .frame(height: metrics.size.quickActionScrollFade)
    }

    private var isScrollable: Bool { contentHeight > metrics.size.quickActionPanelBody }

    private var panelHeight: CGFloat {
        let chrome = headerHeight + footerHeight
        return min(
            max(contentHeight + chrome, chrome + metrics.size.quickActionPanelMinBody),
            chrome + metrics.size.quickActionPanelBody)
    }

    private var header: some View {
        HStack(spacing: metrics.spacing.md) {
            // Only the title run drags: the handle is an overlay, and would eat the menu's clicks.
            HStack(spacing: metrics.spacing.sm) {
                SymbolImage(name: state.action.symbol, size: metrics.size.quickActionHeaderIcon)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(state.action.title)
                    .font(metrics.typography.panelTitle)
                Spacer(minLength: metrics.spacing.md)
            }
            .windowDraggable(true)
            if state.action == .translate, !languages.isEmpty { languageMenu }
        }
        .padding(.horizontal, metrics.spacing.xxl)
        .padding(.top, metrics.spacing.xl)
        .padding(.bottom, metrics.spacing.lg)
    }

    @ViewBuilder
    private func body(for phase: QuickActionPanelState.Phase) -> some View {
        switch phase {
        case .running where state.output.isEmpty:
            HStack(spacing: metrics.spacing.md) {
                ProgressView().controlSize(.small)
                Text("Working…").foregroundStyle(Theme.Colors.textSecondary)
            }
            .font(metrics.typography.rowTitle)
        case .running, .finished:
            output
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
        case .needsLanguageDownload:
            downloadPrompt
        }
    }

    @ViewBuilder
    private var output: some View {
        let chunks = state.diff
        if !chunks.isEmpty {
            // One `Text` per chunk would break the wrap, so the runs are styled inside one string.
            prose(Text(attributed(chunks)))
        } else if state.action == .summarize {
            MarkdownView(blocks: MarkdownBlock.parse(state.output))
        } else {
            prose(Text(state.output))
        }
    }

    /// A result is a paragraph to read rather than a row label, so it is led like one.
    private func prose(_ text: Text) -> some View {
        text
            .font(metrics.typography.rowTitle)
            .lineSpacing(metrics.spacing.xs)
            .textSelection(.enabled)
    }

    private func attributed(_ chunks: [TextDiffEngine.Chunk]) -> AttributedString {
        chunks.reduce(into: AttributedString()) { result, chunk in
            switch chunk {
            case .equal(let text):
                result.append(AttributedString(text))
            case .inserted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.success
                result.append(run)
            case .deleted(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.Colors.destructive
                run.strikethroughStyle = .single
                result.append(run)
            }
        }
    }

    private var downloadPrompt: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xl) {
            Text("\(TextTranslator.displayName(of: state.targetLanguage)) hasn't been downloaded yet.")
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
            if #available(macOS 15.0, *) {
                Button("Download") {
                    downloadStorage = TranslationSession.Configuration(
                        source: nil, target: state.targetLanguage)
                }
            } else {
                Text("Language downloads need macOS 15 or newer.")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
    }

    private var languageMenu: some View {
        Menu(TextTranslator.displayName(of: state.targetLanguage)) {
            ForEach(languages, id: \.minimalIdentifier) { language in
                Button(TextTranslator.displayName(of: language)) { onRetranslate(language) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .fixedSize()
    }

    private var footer: some View {
        HStack(spacing: metrics.spacing.md) {
            Spacer(minLength: metrics.spacing.md)
            Button("Dismiss", action: onCancel)
            Button("Copy", action: onCopy).disabled(!state.canReplace)
            Button("Replace", action: onReplace)
                .buttonStyle(.borderedProminent)
                .disabled(!state.canReplace)
        }
        .controlSize(.large)
        .padding(.horizontal, metrics.spacing.xxl)
        .padding(.vertical, metrics.spacing.xl)
    }
}

extension View {
    @ViewBuilder
    func sonomaTranslationTask(
        _ storage: Binding<Any?>, onDownloaded: @escaping () -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            translationTask(
                Binding<TranslationSession.Configuration?>(
                    get: { storage.wrappedValue as? TranslationSession.Configuration },
                    set: { storage.wrappedValue = $0 })
            ) { session in
                try? await session.prepareTranslation()
                await MainActor.run {
                    storage.wrappedValue = nil
                    onDownloaded()
                }
            }
        } else {
            self
        }
    }
}
