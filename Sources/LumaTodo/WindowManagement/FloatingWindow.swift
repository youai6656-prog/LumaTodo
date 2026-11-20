import AppKit
import SwiftUI
import OSLog

class TaskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    private(set) var keyBeganWithMarkedText = false
    var onEscape: (() -> Bool)?
    var onGripDown: ((NSEvent) -> Bool)?
    var onGripInterrupted: (() -> Void)?
    let grips = NSHashTable<NSView>.weakObjects()

    func gripContains(screenPoint: CGPoint) -> Bool {
        let point = convertPoint(fromScreen: screenPoint)
        return grips.allObjects.contains { view in
            view.window === self && !view.isHiddenOrHasHiddenAncestor && view.bounds.contains(view.convert(point, from: nil))
        }
    }

    #if DEBUG
    var sampleGripPoint: CGPoint? {
        grips.allObjects.filter { $0.window === self && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
            .max(by: { $0.bounds.width < $1.bounds.width }).map {
                convertPoint(toScreen: $0.convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil))
            }
    }
    #endif
    var onGripEvent: ((NSEvent) -> Bool)?

    static var hasActiveComposition: Bool {
        let window = NSApp.keyWindow
        return (window as? TaskPanel)?.keyBeganWithMarkedText == true
            || (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onGripInterrupted?()
            if !event.modifierFlags.contains(.control),
               gripContains(screenPoint: PointerSample(event, in: self).point), onGripDown?(event) == true { return }
        }
        if (event.type == .leftMouseDragged || event.type == .leftMouseUp), onGripEvent?(event) == true { return }
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        keyBeganWithMarkedText = (firstResponder as? NSTextView)?.hasMarkedText() == true
        defer { keyBeganWithMarkedText = false }
        if event.keyCode == 53, !keyBeganWithMarkedText, onEscape?() == true { return }
        super.sendEvent(event)
    }
}

enum ScreenEdge: String, Codable { case left, right }

struct EdgePlacement: Codable, Equatable {
    static let size = NSSize(width: 28, height: 64)
    let displayID: UInt32?
    let edge: ScreenEdge
    let fraction: Double

    init(displayID: UInt32?, edge: ScreenEdge, centerY: CGFloat, in visible: NSRect) {
        self.displayID = displayID
        self.edge = edge
        let margin = Self.size.height / 2 + 4
        let travel = max(0, visible.height - 2 * margin)
        fraction = travel > 0 ? min(1, max(0, (centerY - visible.minY - margin) / travel)) : 0.5
    }

