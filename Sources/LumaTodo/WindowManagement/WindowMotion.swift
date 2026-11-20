import AppKit
import SwiftUI

enum Motion {
    static let tabDragThreshold: CGFloat = 5
    static let windowDragThreshold: CGFloat = 3
    static let completionHold = Duration.milliseconds(155)
    static let rowDeparture = Duration.milliseconds(85)
    static let rowArrival = Duration.milliseconds(150)
    static let rowDepartureAnimation = Animation.easeOut(duration: 0.08)
    static let rowArrivalAnimation = Animation.easeOut(duration: 0.14)
    static let completionDraw = 0.14
    static let completionErase = 0.10
    static let completionDrawDelay = 0.035

    static func list(_ intensity: MotionIntensity) -> Animation {
        .spring(duration: 0.27, bounce: intensity.bounce / 3)
    }

}

struct PointerSample {
    var point: CGPoint
    let time: TimeInterval

    @MainActor init(_ event: NSEvent, in window: NSWindow) {
        // Quartz reports a global cursor even when the window moves under the drag.
        if let quartz = event.cgEvent?.location {
            point = CGPoint(x: quartz.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - quartz.y)
        } else {
            point = window.convertPoint(toScreen: event.locationInWindow)
        }
        time = event.timestamp
    }

    init(point: CGPoint, time: TimeInterval) {
        self.point = point
        self.time = time
    }
}

struct DragMotion {
    let start: PointerSample
    private(set) var latest: PointerSample
    private(set) var sampleCount = 1
    private var recent: [PointerSample]

    init(start: PointerSample) {
        self.start = start
        latest = start
        recent = [start]
    }

    var translation: CGSize { CGSize(width: latest.point.x - start.point.x, height: latest.point.y - start.point.y) }

    mutating func append(_ sample: PointerSample) {
        guard sample.time >= latest.time else { return }
        sampleCount += 1
        if sample.time == latest.time {
            recent[recent.count - 1] = sample
        } else {
            while recent.count > 1, recent[1].time < sample.time - 0.16 { recent.removeFirst() }
            recent.append(sample)
        }
        latest = sample
    }

    /// Fit recent moving samples. A repeated mouse-up coordinate preserves a
    /// prompt release but a stationary pause must not preserve stale momentum.
    var velocity: CGVector {
        guard let end = lastMovement else { return .zero }
        let pause = latest.time - end.time
        guard pause <= 0.085 else { return .zero }
        var samples = recent.filter { $0.time <= end.time && end.time - $0.time <= 0.105 }
        if samples.count < 2, let prior = recent.last(where: { $0.time < end.time && end.time - $0.time <= 0.16 }) {
            samples.insert(prior, at: 0)
        }
        guard let first = samples.first, end.time - first.time >= 0.014 else { return .zero }
        var weight = 0.0
        var timeSum = 0.0
        var squareSum = 0.0
        var pointSum = CGVector.zero
        var timePointSum = CGVector.zero
        for sample in samples {
            let t = sample.time - end.time
            let w = 1 + max(0, 1 + t / 0.105)
            let x = sample.point.x - end.point.x
            let y = sample.point.y - end.point.y
            weight += w
            timeSum += w * t
            squareSum += w * t * t
            pointSum.dx += w * x
            pointSum.dy += w * y
            timePointSum.dx += w * t * x
            timePointSum.dy += w * t * y
        }
        let variance = squareSum - timeSum * timeSum / weight
        guard variance > 0 else { return .zero }
        let decay = min(1, max(0, (0.085 - pause) / 0.055))
        return CGVector(dx: (timePointSum.dx - timeSum * pointSum.dx / weight) / variance * decay,
                        dy: (timePointSum.dy - timeSum * pointSum.dy / weight) / variance * decay)
    }

    private var lastMovement: PointerSample? {
        for (previous, current) in zip(recent, recent.dropFirst()).reversed() {
            if hypot(current.point.x - previous.point.x, current.point.y - previous.point.y) >= 0.35 { return current }
        }
        return nil
    }

    var recentReversal: Bool {
        let totalX = translation.width
        guard totalX != 0, let end = lastMovement, let earlier = recent.last(where: {
            end.time - $0.time >= 0.014 && end.time - $0.time <= 0.065
        }) else { return false }
        let dx = end.point.x - earlier.point.x
        return abs(dx) >= 7 && dx * totalX < 0
    }
}

