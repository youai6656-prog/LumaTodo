import AppKit
import QuartzCore

/// Runs identical pointer trajectories against optimized sources and reports CPU-side timings.
@main
@MainActor
final class NativeMotionProfile: NSObject {
    private var samples: [Double] = []
    private var callbacks: [CFTimeInterval] = []
    private var display: [CFTimeInterval] = []
    private var updates = 0
    private var lastVisual: CGRect?
    private var tabFrameChanges = 0
    private var lastTabFrame: CGRect = .zero

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await NativeMotionProfile().run(full: CommandLine.arguments.contains("--full"))
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    private func run(full: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "io.lumatodo.motion-profile.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("Missing preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try TaskStore(url: directory.appending(path: "Tasks.store"))
        let state = AppState(store: store, preferences: Preferences(defaults: defaults))
        state.preferences.values.animations = true
        state.preferences.tuckSide = .right
        let window = FloatingWindow(state: state)
        state.onLayoutChange = { [weak window] h, e in window?.updateLayout(height: h, editing: e) }
        store.onChange = { [weak state] in state?.updateListing() }
        let task = try store.save(TaskDraft(title: "Profile · Task one"))
        try store.save(TaskDraft(title: "Profile · Task two"))
        window.show()
        guard let main = NSApp.windows.first(where: { $0.title == "LumaTodo" }),
              let tab = NSApp.windows.first(where: { $0.title == "LumaTodo Edge" }),
              let screen = main.screen ?? NSScreen.main else { throw Failure("Missing display") }
        let refresh = Double(screen.maximumFramesPerSecond)
        let clock = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
        clock.add(to: .main, forMode: .common)
        defer { clock.invalidate() }
        window.onTransitionFrame = { [weak self, weak window] time in
            guard let self, let window else { return }
            callbacks.append(time)
            let frame = window.transitionFrame
            if frame != lastVisual { updates += 1; lastVisual = frame }
        }
        let iterations = full ? 20 : 2
        window.tuck()
        try await wait { tab.isVisible && !main.isVisible && window.transitionFrame == nil }

        func gesture(seconds: Double, points: (Double) -> CGVector) async throws {
            let center = CGPoint(x: tab.frame.midX, y: tab.frame.midY)
            try send(.leftMouseDown, point: center, to: tab)
            let begin = CACurrentMediaTime()
            var fraction = 0.0
            while fraction < 1 {
                try await Task.sleep(for: .milliseconds(8))
                fraction = min(1, (CACurrentMediaTime() - begin) / seconds)
                let delta = points(fraction)
                try send(.leftMouseDragged, point: CGPoint(x: center.x + delta.dx, y: center.y + delta.dy), to: tab)
            }
            let delta = points(1)
            try send(.leftMouseUp, point: CGPoint(x: center.x + delta.dx, y: center.y + delta.dy), to: tab)
        }

        print("ENV refreshMax=\(refresh)Hz optimized=true full=\(full)")
        fflush(nil)
        try await measure("idle", tab: tab, refresh: refresh) { try await Task.sleep(for: .seconds(1)) }
        try await measure("press", tab: tab, refresh: refresh) {
            try await gesture(seconds: 0.65) { _ in .zero }
            try await wait { tab.isVisible && window.transitionFrame == nil }
        }
        try await measure("vertical", tab: tab, refresh: refresh) {
            for _ in 0..<iterations {
                try await gesture(seconds: 0.15) { CGVector(dx: 0, dy: 42 * sin($0 * .pi)) }
                try await wait { tab.isVisible && window.transitionFrame == nil }
            }
        }
        try await measure("magnetic+return", tab: tab, refresh: refresh) {
            for _ in 0..<iterations {
                try await gesture(seconds: 0.14) { CGVector(dx: -42 * $0, dy: 0) }
                try await wait { tab.isVisible && window.transitionFrame == nil }
            }
        }
        try await measure("diagonal", tab: tab, refresh: refresh) {
            for _ in 0..<iterations {
                try await gesture(seconds: 0.22) { CGVector(dx: -54 * sin($0 * .pi), dy: 46 * sin(2 * $0 * .pi)) }
                try await wait { tab.isVisible && window.transitionFrame == nil }
            }
        }
        try await measure("continuous", tab: tab, refresh: refresh) {
            let duration: Double = full ? 60 : 3
            try await gesture(seconds: duration) { phase in
                let cycle = phase * duration * 2 * .pi
                return CGVector(dx: -80 * (1 - cos(cycle)), dy: 72 * sin(cycle))
            }
            try await wait { tab.isVisible && window.transitionFrame == nil }
        }
        try await measure("expand", tab: tab, refresh: refresh) {
            for _ in 0..<iterations {
                try await gesture(seconds: 0.18) { CGVector(dx: -220 * $0, dy: 0) }
                try await wait { main.isVisible && window.transitionFrame == nil }
                state.preferences.values.animations = false
                window.tuck()
                state.preferences.values.animations = true
            }
        }
        try await measure("collapse", tab: tab, refresh: refresh) {
            for _ in 0..<iterations {
                state.preferences.values.animations = false
                window.show()
                state.preferences.values.animations = true
                window.tuck()
                try await wait { tab.isVisible && !main.isVisible && window.transitionFrame == nil }
            }
        }
        try await measure("rapid-cycle", tab: tab, refresh: refresh) {
            for _ in 0..<(full ? 10 : 2) {
                window.show()
                try await Task.sleep(for: .milliseconds(95))
                window.tuck()
                try await wait { tab.isVisible && !main.isVisible && window.transitionFrame == nil }
            }
        }
        window.show()
        try await wait { main.isVisible && window.transitionFrame == nil }
        try await measure("tasks", tab: tab, refresh: refresh) {
            for _ in 0..<(full ? 10 : 2) {
                state.complete(task, feedback: true)
                try await Task.sleep(for: .milliseconds(420))
                state.restore(task, feedback: true)
                try await Task.sleep(for: .milliseconds(420))
            }
        }
        print("PASS: completed comparable motion profile")
    }