    func frame(in visible: NSRect) -> NSRect {
        let width = min(Self.size.width, visible.width)
        let height = min(Self.size.height, visible.height)
        let x = edge == .left ? visible.minX : visible.maxX - width
        let margin = min(4, (visible.height - height) / 2)
        let y = visible.minY + margin + min(1, max(0, fraction)) * (visible.height - height - 2 * margin)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor @Observable
final class EdgeTabInteraction {
    var isPreview = false
}

private final class EdgeTabPanel: TaskPanel {
    private struct Pointer {
        var gesture: EdgePullGesture
        var signaled = false
    }

    let interaction = EdgeTabInteraction()
    var pullConfiguration: (() -> (ScreenEdge, EdgePullTuning)?)?
    var onPress: ((CGFloat) -> Void)?
    var onPull: ((EdgePullGesture) -> Void)?
    var onPullEnd: ((EdgePullGesture.Release, Double) -> Void)?
    private var pointer: Pointer?

    @discardableResult
    func cancelDrag() -> Bool {
        guard let pointer else { return false }
        releasePointer(pointer)
        onPullEnd?(.stay, 0)
        return true
    }

    private func releasePointer(_ pointer: Pointer) {
        self.pointer = nil
        if pointer.gesture.dragging { NSCursor.pop() }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            _ = cancelDrag()
            guard let (edge, tuning) = pullConfiguration?() else { return }
            let start = PointerSample(event, in: self)
            pointer = Pointer(gesture: EdgePullGesture(edge: edge, tuning: tuning, start: start))
            let anchor = min(0.94, max(0.06, (start.point.y - frame.minY) / max(1, frame.height)))
            onPress?(anchor)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .leftMouseDragged, .leftMouseUp:
            guard var pointer else { return }
            let wasDragging = pointer.gesture.dragging
            pointer.gesture.append(PointerSample(event, in: self))
            let gesture = pointer.gesture
            if gesture.dragging {
                if !wasDragging { NSCursor.closedHand.push() }
                onPull?(gesture)
                if gesture.ready, !pointer.signaled {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    pointer.signaled = true
                }
            }
            self.pointer = pointer
            if event.type == .leftMouseUp {
                releasePointer(pointer)
                let destination = gesture.release
                onPullEnd?(destination == .click && event.clickCount > 1 ? .stay : destination, gesture.progressVelocity)
            }
        default:
            super.sendEvent(event)
        }
    }
}
private final class EdgeTabHost: NSHostingView<EdgeTabView> {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

@MainActor
final class FloatingWindow: NSObject, NSWindowDelegate {
    private static let maxSize = NSSize(width: 3000, height: 3000)
    private let state: AppState
    private let panel: TaskPanel
    private let tab: EdgeTabPanel
    private var fullFrame: NSRect
    private var targetFrame: NSRect
    private var manualSize: NSSize?
    private var contentHeight: CGFloat
    private var editorHeight: CGFloat?
    private var manualEditorSize: NSSize?
    private enum Visibility { case hidden, expanded, dragging, collapsing, collapsed, pullingTab, expanding }
    private var visibility = Visibility.hidden
    private var placement: EdgePlacement?
    private var tabEdge: ScreenEdge?
    private var tabPullDestination: CGRect?
    private struct TabPullSession {
        let geometry: MorphGeometry
        let visible: CGRect
        let placement: EdgePlacement
        var centerY: CGFloat
    }
    private var tabPullSession: TabPullSession?
    private struct PreviewKey: Equatable {
        let size: CGSize
        let revision: UInt64
        let appearance: NSAppearance.Name
        let preferences: PreferencesValues
        let folded: Set<TaskGroup>
        let undo: TaskUndo?
        let scrollOffset: CGFloat
        let selection: UUID?
        let minute: Int
        let mini: Bool
        let searching: Bool
    }
    private var previewCache: (key: PreviewKey, image: NSImage?)?
    private var previewTask: Task<Void, Never>?
    private var pendingLayout: Task<Void, Never>?
    private var resizing = false
    private struct GripDrag {
        let frame: CGRect
        let initialScreen: UInt32?
        var motion: DragMotion
        var candidate: ScreenEdge?
        var crossedDisplay = false
        var gaveFeedback = false
        var hasMoved = false
    }
    private var gripDrag: GripDrag?
    private let morph = WindowMorph()
    private var settingsWindow: NSWindow?
    private var prefs: PreferencesValues { state.preferences.values }

    var isVisible: Bool { visibility != .hidden }
    var transitionFrame: CGRect? { morph.currentFrame }
    var onTransitionFrame: ((CFTimeInterval) -> Void)? {
        get { morph.onFrame }
        set { morph.onFrame = newValue }
    }

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
        tab = EdgeTabPanel(contentRect: NSRect(origin: frame.origin, size: EdgePlacement.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if preferences.values.rememberPosition,
           let data = preferences.defaults.data(forKey: "window.edgePlacement") {
            placement = try? JSONDecoder().decode(EdgePlacement.self, from: data)
        }
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
        panel.isMovableByWindowBackground = false
        panel.onEscape = { [weak self] in
            guard let self else { return false }
            return cancelGrip(reason: "escape") || state.dismissDialog()
        }
        panel.onGripDown = { [weak self] in self?.beginGrip($0) ?? false }
        panel.onGripInterrupted = { [weak self] in _ = self?.cancelGrip(reason: "newMouseDownWithoutRelease") }
        #if DEBUG
        state.windowHeightForDiagnostics = { [weak panel] in panel?.frame.height ?? 0 }
        #endif
        panel.onGripEvent = { [weak self] in self?.trackGrip($0) ?? false }
        tab.title = "LumaTodo Edge"
        tab.becomesKeyOnlyIfNeeded = true
        tab.onEscape = { [weak tab] in tab?.cancelDrag() ?? false }
        tab.pullConfiguration = { [weak self] in self?.tabPullConfiguration() }
        tab.onPress = { [weak self] anchor in self?.beginTabPull(anchor: anchor) }
        tab.onPull = { [weak self] gesture in self?.updateTabPull(gesture) }
        tab.onPullEnd = { [weak self] result, velocity in self?.endTabPull(result, velocity: velocity) }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelTabTracking),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        let host = NSHostingView(rootView: TaskPanelView(state: state) { [weak self] in self?.dialogChanged() })
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: false)
        panel.delegate = self
        fit()
        applyPreferences()
        saveFrame()
    }