struct EdgePullTuning {
    let knee: CGFloat
    let reach: CGFloat

    init(windowWidth: CGFloat, displayWidth: CGFloat) {
        reach = min(max(132, windowWidth * 0.56), 260, max(75, displayWidth * 0.34))
        knee = min(max(43, windowWidth * 0.15), 66, reach * 0.49)
    }

    func progress(at distance: CGFloat) -> Double {
        let distance = max(0, distance)
        let scale: CGFloat = 26
        let earlyProgress = 0.10
        let normalization = (scale + knee) / knee
        if distance <= knee { return earlyProgress * normalization * distance / (scale + distance) }
        let t = min(1, (distance - knee) / (reach - knee))
        let tangent = earlyProgress * normalization * scale / pow(scale + knee, 2) * (reach - knee)
        return earlyProgress + (1 - earlyProgress) * t * t * (3 - 2 * t) + tangent * t * pow(1 - t, 2)
    }

    func velocity(at distance: CGFloat, pointerVelocity: CGFloat) -> Double {
        (progress(at: distance + 0.5) - progress(at: distance - 0.5)) * pointerVelocity
    }
}

struct EdgePullGesture {
    enum Release { case click, stay, expand }

    let edge: ScreenEdge
    let tuning: EdgePullTuning
    private(set) var motion: DragMotion
    private(set) var dragging = false
    private(set) var ready = false

    init(edge: ScreenEdge, tuning: EdgePullTuning, start: PointerSample) {
        self.edge = edge
        self.tuning = tuning
        motion = DragMotion(start: start)
    }

    private var direction: CGFloat { edge == .left ? 1 : -1 }
    var inwardDistance: CGFloat { motion.translation.width * direction }
    var inwardVelocity: CGFloat { motion.velocity.dx * direction }
    var progress: Double { tuning.progress(at: inwardDistance) }
    var progressVelocity: Double { tuning.velocity(at: inwardDistance, pointerVelocity: inwardVelocity) }

    mutating func append(_ sample: PointerSample) {
        motion.append(sample)
        let delta = motion.translation
        if !dragging { dragging = hypot(delta.width, delta.height) >= Motion.tabDragThreshold }
        if dragging { ready = progress >= (ready ? 0.65 : 0.74) }
    }

    var release: Release {
        guard dragging else {
            return motion.latest.time - motion.start.time <= 0.52 ? .click : .stay
        }
        let velocity = inwardVelocity
        guard inwardDistance > 0, !motion.recentReversal, velocity > -240 else { return .stay }
        let prediction = tuning.progress(at: inwardDistance + max(0, velocity) * 0.12)
        return ready || (progress >= 0.52 && velocity >= 420 && prediction >= 0.74) ? .expand : .stay
    }
}

struct FlingDecision {
    let velocity: CGVector
    let predictedEndX: CGFloat
    let targetEdge: ScreenEdge?
    let rejection: String?
    var shouldCollapse: Bool { targetEdge != nil && rejection == nil }
}

struct FlingIntent {
    let edge: ScreenEdge
    let velocity: CGVector

    static func detect(_ drag: DragMotion, window: CGRect, visible: CGRect, display: CGRect,
                       neighbors: [CGRect], crossedDisplay: Bool) -> Self? {
        let decision = evaluate(drag, window: window, visible: visible, display: display,
                                neighbors: neighbors, crossedDisplay: crossedDisplay)
        guard decision.shouldCollapse, let edge = decision.targetEdge else { return nil }
        return Self(edge: edge, velocity: decision.velocity)
    }