    private func measure(_ name: String, tab: NSWindow, refresh: Double, body: () async throws -> Void) async throws {
        samples.removeAll(keepingCapacity: true)
        callbacks.removeAll(keepingCapacity: true)
        display.removeAll(keepingCapacity: true)
        updates = 0
        tabFrameChanges = 0
        lastVisual = nil
        lastTabFrame = tab.frame
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuStart = cpuTime(usage)
        let started = CACurrentMediaTime()
        print("SCENE \(name)")
        fflush(nil)
        try await body()
        let seconds = CACurrentMediaTime() - started
        getrusage(RUSAGE_SELF, &usage)
        let intervals = zip(display.dropFirst(), display).map(-)
        let budget = 1 / max(1, refresh)
        let gaps = intervals.filter { $0 > budget * 1.5 }.count
        let lost = intervals.reduce(0) { $0 + max(0, Int(($1 / budget).rounded()) - 1) }
        let cpu = 100 * (cpuTime(usage) - cpuStart) / seconds
        print("PROFILE \(name) seconds=\(format(seconds)) cpu=\(format(cpu))% " +
              "display=\(display.count) intervalP95=\(format(percentile(intervals) * 1000))ms " +
              "gaps=\(gaps) estimatedMissed=\(lost) " +
              "events=\(samples.count) dispatchP95=\(format(percentile(samples)))ms max=\(format(samples.max() ?? 0))ms " +
              "morphCallbacks=\(callbacks.count) visualChanges=\(updates) tabFrameChanges=\(tabFrameChanges)")
        fflush(nil)
    }

    private func send(_ type: CGEventType, point: CGPoint, to tab: NSWindow) throws {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: CGPoint(x: point.x, y: top - point.y), mouseButton: .left)
        else { throw Failure("Could not create input event") }
        cg.setIntegerValueField(.mouseEventClickState, value: 1)
        cg.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        guard let event = NSEvent(cgEvent: cg) else { throw Failure("Could not translate input event") }
        let start = CACurrentMediaTime()
        tab.sendEvent(event)
        samples.append((CACurrentMediaTime() - start) * 1000)
        if lastTabFrame != tab.frame { tabFrameChanges += 1; lastTabFrame = tab.frame }
    }

    @objc private func displayTick(_ clock: CADisplayLink) { display.append(clock.timestamp) }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure("Window transition did not settle")
    }

    private func cpuTime(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func percentile(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        return ordered.isEmpty ? 0 : ordered[(ordered.count - 1) * 95 / 100]
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
