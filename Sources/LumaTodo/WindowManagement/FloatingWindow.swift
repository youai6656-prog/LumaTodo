import AppKit
import SwiftUI

final class TaskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    private(set) var keyBeganWithMarkedText = false

    static var hasActiveComposition: Bool {
        let window = NSApp.keyWindow
        return (window as? TaskPanel)?.keyBeganWithMarkedText == true
            || (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        keyBeganWithMarkedText = (firstResponder as? NSTextView)?.hasMarkedText() == true
        defer { keyBeganWithMarkedText = false }
        super.sendEvent(event)
    }
}

enum ScreenEdge: String { case left, right }

@MainActor
final class FloatingWindow: NSObject, NSWindowDelegate {
    private static let maxSize = NSSize(width: 3000, height: 3000)
    private let state: AppState
    private let panel: TaskPanel
    private let tab: TaskPanel
    private var fullFrame: NSRect
    private var targetFrame: NSRect
    private var manualSize: NSSize?
    private var contentHeight: CGFloat
    private var editorHeight: CGFloat?
    private var manualEditorSize: NSSize?
    private var tuckedEdge: ScreenEdge?
    private var pendingLayout: Task<Void, Never>?
    private var settle: Timer?
    private var resizing = false
    private var moving = false
    private var animating = false
    private var transitionID = 0
    private var settingsWindow: NSWindow?
    private var prefs: PreferencesValues { state.preferences.values }

    var isVisible: Bool { panel.isVisible || tab.isVisible }