    static func evaluate(_ drag: DragMotion, window: CGRect, visible: CGRect, display: CGRect,
                         neighbors: [CGRect], crossedDisplay: Bool, blockedBy: String? = nil) -> FlingDecision {
        let speed = drag.velocity
        let distance = drag.translation
        let edge: ScreenEdge? = speed.dx == 0 ? nil : speed.dx < 0 ? .left : .right
        let predicted = drag.latest.point.x + speed.dx * 0.22
        func decision(_ reason: String?) -> FlingDecision {
            FlingDecision(velocity: speed, predictedEndX: predicted, targetEdge: edge, rejection: reason)
        }
        if let blockedBy { return decision(blockedBy) }
        guard !crossedDisplay else { return decision("crossedDisplay") }
        guard abs(distance.width) >= 60 else { return decision("shortDrag") }
        guard abs(distance.width) > abs(distance.height) * 1.30,
              abs(speed.dx) >= abs(speed.dy) * 1.40 else { return decision("verticalDominant") }
        guard !drag.recentReversal else { return decision("reversedBeforeRelease") }
        guard let edge else { return decision("noReleaseMomentum") }
        guard distance.width * speed.dx > 0 else { return decision("releaseDirectionMismatch") }
        let remaining = max(0, edge == .left ? window.minX - visible.minX : visible.maxX - window.maxX)
        let requiredSpeed = 900 + min(200, remaining * 0.7)
        guard abs(speed.dx) >= requiredSpeed else { return decision("belowHorizontalSpeed") }
        guard remaining <= abs(speed.dx) * 0.22 + 24 else { return decision("projectedWindowTooFar") }
        let projectedY = min(display.maxY - 1, max(display.minY + 1, drag.latest.point.y + speed.dy * 0.16))
        let exteriorX = edge == .left ? display.minX - 1 : display.maxX + 1
        let probe = CGPoint(x: exteriorX, y: projectedY)
        guard !neighbors.contains(where: { $0.insetBy(dx: -2, dy: 0).contains(probe) }) else {
            return decision("adjacentDisplay")
        }
        return decision(nil)
    }
}

struct MorphSpring {
    var start: Double
    var target: Double
    var velocity: Double
    let response: Double
    let damping: Double

    func sample(at time: TimeInterval) -> (position: Double, velocity: Double) {
        let attenuation = damping * response
        let frequency = response * sqrt(1 - damping * damping)
        let offset = start - target
        let b = (velocity + attenuation * offset) / frequency
        let wave = cos(frequency * time) * offset + sin(frequency * time) * b
        let slope = frequency * (-sin(frequency * time) * offset + cos(frequency * time) * b)
        let envelope = exp(-attenuation * time)
        return (target + wave * envelope, (slope - attenuation * wave) * envelope)
    }
}

struct MorphGeometry {
    let window: CGRect
    let tab: CGRect
    let windowRadius: CGFloat
    var pullEdge: ScreenEdge? = nil
    var verticalBounds: CGRect? = nil

    private static let contentExitProgress = 0.14

    static func pullDestination(window: CGRect, tab: CGRect, edge: ScreenEdge, visible: CGRect) -> CGRect {
        let gap = min(95, max(20, window.width * 0.23))
        let x = edge == .left ? min(window.minX, tab.minX + gap) : max(window.minX, tab.maxX - window.width - gap)
        return PanelLayout.reachable(CGRect(origin: CGPoint(x: x, y: window.minY), size: window.size), in: visible)
    }

    var canvas: CGRect {
        var area = window.union(tab).union(frame(at: Self.contentExitProgress)).insetBy(dx: -12, dy: -12).integral
        if let verticalBounds {
            area.origin.y = verticalBounds.minY
            area.size.height = verticalBounds.height
        }
        return area
    }

    func contentOpacity(at progress: Double) -> Double {
        let fade = min(1, max(0, progress / Self.contentExitProgress))
        return 1 - fade * fade * (3 - 2 * fade)
    }
    var horizontalTravel: CGFloat { tab.midX - window.midX }

    func frame(at progress: Double) -> CGRect {
        let p = min(1, max(0, progress))
        if let pullEdge {
            let opening = 1 - p
            let shape = Self.smooth((opening - 0.07) / 0.79)
            let inward = 10 * sin(.pi / 2 * min(1, opening / 0.115)) * (1 - shape)
            let width = tab.width + (window.width - tab.width) * shape + 2.5 * inward / 10
            let height = tab.height + (window.height - tab.height) * shape
            let x = pullEdge == .left
                ? tab.minX + (window.minX - tab.minX) * shape + inward
                : tab.maxX + (window.maxX - tab.maxX) * shape - inward - width
            return CGRect(x: x, y: tab.midY + (window.midY - tab.midY) * shape - height / 2,
                          width: width, height: height)
        }
        // Content finishes fading at full size before the shell starts to narrow.
        let shrink = max(0, (p - Self.contentExitProgress) / (1 - Self.contentExitProgress))
        let shape = shrink * (0.62 + 0.38 * shrink * (3 - 2 * shrink))
        let size = CGSize(width: window.width + (tab.width - window.width) * shape,
                          height: window.height + (tab.height - window.height) * shape)
        return CGRect(x: window.midX + (tab.midX - window.midX) * p - size.width / 2,
                      y: window.midY + (tab.midY - window.midY) * p - size.height / 2,
                      width: size.width, height: size.height)
    }

