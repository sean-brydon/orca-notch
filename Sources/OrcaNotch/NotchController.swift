import AppKit
import Carbon
import SwiftUI

enum NotchMode: Equatable {
    case collapsed, peek, expanded
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var mode: NotchMode = .collapsed
    /// Opened by click/hotkey (stays open) vs. by hover (closes when the mouse leaves).
    @Published var pinned = false
    @Published var peekAgentID: String?
    @Published var hardwareNotch = CGSize(width: 190, height: 32)
    @Published var screenHasNotch = true
    @Published var focusInputToken = 0
    @Published var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    static let earWidth: CGFloat = 38
    static let expandedSize = CGSize(width: 860, height: 520)

    /// Size of the black body (excluding the little top flares).
    func bodySize(showEars: Bool) -> CGSize {
        let notch = screenHasNotch ? hardwareNotch : CGSize(width: 120, height: 26)
        switch mode {
        case .collapsed:
            if !showEars { return screenHasNotch ? notch : .zero }
            return CGSize(width: notch.width + Self.earWidth * 2, height: notch.height)
        case .peek:
            return CGSize(width: max(notch.width + Self.earWidth * 2, 460), height: notch.height + 66)
        case .expanded:
            return Self.expandedSize
        }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    let model = NotchModel()
    let store = AgentStore()
    private var panel: NotchPanel!
    private var hotKey: HotKey?
    private var trackTimer: Timer?
    private var hoverSince: Date?
    private var outsideSince: Date?
    private var peekWork: DispatchWorkItem?
    private var monitors: [Any] = []

    private static let panelSize = CGSize(width: NotchModel.expandedSize.width + 80, height: NotchModel.expandedSize.height + 40)

    func start() {
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let root = NotchRootView(onCollapse: { [weak self] in self?.collapse() },
                                 onPin: { [weak self] in self?.pinOpen() })
            .environmentObject(model)
            .environmentObject(store)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host

        positionPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }

        // ⌥⌘O toggles the pull-down.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.mode == .expanded, self.model.pinned else { return }
                if !self.shapeRect().contains(NSEvent.mouseLocation) { self.collapse() }
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.model.mode == .expanded else { return false }
                self.collapse()
                return true
            }
            return handled ? nil : event
        } as Any)

        trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }

        store.onNewAttention = { [weak self] agent in self?.peek(agent) }
        store.start()

        // Dev flags for screenshots: `--expanded` opens pinned, `--peek-demo` peeks the first agent.
        let args = CommandLine.arguments
        if args.contains("--expanded") || args.contains("--peek-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if args.contains("--expanded") { self.expand(pinned: true) }
                    else if let agent = self.store.agents.first { self.peek(agent) }
                }
            }
        }
    }

    // MARK: - Geometry

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func positionPanel() {
        guard let screen = targetScreen else { return }
        let hasNotch = screen.safeAreaInsets.top > 0
        model.screenHasNotch = hasNotch
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.hardwareNotch = CGSize(width: screen.frame.width - left.width - right.width,
                                         height: screen.safeAreaInsets.top)
        }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - Self.panelSize.width / 2, y: f.maxY - Self.panelSize.height,
                              width: Self.panelSize.width, height: Self.panelSize.height), display: true)
    }

    /// The visible black body in screen coordinates.
    private func shapeRect() -> NSRect {
        guard let screen = targetScreen else { return .zero }
        let showEars = !store.agents.isEmpty
        let size = model.bodySize(showEars: showEars)
        let f = screen.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    private func notchHotZone() -> NSRect {
        guard let screen = targetScreen else { return .zero }
        let f = screen.frame
        let w = model.screenHasNotch ? model.hardwareNotch.width + NotchModel.earWidth * 2 : 200
        let h = model.screenHasNotch ? model.hardwareNotch.height : 8
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + 2)
    }

    // MARK: - Mouse tracking

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        let inShape = shapeRect().insetBy(dx: -2, dy: -2).contains(p)
        panel.ignoresMouseEvents = !inShape

        switch model.mode {
        case .collapsed, .peek:
            if notchHotZone().contains(p) || (model.mode == .peek && inShape) {
                if hoverSince == nil { hoverSince = Date() }
                if Date().timeIntervalSince(hoverSince!) > 0.18 { expand(pinned: false) }
            } else {
                hoverSince = nil
            }
        case .expanded:
            hoverSince = nil
            guard !model.pinned else { outsideSince = nil; return }
            if inShape {
                outsideSince = nil
            } else {
                if outsideSince == nil { outsideSince = Date() }
                if Date().timeIntervalSince(outsideSince!) > 0.45 { collapse() }
            }
        }
    }

    // MARK: - Transitions

    private func setMode(_ mode: NotchMode) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            model.mode = mode
        }
        store.isViewing = mode == .expanded
    }

    func expand(pinned: Bool) {
        peekWork?.cancel()
        if let peekID = model.peekAgentID, model.mode == .peek { store.selectedID = peekID }
        model.peekAgentID = nil
        model.pinned = pinned
        setMode(.expanded)
        if pinned { focusPanel() }
    }

    func pinOpen() {
        if model.mode != .expanded { expand(pinned: true); return }
        guard !model.pinned else { return }
        model.pinned = true
        focusPanel()
    }

    private func focusPanel() {
        panel.makeKeyAndOrderFront(nil)
        model.focusInputToken += 1
    }

    func collapse() {
        model.pinned = false
        outsideSince = nil
        setMode(.collapsed)
        panel.resignKey()
    }

    func toggle() {
        if model.mode == .expanded { collapse() }
        else {
            if let first = store.attentionAgents.first { store.selectedID = first.id }
            expand(pinned: true)
        }
    }

    private func peek(_ agent: Agent) {
        if model.soundEnabled { NSSound(named: agent.state == .done ? "Glass" : "Funk")?.play() }
        guard model.mode != .expanded else { return }
        model.peekAgentID = agent.id
        setMode(.peek)
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.mode == .peek else { return }
                self.model.peekAgentID = nil
                self.setMode(.collapsed)
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