    init(state: AppState) {
        self.state = state
        let preferences = state.preferences
        contentHeight = state.preferredPanelHeight(notice: false)
        manualSize = Self.savedManualSize(preferences)
        let frame = Self.initialFrame(preferences, manualSize: manualSize, height: contentHeight)
        fullFrame = frame
        targetFrame = frame
        panel = TaskPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        tab = TaskPanel(contentRect: NSRect(x: frame.minX, y: frame.minY, width: 30, height: 54),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        for window in [panel, tab] {
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.animationBehavior = .none
            window.becomesKeyOnlyIfNeeded = false
            window.tabbingMode = .disallowed
        }
        panel.title = "LumaTodo"
        panel.setAccessibilityLabel("LumaTodo")
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: TaskPanelView(state: state))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: false)
        panel.delegate = self
        updateSizeConstraints(in: boundary(for: frame))
        applyPreferences()
        saveFrame()
    }

    func toggle() {
        if tuckedEdge != nil || !panel.isVisible || (!prefs.allSpaces && !panel.isOnActiveSpace) { show() }
        else { hide() }
    }

    func show() {
        if tuckedEdge != nil {
            tuckedEdge = nil
            tab.orderOut(nil)
            cancelTransition()
            panel.setFrame(reachable(targetFrame), display: true)
            panel.alphaValue = animates ? 0.20 : 1
            panel.orderFrontRegardless()
            transition(to: panel.frame)
        } else if !panel.isVisible || !panel.isOnActiveSpace {
            cancelTransition()
            panel.orderOut(nil)
            panel.setFrame(reachable(targetFrame), display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func revealEditor() {
        show()
        panel.orderFrontRegardless()
    }

    func hide() {
        settle?.invalidate()
        moving = false
        cancelTransition()
        tuckedEdge = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        tab.orderOut(nil)
    }

    func tuck() {
        guard panel.isVisible, state.editor == nil, state.pendingSnooze == nil, !TaskPanel.hasActiveComposition else { return }
        let frame = targetFrame
        let visible = boundary(for: frame)
        collapse(to: frame.midX < visible.midX ? .left : .right)
    }

    func applyPreferences() {
        let level: NSWindow.Level = prefs.alwaysOnTop ? .floating : .normal
        let spaces: NSWindow.CollectionBehavior = prefs.allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        let appearance: NSAppearance?
        switch prefs.appearance {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        for window in [panel, tab] {
            window.level = level
            window.collectionBehavior = spaces
            window.appearance = appearance
        }
        settingsWindow?.appearance = appearance
        if !prefs.rememberPosition {
            state.preferences.defaults.removeObject(forKey: "window.frame")
            state.preferences.defaults.removeObject(forKey: "window.manualSize")
        } else {
            saveFrame()
        }
    }

    func updateLayout(height: CGFloat, editing: Bool) {
        if editing {
            editorHeight = height
        } else {
            editorHeight = nil
            manualEditorSize = nil
            contentHeight = height
        }
        pendingLayout?.cancel()
        pendingLayout = Task { @MainActor [weak self] in
            // Coalesce layout changes and keep frame mutations outside the SwiftUI update pass.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.fit()
        }
    }

    func setMini(_ enabled: Bool) {
        if enabled { editorHeight = nil }
        fit()
    }

    func restoreDefaultSize() {
        manualSize = nil
        state.preferences.defaults.removeObject(forKey: "window.manualSize")
        let visible = boundary(for: fullFrame)
        fullFrame = PanelLayout.resized(fullFrame, width: prefs.windowWidth, height: contentHeight, in: visible)
        if state.mini { state.setMini(false) }
        fit()
        saveFrame()
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 530),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(state: state))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = state.words("LumaTodo 设置", "LumaTodo Settings")
        applyPreferences()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func screensChanged() {
        settle?.invalidate()
        moving = false
        fullFrame = reachable(fullFrame)
        targetFrame = reachable(targetFrame)
        fit()
        saveFrame()
    }

    func windowWillMove(_ notification: Notification) {
        if !animating, mouseIsDragging, !moving {
            moving = true
            scheduleSettle()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !animating, panel.isVisible, tuckedEdge == nil, !resizing, !panel.inLiveResize,
              moving || mouseIsDragging else { return }
        moving = true
        settle?.invalidate()
        scheduleSettle()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        // AppKit also reports live-resize callbacks for some animator-driven frame changes.
        guard !animating, mouseIsDragging else { return }
        settle?.invalidate()
        moving = false
        cancelTransition()
        resizing = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard resizing else { return }
        resizing = false
        if state.editor != nil {
            manualEditorSize = panel.frame.size
        } else {
            if !state.mini { manualSize = panel.frame.size }
            recordUserFrame(reachable(panel.frame))
        }
        fit()
        saveFrame()
    }

    private var mouseIsDragging: Bool {
        if NSEvent.pressedMouseButtons & 1 != 0 { return true }
        let event = NSApp.currentEvent?.type
        return event == .leftMouseDragged || event == .leftMouseDown
    }

    private func fit() {
        guard !resizing, !moving else { return }
        let visible = boundary(for: fullFrame)
        fullFrame = PanelLayout.resized(fullFrame, width: manualSize?.width ?? fullFrame.width,
                                       height: manualSize?.height ?? contentHeight, in: visible)
        let size: NSSize
        if state.mini {
            size = PanelLayout.miniSize
        } else if let editorHeight {
            size = manualEditorSize ?? PanelLayout.editorSize(browsingWidth: fullFrame.width, contentHeight: editorHeight)
        } else {
            size = fullFrame.size
        }
        let target = PanelLayout.resized(fullFrame, width: size.width, height: size.height, in: visible)
        updateSizeConstraints(in: visible)
        let changed = target != targetFrame
        guard changed || (!animating && tuckedEdge == nil && target != panel.frame) else { return }
        targetFrame = target
        if let edge = tuckedEdge {
            positionTab(edge)
        } else if panel.isVisible {
            transition(to: target)
        } else {
            panel.setFrame(target, display: false)
        }
        if state.editor == nil { saveFrame() }
    }

    private func updateSizeConstraints(in visible: NSRect) {
        if state.mini {
            let size = NSSize(width: min(PanelLayout.miniSize.width, visible.width),
                              height: min(PanelLayout.miniSize.height, visible.height))
            panel.minSize = size
            panel.maxSize = size
        } else if editorHeight != nil {
            panel.maxSize = NSSize(width: min(520, visible.width), height: min(PanelLayout.editorMaximumHeight, visible.height))
            panel.minSize = NSSize(width: min(380, visible.width), height: min(PanelLayout.editorMinimumHeight, visible.height))
        } else {
            panel.maxSize = Self.maxSize
            panel.minSize = NSSize(width: min(PanelLayout.minimumWidth, visible.width),
                                   height: min(PanelLayout.minimumHeight, visible.height))
        }
        panel.isMovableByWindowBackground = true
    }

    private func scheduleSettle() {
        settle = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.animating, self.panel.isVisible, self.tuckedEdge == nil else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleSettle() }
                else { self.finishMove() }
            }
        }
    }

    private func finishMove() {
        moving = false
        let raw = panel.frame
        let moved = raw.origin != targetFrame.origin
        var frame = reachable(raw)
        let visible = boundary(for: frame)
        let left = abs(raw.minX - visible.minX)
        let right = abs(raw.maxX - visible.maxX)
        let closest: ScreenEdge = left < right ? .left : .right
        let distance = min(left, right)
        if moved && prefs.snapToEdge && distance <= 16 {
            frame.origin.x = closest == .left ? visible.minX : visible.maxX - frame.width
        }
        recordUserFrame(frame)
        targetFrame = frame
        if moved, prefs.snapToEdge, prefs.autoHide, distance <= 7,
           !(panel.firstResponder is NSTextView), state.editor == nil, state.pendingSnooze == nil {
            collapse(to: closest)
        } else if raw != frame {
            transition(to: frame)
        }
        saveFrame()
        fit()
    }

    private func recordUserFrame(_ frame: NSRect) {
        let visible = boundary(for: frame)
        fullFrame = PanelLayout.resized(frame, width: fullFrame.width, height: fullFrame.height, in: visible)
        if !state.mini && state.editor == nil { fullFrame = frame }
        targetFrame = frame
    }

    private func collapse(to edge: ScreenEdge) {
        settle?.invalidate()
        moving = false
        tuckedEdge = edge
        positionTab(edge)
        tab.orderFrontRegardless()
        transition(to: targetFrame, alpha: 0) { [weak self] in
            guard let self, tuckedEdge == edge else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func positionTab(_ edge: ScreenEdge) {
        let visible = boundary(for: targetFrame)
        let size = NSSize(width: 30, height: 54)
        let x = edge == .left ? visible.minX + 3 : visible.maxX - size.width - 3
        let y = min(max(targetFrame.midY - size.height / 2, visible.minY + 4), visible.maxY - size.height - 4)
        if tab.contentView == nil || !tab.isVisible {
            let host = NSHostingView(rootView: EdgeTabView(state: state, edge: edge) { [weak self] in self?.show() })
            host.sizingOptions = []
            tab.contentView = host
        }
        tab.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    private var animates: Bool { prefs.animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func cancelTransition() {
        transitionID += 1
        animating = false
    }

    private func transition(to frame: NSRect, alpha: CGFloat = 1,
                            completion: (@MainActor @Sendable () -> Void)? = nil) {
        settle?.invalidate()
        transitionID += 1
        let id = transitionID
        animating = true
        guard animates else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = alpha
            animating = false
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, id == self.transitionID else { return }
                self.animating = false
                completion?()
            }
        }
    }

    private func saveFrame() {
        guard prefs.rememberPosition else { return }
        let defaults = state.preferences.defaults
        defaults.set(NSStringFromRect(fullFrame), forKey: "window.frame")
        defaults.set(true, forKey: "window.frame.v2")
        if let manualSize { defaults.set(NSStringFromSize(manualSize), forKey: "window.manualSize") }
    }

    private static func savedManualSize(_ prefs: Preferences) -> NSSize? {
        guard prefs.values.rememberPosition else { return nil }
        if let saved = prefs.defaults.string(forKey: "window.manualSize") {
            let size = NSSizeFromString(saved)
            if size.width >= PanelLayout.minimumWidth, size.height >= PanelLayout.minimumHeight { return size }
        }
        if !prefs.defaults.bool(forKey: "window.frame.v2"),
           let saved = prefs.defaults.string(forKey: "window.frame") {
            let size = NSRectFromString(saved).size
            let isDefault = (size.width == 350 || size.width == prefs.values.windowWidth)
                && (size.height == 460 || size.height == prefs.values.windowHeight)
            if !isDefault, size.width >= PanelLayout.minimumWidth, size.height >= 390 { return size }
        }
        return nil
    }

    private static func initialFrame(_ prefs: Preferences, manualSize: NSSize?, height: CGFloat) -> NSRect {
        let width = manualSize?.width ?? CGFloat(prefs.values.windowWidth)
        let height = manualSize?.height ?? height
        if prefs.values.rememberPosition, let saved = prefs.defaults.string(forKey: "window.frame") {
            let frame = NSRectFromString(saved)
            if frame.width >= PanelLayout.minimumWidth, frame.height >= PanelLayout.minimumHeight {
                return PanelLayout.resized(frame, width: width, height: height, in: visibleFrame(for: frame))
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return PanelLayout.reachable(NSRect(x: visible.maxX - width - 24, y: visible.maxY - height - 20,
                                           width: width, height: height), in: visible)
    }

    private static func visibleFrame(for frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { left, right in
            let a = left.frame.intersection(frame)
            let b = right.frame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }
        if let screen, screen.frame.intersects(frame) { return screen.visibleFrame }
        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    }

    private func boundary(for frame: NSRect) -> NSRect { Self.visibleFrame(for: frame) }
    private func reachable(_ frame: NSRect) -> NSRect { PanelLayout.reachable(frame, in: boundary(for: frame)) }
}
