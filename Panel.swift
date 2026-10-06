import AppKit
import SwiftUI

// Menu bar panel. It never activates TypeThru, so the app the user was typing into stays in front.

enum PanelAction { case typeClipboard, test(TypingTest), setUp, checkVirtualKeyboard, checkAccessibility, diagnostics, uninstall, quit }

final class PanelModel: ObservableObject {
    struct Status: Equatable { var text: String; var ready: Bool; var needsSetUp = false }
    @Published var method = TypingMethod.virtualKeyboard
    @Published var speedIndex = 0
    @Published var replaceSymbols = true
    @Published var shiftReturn = true
    @Published var status = Status(text: "Checking…", ready: false)
    @Published var busy = false
    var speeds: [String] = []
    var speedDetails: [String] = []
    var onChange: (() -> Void)?
    var perform: ((PanelAction) -> Void)?
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Button { model.perform?(.typeClipboard) } label: {
                HStack {
                    Image(systemName: "keyboard")
                    Text("Type Clipboard").fontWeight(.semibold)
                    Spacer()
                    Text("⌃\\").font(.system(.body, design: .rounded)).opacity(0.75)
                }
                .padding(.vertical, 6).padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
            }
            .prominentGlass()
            .tint(Brand.accent)
            .controlSize(.large)
            .disabled(model.busy)
            Text("Esc, a mouse click, or switching apps stops typing.")
                .font(.caption).foregroundStyle(.secondary)

            settings
            tests
            footer
        }
        .padding(18)
        .frame(width: 340)
        .noFocusRing()
        .glassPanel()
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            Text("TypeThru").font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.status.ready ? Color.green : Color.orange).frame(width: 8, height: 8)
                    .shadow(color: model.status.ready ? .green : .orange, radius: 4)
                Text(model.status.text).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassCapsule()
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.status.needsSetUp {
                Button("Set Up Virtual Keyboard…") { model.perform?(.setUp) }.glassButton()
            }
            LabeledContent("Method") {
                Picker("Method", selection: binding(\.method)) {
                    ForEach(TypingMethod.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            LabeledContent("Speed") {
                Picker("Speed", selection: binding(\.speedIndex)) {
                    ForEach(model.speeds.indices, id: \.self) { Text(model.speeds[$0]).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if model.speedDetails.indices.contains(model.speedIndex) {
                Text(model.speedDetails[model.speedIndex]).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Replace symbols without a key (• → -)", isOn: binding(\.replaceSymbols))
                .toggleStyle(.switch).controlSize(.small).tint(Brand.accent)
            Toggle("Type line breaks as Shift+Return", isOn: binding(\.shiftReturn))
                .toggleStyle(.switch).controlSize(.small).tint(Brand.accent)
                .help("Makes a new line instead of sending in chat apps. Turn off for spreadsheets, where Shift+Return moves up a cell.")
        }
        .font(.callout)
    }

    private var tests: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Typing tests").font(.callout.weight(.semibold))
            Text("Starts in 3 seconds. Click the target text field first.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { testButton(.short); testButton(.capitals); testButton(.symbols) }
                GridRow { testButton(.smartSymbols).gridCellColumns(2); testButton(.long) }
            }
            .disabled(model.busy)
        }
    }

    private func testButton(_ test: TypingTest) -> some View {
        Button { model.perform?(.test(test)) } label: {
            Text(test.title).lineLimit(1).frame(maxWidth: .infinity)
        }
        .glassButton()
        .help(test.help)
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Set Up Virtual Keyboard…") { model.perform?(.setUp) }
                Button("Check Virtual Keyboard") { model.perform?(.checkVirtualKeyboard) }
                Button("Check Accessibility Permission") { model.perform?(.checkAccessibility) }
                Button("Last Attempt / Diagnostics") { model.perform?(.diagnostics) }
                Divider()
                Button("Uninstall TypeThru…") { model.perform?(.uninstall) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button("Quit") { model.perform?(.quit) }.glassButton()
        }
        .font(.callout)
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<PanelModel, T>) -> Binding<T> {
        Binding(get: { model[keyPath: keyPath] },
                set: { model[keyPath: keyPath] = $0; model.onChange?() })
    }
}

// Liquid Glass on macOS 26 and later; system materials before that.
private extension View {
    @ViewBuilder func glassPanel() -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer { self.glassEffect(.regular.tint(Color.black.opacity(0.45)), in: .rect(cornerRadius: 26)) }
        } else {
            background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }

    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26, *) { glassEffect(.regular, in: .capsule) }
        else { background(.thinMaterial, in: Capsule()) }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    @ViewBuilder func prominentGlass() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}

/// A borderless panel that can take clicks without making TypeThru the active app.
final class GlassPanel: NSPanel {
    var onClose: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        // DECISION: the glass draws its own edge; a window shadow outlines the square frame.
        hasShadow = false
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); close() }
    override func cancelOperation(_ sender: Any?) { close() }
    override func close() { super.close(); onClose?() }
}

final class PanelController {
    let model = PanelModel()
    var onClose: (() -> Void)?
    private var panel: GlassPanel?

    var isShown: Bool { panel?.isVisible == true }

    func show(below button: NSStatusBarButton) {
        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame.size = host.fittingSize
        let panel = GlassPanel(content: host)
        panel.onClose = { [weak self] in self?.panel = nil; self?.onClose?() }
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = host.fittingSize
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        let current = panel
        panel = nil
        current?.close()
    }
}