    func restoreAtLaunch() {
        if prefs.rememberPosition, placement != nil,
           state.preferences.defaults.bool(forKey: "window.collapsed") {
            visibility = .collapsed
            positionTab()
            tab.orderFrontRegardless()
            warmPreview(size: targetFrame.size)
        } else {
            show()
        }
    }

    func toggle() {
        switch visibility {
        case .hidden, .collapsed: show()
        case .expanded:
            if !prefs.allSpaces && !panel.isOnActiveSpace { show() }
            else { tuck() }
        case .collapsing: show()
        case .expanding: tuck()
        case .pullingTab: _ = tab.cancelDrag()
        case .dragging: break
        }
    }

    func show() {
        switch visibility {
        case .collapsed: expand()
        case .collapsing: retarget(toEdge: false)
        case .expanding, .dragging, .pullingTab: break
        case .hidden, .expanded:
            guard !panel.isVisible || !panel.isOnActiveSpace else { return }
            visibility = .expanded
            fit()
                panel.orderOut(nil)
            panel.setFrame(reachable(targetFrame), display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            savePlacement()
        }
    }

    func revealEditor() {
        show()
    }

    func hide() {
        _ = cancelGrip(reason: "orderOutWithoutRelease")
        hidePreview()
        visibility = .hidden
        gripDrag = nil
        tabPullDestination = nil
        tabPullSession = nil
        previewTask?.cancel()
        morph.stop()
        panel.orderOut(nil)
        panel.alphaValue = 1
        tab.orderOut(nil)
        tab.cancelDrag()
        setTabConcealed(false)
        updateInteractivity()
        savePlacement()
    }

    func tuck() {
        if visibility == .expanding, state.editor == nil, state.dialog == nil {
            retarget(toEdge: true)
            return
        }
        guard visibility == .expanded, panel.isVisible, state.editor == nil, state.dialog == nil,
              !TaskPanel.hasActiveComposition else { return }
        let visible = boundary(for: targetFrame)
        let closest: ScreenEdge = targetFrame.midX < visible.midX ? .left : .right
        collapse(to: preferredEdge(closest))
    }

    func dialogChanged() {
        updateInteractivity()
        if state.dialog != nil, visibility == .expanded {
            panel.makeFirstResponder(nil)
            panel.makeKey()
        }
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
            state.preferences.defaults.removeObject(forKey: "window.edgePlacement")
            state.preferences.defaults.removeObject(forKey: "window.collapsed")
        } else if visibility != .hidden {
            saveFrame()
            savePlacement()
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
        _ = cancelGrip(reason: "screenChangedWithoutRelease")
        fullFrame = reachable(fullFrame)
        targetFrame = reachable(targetFrame)
        switch visibility {
        case .collapsed, .collapsing, .pullingTab:
            tab.cancelDrag()
            if let placement {
                let visible = screenForPlacement()?.visibleFrame ?? boundary(for: targetFrame)
                alignRestoration(to: placement.frame(in: visible).midY, in: visible)
            }
            finishCollapse()
        case .expanding:
            finishExpansion()
        case .expanded, .dragging, .hidden:
            fit()
        }
        saveFrame()
    }

    private func finishExpansion() {
        visibility = .expanded
        tabPullSession = nil
        if let destination = tabPullDestination {
            tabPullDestination = nil
            recordUserFrame(reachable(destination))
            saveFrame()
        }
        tab.orderOut(nil)
        setTabConcealed(false)
        panel.setFrame(targetFrame, display: true)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        if state.editor != nil { panel.makeKey() }
        panel.invalidateShadow()
        morph.retireAfterHandoff()
        fit()
        dialogChanged()
        savePlacement()
    }

    private func beginGrip(_ event: NSEvent) -> Bool {
        guard visibility == .expanded, !resizing, state.dialog == nil, !TaskPanel.hasActiveComposition else { return false }
        let sample = PointerSample(event, in: panel)
        let screen = NSScreen.screens.first { $0.frame.contains(sample.point) } ?? Self.screen(for: panel.frame)
        gripDrag = GripDrag(frame: panel.frame, initialScreen: screen?.displayID, motion: DragMotion(start: sample))
        visibility = .dragging
        #if DEBUG
        emitGesture("mouseDown nearestScreen=\(screen?.displayID ?? 0) stateBefore=expanded stateAfter=dragging")
        #endif
        return true
    }

    @discardableResult
    private func cancelGrip(reason: String) -> Bool {
        guard visibility == .dragging, let drag = gripDrag else { return false }
        gripDrag = nil
        visibility = .expanded
        hidePreview()
        if drag.hasMoved { finishMove(allowAutoTuck: false) }
        else { fit() }
        #if DEBUG
        emitGesture("releaseMissing samples=\(drag.motion.sampleCount) rejectionReason=\(reason) stateBefore=dragging stateAfter=expanded")
        #endif
        return true
    }

    private func trackGrip(_ event: NSEvent) -> Bool {
        guard visibility == .dragging, var drag = gripDrag else { return false }
        drag.motion.append(PointerSample(event, in: panel))
        let delta = drag.motion.translation
        let moved = drag.hasMoved || hypot(delta.width, delta.height) >= Motion.windowDragThreshold
        drag.hasMoved = moved
        if moved { panel.setFrameOrigin(CGPoint(x: drag.frame.minX + delta.width, y: drag.frame.minY + delta.height)) }
        let screen = NSScreen.screens.first { $0.frame.contains(drag.motion.latest.point) }
        if let screen, screen.displayID != drag.initialScreen { drag.crossedDisplay = true }
        let releaseScreen = screen ?? Self.screen(for: panel.frame)
        let frame = releaseScreen?.frame ?? boundary(for: panel.frame)
        let blocker: String?
        if screen == nil { blocker = "outsideKnownScreens" }
        else if state.editor != nil || state.dialog != nil || TaskPanel.hasActiveComposition { blocker = "editingOrModal" }
        else { blocker = nil }
        let decision = FlingIntent.evaluate(drag.motion, window: panel.frame,
                                            visible: releaseScreen?.visibleFrame ?? frame, display: frame,
                                            neighbors: NSScreen.screens.filter { $0 != releaseScreen }.map(\.frame),
                                            crossedDisplay: drag.crossedDisplay, blockedBy: blocker)
        let edge = decision.shouldCollapse ? decision.targetEdge : nil
        if event.type == .leftMouseUp {
            gripDrag = nil
            visibility = .expanded
            hidePreview()
            if let edge, let screen {
                let rest = PanelLayout.reachable(panel.frame, in: screen.visibleFrame)
                recordUserFrame(rest)
                placement = nil
                saveFrame()
                collapse(to: edge, velocity: decision.velocity, on: screen)
            } else if moved || panel.frame != drag.frame {
                finishMove(allowAutoTuck: !drag.crossedDisplay)
            } else {
                fit()
            }
            #if DEBUG
            emitGesture("mouseUp samples=\(drag.motion.sampleCount) releaseVelocityX=\(decision.velocity.dx) releaseVelocityY=\(decision.velocity.dy) dragDistanceX=\(delta.width) dragDistanceY=\(delta.height) predictedEndX=\(decision.predictedEndX) targetEdge=\(decision.targetEdge?.rawValue ?? "none") nearestScreen=\(releaseScreen?.displayID ?? 0) shouldCollapse=\(decision.shouldCollapse) rejectionReason=\(decision.rejection ?? "none") stateBefore=dragging stateAfter=\(visibility)")
            #endif
        } else {
            if let edge, let screen {
                preview(edge, on: screen)
                if !drag.gaveFeedback {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    drag.gaveFeedback = true
                }
            } else if drag.candidate != nil {
                hidePreview()
            }
            drag.candidate = edge
            gripDrag = drag
        }
        return true
    }

    private func preview(_ edge: ScreenEdge, on screen: NSScreen) {
        let location = EdgePlacement(displayID: screen.displayID, edge: edge, centerY: panel.frame.midY, in: screen.visibleFrame)
        configureTab(for: edge)
        tab.interaction.isPreview = true
        tab.alphaValue = 0.42
        tab.ignoresMouseEvents = true
        tab.setFrame(location.frame(in: screen.visibleFrame), display: true)
        if !tab.isVisible { tab.orderFrontRegardless() }
    }

    private func hidePreview() {
        guard tab.interaction.isPreview else { return }
        tab.orderOut(nil)
        tab.interaction.isPreview = false
        tab.alphaValue = 1
        tab.ignoresMouseEvents = false
    }


    #if DEBUG
    var gestureProbe: ((String) -> Void)?

    private func emitGesture(_ message: String) {
        Self.gestureLog.debug("\(message, privacy: .public)")
        gestureProbe?(message)
    }

    private static let gestureLog = Logger(subsystem: "io.lumatodo.mac", category: "window-gesture")
    #endif

    func windowWillStartLiveResize(_ notification: Notification) {
        // AppKit also reports live-resize callbacks for some animator-driven frame changes.
        guard visibility == .expanded, mouseIsDragging else { return }
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
        panel.invalidateShadow()
    }

    private var mouseIsDragging: Bool {
        if NSEvent.pressedMouseButtons & 1 != 0 { return true }
        let event = NSApp.currentEvent?.type
        return event == .leftMouseDragged || event == .leftMouseDown
    }

    private func fit() {
        guard !resizing, visibility != .dragging, visibility != .pullingTab else { return }
        let visible = boundary(for: fullFrame)
        if state.panelDisplayHeight != visible.height { state.panelDisplayHeight = visible.height }
        if state.panelManualHeight != manualSize?.height { state.panelManualHeight = manualSize?.height }
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
        let changed = target != targetFrame
        targetFrame = target
        guard visibility != .collapsing, visibility != .expanding else { return }
        updateSizeConstraints(in: visible)
        switch visibility {
        case .collapsing, .expanding, .dragging, .pullingTab: return
        case .collapsed:
            positionTab()
        case .expanded where panel.isVisible:
            if target != panel.frame {
                // The list topology and AppKit viewport advance together.
                panel.setFrame(target, display: true)
                panel.invalidateShadow()
            }
        case .expanded, .hidden:
            if panel.frame != target { panel.setFrame(target, display: false) }
        }
        if changed, state.editor == nil { saveFrame() }
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
        updateInteractivity()
    }

    private func finishMove(allowAutoTuck: Bool = true) {
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
        if moved {
            placement = nil
            savePlacement()
        }
        if allowAutoTuck, moved, prefs.snapToEdge, prefs.autoHide, distance <= 7,
           !(panel.firstResponder is NSTextView), state.editor == nil, state.dialog == nil {
            collapse(to: preferredEdge(closest))
        } else if raw != frame {
            panel.setFrame(frame, display: true)
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

    private func collapse(to edge: ScreenEdge, velocity: CGVector = .zero, on releaseScreen: NSScreen? = nil) {
        let screen = releaseScreen ?? Self.screen(for: targetFrame)
        let visible = screen?.visibleFrame ?? boundary(for: targetFrame)
        if placement?.edge != edge || placement?.displayID != screen?.displayID {
            placement = EdgePlacement(displayID: screen?.displayID, edge: edge, centerY: targetFrame.midY, in: visible)
        }
        panel.makeFirstResponder(nil)
        startMorph(toEdge: true, velocity: velocity)
    }

    private func finishCollapse() {
        panel.orderOut(nil)
        tabPullDestination = nil
        let moved = tabPullSession != nil
        tabPullSession = nil
        visibility = .collapsed
        positionTab()
        setTabConcealed(false)
        tab.orderFrontRegardless()
        tab.displayIfNeeded()
        morph.retireAfterHandoff()
        if moved { saveFrame() }
        savePlacement()
        warmPreview(size: targetFrame.size)
    }

    private func expand() {
        tab.cancelDrag()
        startMorph(toEdge: false)
    }

    private func startMorph(toEdge: Bool, velocity: CGVector = .zero) {
        guard let placement else { return }
        if !toEdge { fit(); panel.setFrame(targetFrame, display: false) }
        positionTab()
        let windowFrame = toEdge ? panel.frame : targetFrame
        visibility = toEdge ? .collapsing : .expanding
        updateInteractivity()
        if prefs.animations {
            let geometry = MorphGeometry(window: windowFrame, tab: tab.frame, windowRadius: state.mini ? 23 : 26,
                                         pullEdge: toEdge ? nil : placement.edge)
            let snapshot = makePreview(size: windowFrame.size)
            morph.start(geometry: geometry, snapshot: snapshot, from: toEdge ? panel : tab, edge: placement.edge, values: prefs,
                        intensity: state.preferences.motionIntensity, toEdge: toEdge, velocity: velocity,
                        reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                        onPresented: { [weak self] in
                self?.panel.orderOut(nil)
                self?.tab.orderOut(nil)
            }) { [weak self] collapsed in
                if collapsed { self?.finishCollapse() }
                else { self?.finishExpansion() }
            }
        } else if toEdge {
            finishCollapse()
        } else {
            tab.orderOut(nil)
            finishExpansion()
        }
    }

    private func retarget(toEdge: Bool) {
        visibility = toEdge ? .collapsing : .expanding
        morph.retarget(toEdge: toEdge, intensity: state.preferences.motionIntensity)
    }

    private func tabPullConfiguration() -> (ScreenEdge, EdgePullTuning)? {
        guard visibility == .collapsed, let placement else { return nil }
        let visible = screenForPlacement()?.visibleFrame ?? boundary(for: targetFrame)
        return (placement.edge, EdgePullTuning(windowWidth: targetFrame.width, displayWidth: visible.width))
    }

    private func beginTabPull(anchor: CGFloat) {
        guard visibility == .collapsed, let placement else { return }
        let size = targetFrame.size
        let visible = screenForPlacement()?.visibleFrame ?? boundary(for: targetFrame)
        let destination = MorphGeometry.pullDestination(window: targetFrame, tab: tab.frame, edge: placement.edge, visible: visible)
        let geometry = MorphGeometry(window: destination, tab: tab.frame, windowRadius: state.mini ? 23 : 26,
                                     pullEdge: placement.edge, verticalBounds: visible)
        tabPullSession = TabPullSession(geometry: geometry, visible: visible, placement: placement, centerY: tab.frame.midY)
        visibility = .pullingTab
        let key = previewKey(size: size)
        morph.startPull(geometry: geometry, snapshot: previewCache?.key == key ? previewCache?.image : nil,
                        from: tab, edge: placement.edge, values: prefs, anchor: anchor,
                        reduced: !prefs.animations || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                        onPresented: { [weak self] in self?.setTabConcealed(true) }) { [weak self] collapsed in
            if collapsed { self?.finishCollapse() }
            else { self?.finishExpansion() }
        }
        if previewCache?.key != key { warmPreview(size: size) }
    }

    private func updateTabPull(_ gesture: EdgePullGesture) {
        guard visibility == .pullingTab, var session = tabPullSession else { return }
        let tab = session.geometry.tab
        let margin = min(4, max(0, (session.visible.height - tab.height) / 2))
        session.centerY = min(session.visible.maxY - margin - tab.height / 2,
                              max(session.visible.minY + margin + tab.height / 2, tab.midY + gesture.motion.translation.height))
        tabPullSession = session
        morph.updatePull(opening: gesture.progress, centerY: session.centerY, velocity: gesture.motion.velocity)
    }

    private func endTabPull(_ result: EdgePullGesture.Release, velocity: Double) {
        guard visibility == .pullingTab, let session = tabPullSession else { return }
        let expand = result != .stay
        if result == .click {
            if !prefs.animations {
                tabPullSession = nil
                finishExpansion()
                return
            }
            morph.useClickDestination(targetFrame)
        } else {
            if abs(session.centerY - session.geometry.tab.midY) > 0.5 {
                placement = EdgePlacement(displayID: session.placement.displayID, edge: session.placement.edge,
                                          centerY: session.centerY, in: session.visible)
                alignRestoration(to: session.centerY, in: session.visible)
            }
            if expand {
                tabPullDestination = session.geometry.frame(at: 0, centerY: session.centerY, within: session.visible)
            }
        }
        visibility = expand ? .expanding : .collapsing
        updateInteractivity()
        #if DEBUG
        emitGesture("edgePull y=\(session.centerY) progressVelocity=\(velocity) result=\(result)")
        #endif
        morph.finishPull(expand: expand, velocity: velocity, intensity: state.preferences.motionIntensity)
    }

    private func previewKey(size: CGSize) -> PreviewKey {
        PreviewKey(size: size, revision: state.panelSnapshotRevision, appearance: panel.effectiveAppearance.name,
                   preferences: prefs, folded: state.collapsedGroups, undo: state.presentedUndo,
                   scrollOffset: state.panelScrollOffset, selection: state.selectedTask,
                   minute: Int(Date.now.timeIntervalSinceReferenceDate / 60), mini: state.mini, searching: state.searching)
    }

    private func makePreview(size: CGSize) -> NSImage? {
        let key = previewKey(size: size)
        if let previewCache, previewCache.key == key { return previewCache.image }
        let image = WindowMorph.snapshot(state: state, size: size, window: panel)
        previewCache = (key, image)
        return image
    }

    private func warmPreview(size: CGSize) {
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, [.collapsed, .pullingTab, .expanding].contains(visibility) else { return }
            let image = makePreview(size: size)
            if visibility != .collapsed { morph.setPreview(image) }
        }
    }

    @objc private func cancelTabTracking() {
        _ = tab.cancelDrag()
    }

    private func setTabConcealed(_ concealed: Bool) {
        // Preserve the NSWindow that owns the original mouse-down until its drag ends.
        tab.contentView?.isHidden = concealed
        tab.hasShadow = !concealed
    }

    private func positionTab() {
        guard var placement else { return }
        let screen = screenForPlacement()
        let visible = screen?.visibleFrame ?? boundary(for: targetFrame)
        if placement.displayID != screen?.displayID {
            placement = EdgePlacement(displayID: screen?.displayID, edge: placement.edge,
                                      centerY: placement.frame(in: visible).midY, in: visible)
            self.placement = placement
            alignRestoration(to: placement.frame(in: visible).midY, in: visible)
            saveTabMove()
        }
        configureTab(for: placement.edge)
        let frame = placement.frame(in: visible)
        if tab.frame != frame { tab.setFrame(frame, display: true) }
    }

    private func configureTab(for edge: ScreenEdge) {
        guard tabEdge != edge else { return }
        tabEdge = edge
        let host = EdgeTabHost(rootView: EdgeTabView(state: state, interaction: tab.interaction, edge: edge) { [weak self] in self?.show() })
        host.sizingOptions = []
        tab.contentView = host
    }

    private func alignRestoration(to centerY: CGFloat, in visible: NSRect) {
        targetFrame.origin.y = centerY - targetFrame.height / 2
        targetFrame = PanelLayout.reachable(targetFrame, in: visible)
        fullFrame = PanelLayout.resized(targetFrame, width: fullFrame.width, height: fullFrame.height, in: visible)
    }

    private func screenForPlacement() -> NSScreen? {
        if let id = placement?.displayID, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return Self.screen(for: targetFrame)
    }


    private func preferredEdge(_ nearest: ScreenEdge) -> ScreenEdge {
        switch state.preferences.tuckSide {
        case .left: .left
        case .right: .right
        case .nearest: nearest
        }
    }

    private func saveTabMove() {
        saveFrame()
        savePlacement()
    }

    private func savePlacement() {
        guard prefs.rememberPosition else { return }
        let defaults = state.preferences.defaults
        defaults.set(visibility == .collapsed || visibility == .pullingTab, forKey: "window.collapsed")
        if let placement, let data = try? JSONEncoder().encode(placement) {
            defaults.set(data, forKey: "window.edgePlacement")
        } else {
            defaults.removeObject(forKey: "window.edgePlacement")
        }
    }

    private func updateInteractivity() {
        let transitioning = visibility == .collapsing || visibility == .expanding || visibility == .pullingTab
        panel.ignoresMouseEvents = transitioning
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

    private static func screen(for frame: NSRect) -> NSScreen? {
        let screen = NSScreen.screens.max { left, right in
            let a = left.frame.intersection(frame)
            let b = right.frame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }
        if let screen, screen.frame.intersects(frame) { return screen }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func visibleFrame(for frame: NSRect) -> NSRect {
        screen(for: frame)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    }

    private func boundary(for frame: NSRect) -> NSRect { Self.visibleFrame(for: frame) }
    private func reachable(_ frame: NSRect) -> NSRect { PanelLayout.reachable(frame, in: boundary(for: frame)) }
}

private extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}