    func frame(at progress: Double, centerY: CGFloat, within bounds: CGRect) -> CGRect {
        var frame = frame(at: progress)
        frame.origin.y = min(bounds.maxY - frame.height, max(bounds.minY, centerY - frame.height / 2))
        return frame
    }

    func radius(at progress: Double) -> CGFloat {
        let p = min(1, max(0, progress))
        return windowRadius + (tab.width / 2 - windowRadius) * p
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

@MainActor
final class WindowMorph: NSObject {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
    private let renderer = FluidRenderer()
    private var displayLink: CADisplayLink?
    private var geometry: MorphGeometry?
    private var edge = ScreenEdge.right
    private var progress = 0.0
    private var inputProgress = 0.0
    private var inputY: CGFloat?
    private var pressure: CGFloat = 0
    private var pressureTarget: CGFloat = 0
    private var anchor: CGFloat = 0.5
    private var shear: CGFloat = 0
    private var shearTarget: CGFloat = 0
    private var lastInputTime: CFTimeInterval = 0
    private var verticalVelocity: CGFloat = 0
    private var verticalDrift: CGFloat = 0
    private var spring: MorphSpring?
    private var started: CFTimeInterval = 0
    private var firstStarted: CFTimeInterval = 0
    private var lastSampleTime: CFTimeInterval = 0
    private var reduced = false
    private var interactive = false
    private var pulled = false
    private var needsDraw = false
    private var onPresented: (() -> Void)?
    private var onEnd: ((Bool) -> Void)?
    private var retirementFrames = 0
    var onFrame: ((CFTimeInterval) -> Void)?

    var currentFrame: CGRect? {
        guard spring != nil || interactive else { return nil }
        return renderedFrame
    }

    private var renderedFrame: CGRect? {
        guard let geometry else { return nil }
        if let inputY, let visible = geometry.verticalBounds {
            return geometry.frame(at: progress, centerY: inputY, within: visible)
        }
        return geometry.frame(at: progress).offsetBy(dx: 0, dy: verticalDrift)
    }

    override init() {
        super.init()
        panel.title = "LumaTodo Transition"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setAccessibilityElement(false)
        panel.contentView = renderer
    }

    func start(geometry: MorphGeometry, snapshot: NSImage?, from source: NSWindow, edge: ScreenEdge,
               values: PreferencesValues, intensity: MotionIntensity, toEdge: Bool, velocity: CGVector,
               reduced: Bool, onPresented: @escaping () -> Void, onEnd: @escaping (Bool) -> Void) {
        let initial = toEdge ? 0.0 : 1.0
        prepare(geometry: geometry, snapshot: snapshot, from: source, edge: edge, values: values,
                progress: initial, reduced: reduced, onPresented: onPresented, onEnd: onEnd)
        let travel = geometry.horizontalTravel
        let initialVelocity = abs(travel) >= 30 ? velocity.dx / travel : 0
        verticalVelocity = min(650, max(-650, velocity.dy))
        drive(from: initial, to: toEdge ? 1 : 0, velocity: min(13, max(0, initialVelocity)), intensity: intensity)
    }

    func startPull(geometry: MorphGeometry, snapshot: NSImage?, from source: NSWindow, edge: ScreenEdge,
                   values: PreferencesValues, anchor: CGFloat, reduced: Bool,
                   onPresented: @escaping () -> Void, onEnd: @escaping (Bool) -> Void) {
        prepare(geometry: geometry, snapshot: snapshot, from: source, edge: edge, values: values,
                progress: 1, reduced: reduced, onPresented: onPresented, onEnd: onEnd)
        interactive = true
        pulled = true
        inputY = geometry.tab.midY
        self.anchor = anchor
        pressureTarget = reduced ? 0 : 1
        startDisplayLink()
    }

    func updatePull(opening: Double, centerY: CGFloat, velocity: CGVector) {
        guard interactive else { return }
        let newProgress = 1 - opening
        needsDraw = needsDraw || inputY != centerY || inputProgress != newProgress
        inputProgress = newProgress
        inputY = centerY
        shearTarget = reduced ? 0 : min(5, max(-5, (-velocity.dy + (edge == .left ? -0.24 : 0.24) * velocity.dx) / 240))
        pressureTarget = reduced ? 0 : max(0.28, 1 - opening * 1.5)
        lastInputTime = CACurrentMediaTime()
    }

    func useClickDestination(_ window: CGRect) {
        guard var geometry, interactive else { return }
        geometry = MorphGeometry(window: window, tab: geometry.tab, windowRadius: geometry.windowRadius, pullEdge: edge)
        self.geometry = geometry
        inputY = nil
        let canvas = panel.frame.union(geometry.canvas)
        if panel.frame != canvas {
            // Rebase the existing path in the same transaction if the remembered window is farther away.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(canvas, display: false)
            draw()
            CATransaction.commit()
        }
        needsDraw = true
    }

    func setPreview(_ image: NSImage?) {
        guard geometry != nil else { return }
        renderer.setPreview(image)
    }

    func finishPull(expand: Bool, velocity: Double, intensity: MotionIntensity) {
        guard interactive else { return }
        interactive = false
        pressureTarget = 0
        shearTarget = 0
        drive(from: inputProgress, to: expand ? 0 : 1,
              velocity: min(8, max(-8, -velocity)), intensity: intensity)
    }

    private func prepare(geometry: MorphGeometry, snapshot: NSImage?, from source: NSWindow, edge: ScreenEdge,
                         values: PreferencesValues, progress: Double, reduced: Bool,
                         onPresented: @escaping () -> Void, onEnd: @escaping (Bool) -> Void) {
        reset()
        self.geometry = geometry
        self.edge = edge
        self.reduced = reduced
        self.onPresented = onPresented
        self.onEnd = onEnd
        self.progress = progress
        inputProgress = progress
        panel.appearance = source.appearance
        panel.collectionBehavior = source.collectionBehavior
        panel.level = source.level
        let canvas = geometry.canvas
        if panel.frame != canvas { panel.setFrame(canvas, display: false) }
        renderer.configure(values: values, appearance: source.effectiveAppearance, scale: source.backingScaleFactor)
        renderer.setPreview(snapshot)
        draw()
        if source.isVisible { panel.order(.below, relativeTo: source.windowNumber) }
        else { panel.orderFrontRegardless() }
    }

    func retarget(toEdge: Bool, intensity: MotionIntensity) {
        guard let spring else { return }
        let target = toEdge ? 1.0 : 0.0
        guard target != spring.target else { return }
        let current = value(at: max(CACurrentMediaTime(), lastSampleTime))
        drive(from: current.position, to: target, velocity: current.velocity, intensity: intensity)
    }

    func stop() {
        reset()
        renderer.clear()
        panel.orderOut(nil)
    }

    private func reset() {
        displayLink?.invalidate()
        displayLink = nil
        spring = nil
        interactive = false
        pulled = false
        inputY = nil
        pressure = 0
        pressureTarget = 0
        shear = 0
        shearTarget = 0
        anchor = 0.5
        lastInputTime = 0
        needsDraw = false
        verticalVelocity = 0
        verticalDrift = 0
        geometry = nil
        lastSampleTime = 0
        onPresented = nil
        onEnd = nil
        retirementFrames = 0
    }

    func retireAfterHandoff() {
        guard displayLink != nil else { renderer.clear(); return }
        retirementFrames = 3
        spring = nil
        interactive = false
        onPresented = nil
    }

    private func drive(from: Double, to: Double, velocity: Double, intensity: MotionIntensity) {
        let distance = abs(geometry?.horizontalTravel ?? 0)
        let response = pulled && to == 1 ? 32 : 23 - min(4, distance / 145)
        spring = MorphSpring(start: from, target: to, velocity: velocity, response: response,
                             damping: pulled && to == 1 ? 0.94 : (intensity == .standard ? 0.88 : 0.99))
        started = CACurrentMediaTime()
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let clock = panel.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = clock
        clock.add(to: .main, forMode: .common)
    }

    private func value(at now: CFTimeInterval) -> (position: Double, velocity: Double) {
        guard let spring else { return (progress, 0) }
        let elapsed = max(0, now - started)
        if !reduced { return spring.sample(at: elapsed) }
        let ratio = min(1, elapsed / 0.13)
        return (spring.start + (spring.target - spring.start) * ratio, 0)
    }

    @objc private func tick(_ clock: CADisplayLink) {
        if retirementFrames > 0 {
            retirementFrames -= 1
            if retirementFrames == 0 {
                renderer.clear()
                reset()
            }
            return
        }
        if let onPresented {
            if lastSampleTime == 0 {
                lastSampleTime = clock.timestamp
                panel.displayIfNeeded()
                return
            }
            self.onPresented = nil
            started = clock.timestamp
            firstStarted = clock.timestamp
            panel.orderFrontRegardless()
            onPresented()
        }
        let interval = min(0.05, max(0, clock.timestamp - lastSampleTime))
        lastSampleTime = clock.timestamp
        let desiredShear = clock.timestamp - lastInputTime > 0.055 ? 0 : shearTarget
        if abs(shear - desiredShear) > 0.04 {
            shear += (desiredShear - shear) * (1 - exp(-interval * 25))
            needsDraw = true
        }
        if abs(pressure - pressureTarget) > 0.015 {
            pressure += (pressureTarget - pressure) * (1 - exp(-interval * 28))
            needsDraw = true
        }
        var reachedEndpoint: Double?
        if let spring {
            let current = value(at: clock.targetTimestamp)
            progress = current.position
            let elapsed = max(0, clock.targetTimestamp - firstStarted)
            if !reduced { verticalDrift = verticalVelocity * elapsed * exp(-26 * elapsed) }
            needsDraw = true
            let limit = reduced ? 0.13 : (pulled && spring.target == 1 ? 0.30 : 0.53)
            if clock.targetTimestamp - started >= limit ||
                (!reduced && abs(current.position - spring.target) < 0.003 && abs(current.velocity) < 0.09) {
                reachedEndpoint = spring.target
                progress = spring.target
                pressure = 0
                shear = 0
                verticalDrift = 0
            }
        } else if interactive {
            progress = inputProgress
        }
        if needsDraw { draw() }
        onFrame?(clock.timestamp)
        if let reachedEndpoint {
            spring = nil
            let completion = onEnd
            onEnd = nil
            completion?(reachedEndpoint == 1)
        }
    }

    private func draw() {
        guard let geometry, let frame = renderedFrame else { return }
        needsDraw = false
        let p = min(1, max(0, progress))
        let opening = 1 - p
        let extent = panel.frame
        let offset = CGVector(dx: -extent.minX, dy: -extent.minY)
        let squeeze = reduced ? 0 : pressure * p * p * 2.1
        let body = frame.insetBy(dx: 0, dy: p * 2 + squeeze / 2).offsetBy(dx: offset.dx, dy: offset.dy)
        let gap = edge == .left ? frame.minX - geometry.tab.minX : geometry.tab.maxX - frame.maxX
        let taper = min(1, max(0, (0.28 - opening) / 0.15))
        let neck = reduced || geometry.pullEdge == nil ? 0 : min(24, max(0, gap)) * taper * taper * (3 - 2 * taper)
        let localSnapshot = CGRect(x: frame.midX - geometry.window.width / 2 + offset.dx,
                                   y: frame.midY - geometry.window.height / 2 + offset.dy,
                                   width: geometry.window.width, height: geometry.window.height)
        let contour = FluidContour(body: body, radius: geometry.radius(at: p), edge: edge, neck: neck,
                                   pressure: pressure * p * p, anchor: anchor, shear: shear * p)
        renderer.draw(contour: contour, previewFrame: localSnapshot, snapshotOpacity: geometry.contentOpacity(at: p),
                      arrowOpacity: min(1, max(0, (p - 0.78) / 0.22)), opticalMotion: shear * p, simplified: reduced)
    }

    static func snapshot(state: AppState, size: CGSize, window: NSWindow) -> NSImage? {
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let view = TaskPanelView(state: state, snapshot: true)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = min(1.5, window.backingScaleFactor)
        return renderer.nsImage
    }
}
