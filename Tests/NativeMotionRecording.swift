import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import os

func frameIntervals(_ times: [CFTimeInterval]) -> String {
    let intervals = zip(times.dropFirst(), times).map(-).filter { $0 > 0 && $0 < 0.10 }.sorted()
    guard !intervals.isEmpty else { return "\(times.count) samples, no short intervals" }
    let median = intervals[intervals.count / 2] * 1_000
    let p95 = intervals[(intervals.count - 1) * 95 / 100] * 1_000
    return "\(times.count) samples, sub-100 ms intervals median \(String(format: "%.1f", median)) ms, p95 \(String(format: "%.1f", p95)) ms"
}

@MainActor
enum NativeMotionRecording {
    static func verify(_ state: AppState, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = FloatingWindow(state: state)
        window.gestureProbe = { print("GESTURE: \($0)") }
        state.onLayoutChange = { [weak window] height, editing in window?.updateLayout(height: height, editing: editing) }
        state.tuckWindow = { [weak window] in window?.tuck() }
        state.setMiniWindow = { [weak window] enabled in window?.setMini(enabled) }
        state.store.onChange = { [weak state] in state?.updateListing() }
        for title in ["Motion QA · Review", "Motion QA · Draft", "Motion QA · Send"] {
            try state.store.save(TaskDraft(title: title))
        }
        state.preferences.values.animations = true
        window.show()
        guard let main = NSApp.windows.compactMap({ $0 as? TaskPanel }).first(where: { $0.title == "LumaTodo" }),
              let tab = NSApp.windows.first(where: { $0.title == "LumaTodo Edge" }),
              let screen = main.screen else { throw RecordingFailure("Missing probe windows") }
        let visible = screen.visibleFrame
        let recorder = try await Recorder(directory: directory, screen: screen)
        var frames: [CFTimeInterval] = []
        window.onTransitionFrame = { frames.append($0) }
        let idle = ResourceSample()
        try await Task.sleep(for: .seconds(2))
        ResourceSample().report(since: idle, label: "idle (no capture)")

        try await recorder.capture("01-collapse-expand") {
            state.preferences.tuckSide = .right
            window.tuck()
            try await settle { tab.isVisible }
            try await Task.sleep(for: .milliseconds(230))
            window.show()
            try await settle { main.isVisible }
            state.preferences.tuckSide = .left
            try await Task.sleep(for: .milliseconds(190))
            window.tuck()
            try await Task.sleep(for: .milliseconds(112))
            window.toggle()
            try await settle { main.isVisible }
            state.setMini(true)
            try await Task.sleep(for: .milliseconds(340))
            window.tuck()
            try await settle { tab.isVisible }
            window.show()
            try await settle { main.isVisible }
            state.setMini(false)
            try await Task.sleep(for: .milliseconds(340))
        }

        try await recorder.capture("02-fling") {
            let middleY = visible.midY
            try await move(main, by: CGVector(dx: visible.midX + 120 - main.frame.midX, dy: middleY - main.frame.midY),
                           duration: 0.37)
            try await Task.sleep(for: .milliseconds(260))
            try await move(main, by: CGVector(dx: 200, dy: 5), duration: 0.115)
            try await settle("right fling") { tab.isVisible && abs(tab.frame.maxX - visible.maxX) < 1 }
            window.show()
            try await settle { main.isVisible }
            try await move(main, by: CGVector(dx: visible.midX - 120 - main.frame.midX, dy: middleY - main.frame.midY),
                           duration: 0.46)
            try await Task.sleep(for: .milliseconds(220))
            try await move(main, by: CGVector(dx: -200, dy: 4), duration: 0.115)
            try await settle("left fling") { tab.isVisible && abs(tab.frame.minX - visible.minX) < 1 }
            window.show()
            try await settle { main.isVisible }
            try await move(main, by: CGVector(dx: 0, dy: 130), duration: 0.12)
            guard main.isVisible, window.transitionFrame == nil else { throw RecordingFailure("Vertical drag tucked the window") }
        }

        try await recorder.capture("03-capsule-drag") {
            state.preferences.tuckSide = .right
            window.tuck()
            try await settle { tab.isVisible }
            let initial = tab.frame
            try await dragTab(tab, dy: 0, duration: 0.31, release: false)
            try await dragTab(tab, dy: -180, duration: 0.25, down: false)
            try await settle { tab.isVisible && window.transitionFrame == nil && tab.frame.midY < initial.midY - 20 }
            try await Task.sleep(for: .milliseconds(250))
            try await dragTab(tab, dy: 80, duration: 0.50)
            try await settle { tab.isVisible && window.transitionFrame == nil }
            let y = tab.frame.midY
            for index in 0..<10 {
                try await dragTab(tab, dy: index.isMultiple(of: 2) ? -34 : 34, duration: 0.10)
                try await settle { tab.isVisible && window.transitionFrame == nil }
                guard tab.isVisible, tab.frame.maxX == initial.maxX else {
                    throw RecordingFailure("Dragging opened the panel or detached from edge")
                }
            }
            guard abs(tab.frame.midY - y) < 2 else { throw RecordingFailure("Repeated drags accumulated position drift") }
            for index in 0..<3 {
                try await dragTab(tab, dy: 0, duration: 0.25, release: false)
                try await dragTab(tab, dy: 12, duration: 0.09, down: false)
                try await settle { tab.isVisible && window.transitionFrame == nil }
                guard tab.isVisible else { throw RecordingFailure("Small drag opened the window on release") }
                try await dragTab(tab, dy: index == 1 ? 2 : 0, duration: 0.07)
                try await settle { main.isVisible && !tab.isVisible }
                if index < 2 {
                    window.tuck()
                    try await settle { tab.isVisible }
                }
            }
        }

        if let extra = state.store.items.last { try state.store.delete(extra) }
        try await Task.sleep(for: .milliseconds(250))
        try await recorder.capture("04-task-completion") {
            guard let task = state.store.items.first else { throw RecordingFailure("Missing task fixture") }
            _ = main.contentView?.layoutSubtreeIfNeeded()
            // The fixture has one 27-pt heading and a title-only 38-pt first row.
            let point = NSPoint(x: 30, y: main.frame.height - 141)
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: main.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
               let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.10,
                                            windowNumber: main.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) {
                NSApp.postEvent(down, atStart: false)
                try await Task.sleep(for: .milliseconds(100))
                NSApp.postEvent(up, atStart: false)
                try await Task.sleep(for: .milliseconds(90))
            }
            if !task.isCompleted {
                print("RECORDING NOTE: completion driven by model callback because synthetic press left selection unchanged.")
                state.complete(task, feedback: true)
            }
            guard task.isCompleted else { throw RecordingFailure("Completion failed to commit") }
            try await Task.sleep(for: .milliseconds(620))
            state.collapsedGroups.remove(.completed)
            try await Task.sleep(for: .milliseconds(460))
            state.restore(task, feedback: true)
            guard !task.isCompleted else { throw RecordingFailure("Restore failed to commit") }
            try await Task.sleep(for: .milliseconds(450))
        }
        for edge in [ScreenEdge.left, .right] {
            try await recorder.capture("05-fluid-\(edge.rawValue)") {
                try await verifyMagneticPull(window, main: main, tab: tab, state: state, screen: visible, edge: edge)
            }
        }
        state.preferences.values.animations = false
        window.tuck()
        try await settle { tab.isVisible }
        let pressed = tab.frame.center
        let reached = pressed.applying(CGAffineTransform(translationX: -220, y: 0))
        tab.sendEvent(try mouse(.leftMouseDown, pressed))
        tab.sendEvent(try mouse(.leftMouseDragged, reached))
        try await settle("reduced animation pull") { (window.transitionFrame?.width ?? 0) >= main.frame.width - 1 }
        window.screensChanged()
        try await settle("cancelled pull during a display update") {
            window.transitionFrame == nil && tab.isVisible && tab.contentView?.isHidden == false && !main.isVisible
        }
        tab.sendEvent(try mouse(.leftMouseDown, pressed))
        tab.sendEvent(try mouse(.leftMouseDragged, reached))
        try await settle("reduced animation retry") { (window.transitionFrame?.width ?? 0) >= main.frame.width - 1 }
        tab.sendEvent(try mouse(.leftMouseUp, reached))
        try await settle("reduced animation handoff") { main.isVisible && !tab.isVisible }
        print("PASS: reduced animation preserves interactive geometry and a display update safely cancels a held pull.")
        print("PASS: recorded native windows, two signed-direction flings, ten consecutive capsule drags, and synchronous completion/restore.")
        print("DISPLAY LINK: \(frameIntervals(frames)) while capturing.")
    }

    private static func verifyMagneticPull(_ window: FloatingWindow, main: NSWindow, tab: NSWindow, state: AppState,
                                          screen: CGRect, edge: ScreenEdge) async throws {
        state.preferences.tuckSide = edge == .left ? .left : .right
        window.tuck()
        try await settle { tab.isVisible && !main.isVisible }
        let edgeFrame = tab.frame
        let sign: CGFloat = edge == .left ? 1 : -1
        let tuning = EdgePullTuning(windowWidth: main.frame.width, displayWidth: screen.width)
        var dispatchTimes: [Double] = []

        func sample(_ type: CGEventType, origin: CGPoint, inward distance: CGFloat, dy: CGFloat = 0) throws {
            let point = CGPoint(x: origin.x + sign * distance, y: origin.y + dy)
            let event = try mouse(type, point)
            let start = CACurrentMediaTime()
            tab.sendEvent(event)
            dispatchTimes.append((CACurrentMediaTime() - start) * 1_000)
        }

        func drag(from initial: CGFloat, to distance: CGFloat, origin: CGPoint, duration: Double,
                  yStart: CGFloat = 0, yEnd: CGFloat = 0) async throws {
            let steps = max(5, Int((duration * 60).rounded()))
            for step in 1...steps {
                try await Task.sleep(for: .seconds(duration / Double(steps)))
                let phase = Double(step) / Double(steps)
                try sample(.leftMouseDragged, origin: origin, inward: initial + (distance - initial) * phase,
                           dy: yStart + (yEnd - yStart) * phase)
            }
        }

        for dy in [20.0, 0, -20] {
            let point = CGPoint(x: edgeFrame.midX, y: edgeFrame.midY + dy)
            try sample(.leftMouseDown, origin: point, inward: 0)
            try await Task.sleep(for: .milliseconds(550))
            try sample(.leftMouseUp, origin: point, inward: 0)
            try await settle { tab.isVisible && window.transitionFrame == nil }
            guard tab.isVisible, !main.isVisible, window.transitionFrame == nil else {
                throw RecordingFailure("Holding the capsule opened or moved it")
            }
            try await Task.sleep(for: .milliseconds(120))
        }

        for distance in [10.0, 25, 40, 60] {
            try sample(.leftMouseDown, origin: edgeFrame.center, inward: 0)
            try await drag(from: 0, to: distance, origin: edgeFrame.center, duration: 0.19)
            try await settle("magnetic tracking") {
                guard let frame = window.transitionFrame else { return false }
                let shift = edge == .left ? frame.minX - edgeFrame.minX : edgeFrame.maxX - frame.maxX
                return shift > 0.5 && shift < distance && frame.width < main.frame.width
                    && tab.contentView?.isHidden == true && !main.isVisible
            }
            try await Task.sleep(for: .milliseconds(100))
            try sample(.leftMouseUp, origin: edgeFrame.center, inward: distance)
            try await settle("magnetic return") { window.transitionFrame == nil && tab.contentView?.isHidden == false }
            guard tab.frame == edgeFrame, !main.isVisible else { throw RecordingFailure("Magnetic return missed its edge") }
        }

        let far = tuning.reach * 0.95
        try sample(.leftMouseDown, origin: edgeFrame.center, inward: 0)
        try await drag(from: 0, to: far, origin: edgeFrame.center, duration: 0.46)
        try await settle("expansion shown before release") { (window.transitionFrame?.width ?? 0) > main.frame.width * 0.9 }
        try await Task.sleep(for: .milliseconds(125))
        try await drag(from: far, to: 10, origin: edgeFrame.center, duration: 0.34)
        try await settle("reversed while pointer still held") { (window.transitionFrame?.width ?? 0) < edgeFrame.width + 5 }
        try sample(.leftMouseUp, origin: edgeFrame.center, inward: 10)
        try await settle("reversed return") { window.transitionFrame == nil && tab.contentView?.isHidden == false }

        // Begin vertically, pull inward while moving down, then reverse X while moving up.
        let origin = tab.frame.center
        try sample(.leftMouseDown, origin: origin, inward: 0)
        try await drag(from: 0, to: 0, origin: origin, duration: 0.20, yEnd: 60)
        try await settle("vertical before inward") {
            guard let fluid = window.transitionFrame else { return false }
            return fluid.midY > origin.y + 50 && abs(fluid.width - edgeFrame.width) < 2
        }
        try await drag(from: 0, to: far * 0.78, origin: origin, duration: 0.44, yStart: 60, yEnd: -45)
        try await settle("mixed movement before releasing") {
            guard let fluid = window.transitionFrame else { return false }
            return fluid.midY < origin.y - 30 && fluid.width > edgeFrame.width + 70
        }
        try await Task.sleep(for: .milliseconds(150))
        try await drag(from: far * 0.78, to: 0, origin: origin, duration: 0.40, yStart: -45, yEnd: 48)
        try await settle("reverse both axes") {
            guard let fluid = window.transitionFrame else { return false }
            return fluid.midY > origin.y + 37 && fluid.width < edgeFrame.width + 3
        }
        try sample(.leftMouseUp, origin: origin, inward: 0, dy: 48)
        try await settle("cancelled pull saves vertical position") {
            window.transitionFrame == nil && abs(tab.frame.midY - (origin.y + 48)) < 1 && !main.isVisible
        }

        for duration in [0.64, 0.32, 0.13] {
            let origin = tab.frame.center
            let shift: CGFloat = duration == 0.32 ? -35 : 0
            try sample(.leftMouseDown, origin: origin, inward: 0)
            try await drag(from: 0, to: far, origin: origin, duration: duration, yEnd: shift)
            try await settle("readable preview before release") {
                (window.transitionFrame?.width ?? 0) >= main.frame.width - 1 && !main.isVisible
            }
            try await Task.sleep(for: .milliseconds(120))
            try sample(.leftMouseUp, origin: origin, inward: far, dy: shift)
            try await settle("interactive reveal") { main.isVisible && !tab.isVisible && window.transitionFrame == nil }
            let expectedY = min(screen.maxY - main.frame.height / 2, max(screen.minY + main.frame.height / 2, origin.y + shift))
            guard abs(main.frame.midY - expectedY) < 1 else { throw RecordingFailure("Expanded window lost its dragged height") }
            try await Task.sleep(for: .milliseconds(210))
            window.tuck()
            try await settle { tab.isVisible && !main.isVisible }
        }

        let initialY = tab.frame.midY
        for _ in 0..<10 {
            try await dragTab(tab, dy: -22, duration: 0.08)
            try await settle { tab.isVisible && window.transitionFrame == nil }
            guard tab.frame.midY < initialY - 15, window.transitionFrame == nil else {
                throw RecordingFailure("Downward repositioning entered the pull transition")
            }
            try await dragTab(tab, dy: 22, duration: 0.08)
            try await settle { tab.isVisible && window.transitionFrame == nil }
            guard abs(tab.frame.midY - initialY) < 1, window.transitionFrame == nil, !main.isVisible else {
                throw RecordingFailure("Upward repositioning drifted or expanded")
            }
        }
        try await dragTab(tab, dy: 0, duration: 0.08)
        try await settle("click after vertical drag") { main.isVisible && !tab.isVisible }
        let sorted = dispatchTimes.sorted()
        let p95 = sorted[(sorted.count - 1) * 95 / 100]
        let maximum = sorted.last ?? 0
        print("EDGE: \(edge.rawValue) pressure at 3 heights, 4 light pulls, 2D motion and reversal while held, 3 reveal speeds, 10 up/10 down, then click.")
        print("POINTER: \(edge.rawValue) \(sorted.count) samples, AppKit dispatch p95 \(String(format: "%.2f", p95)) ms, max \(String(format: "%.2f", maximum)) ms.")
    }

    static func move(_ panel: TaskPanel, by delta: CGVector, duration: Double) async throws {
        guard let origin = panel.sampleGripPoint else { throw RecordingFailure("The actual window has no registered title grip") }
        let time = ProcessInfo.processInfo.systemUptime
        panel.sendEvent(try mouse(.leftMouseDown, origin, time: time))
        try await movePointer(from: origin, by: delta, duration: duration, time: time) { event in panel.sendEvent(event) }
    }

    private static var tabPressOrigin: CGPoint?

    private static func dragTab(_ tab: NSWindow, dy: CGFloat, duration: Double, down: Bool = true, release: Bool = true) async throws {
        let origin = !down ? tabPressOrigin ?? tab.frame.center : tab.frame.center
        if down {
            tabPressOrigin = origin
            tab.sendEvent(try mouse(.leftMouseDown, origin))
        }
        if release { try await movePointer(from: origin, by: CGVector(dx: 0, dy: dy), duration: duration) { tab.sendEvent($0) } }
        else { try await Task.sleep(for: .seconds(duration)) }
    }

    private static func movePointer(from origin: CGPoint, by delta: CGVector, duration: Double,
                                    time: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                    dispatch: (NSEvent) -> Void) async throws {
        let frames = max(5, Int((duration * 60).rounded()))
        for index in 1...frames {
            try await Task.sleep(for: .seconds(duration / Double(frames)))
            let fraction = CGFloat(index) / CGFloat(frames)
            dispatch(try mouse(index == frames ? .leftMouseUp : .leftMouseDragged,
                               CGPoint(x: origin.x + delta.dx * fraction, y: origin.y + delta.dy * fraction),
                               time: time + duration * fraction))
        }
    }

    private static func mouse(_ type: CGEventType, _ point: CGPoint,
                              time: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> NSEvent {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: CGPoint(x: point.x, y: top - point.y), mouseButton: .left) else {
            throw RecordingFailure("Could not synthesize a pointer sample")
        }
        cg.setIntegerValueField(.mouseEventClickState, value: 1)
        cg.timestamp = UInt64(time * 1_000_000_000)
        guard let event = NSEvent(cgEvent: cg) else { throw RecordingFailure("AppKit could not read the pointer sample") }
        return event
    }

    private static func settle(_ operation: String = "window transition", _ condition: () -> Bool) async throws {
        for _ in 0..<70 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(18))
        }
        throw RecordingFailure("A native window did not reach the expected state after " + operation)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
private final class Recorder {
    private let directory: URL
    private let display: SCDisplay
    private let application: SCRunningApplication

    init(directory: URL, screen: NSScreen) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw RecordingFailure("Screen recording permission unavailable") }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let pid = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }),
               let application = content.applications.first(where: { $0.processID == pid })
                    ?? content.windows.compactMap(\.owningApplication).first(where: { $0.processID == pid }) {
                self.directory = directory
                self.display = display
                self.application = application
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RecordingFailure("ScreenCaptureKit could not isolate the QA process")
    }

    func capture(_ name: String, perform: @MainActor () async throws -> Void) async throws {
        let destination = directory.appending(path: name + ".mp4")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RecordingFailure("Recording already exists: " + name) }
        let config = SCStreamConfiguration()
        config.width = min(1440, display.width * 2)
        config.height = Int(Double(config.width) * display.frame.height / display.frame.width) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = false
        config.backgroundColor = NSColor(srgbRed: 0.21, green: 0.26, blue: 0.32, alpha: 1).cgColor
        let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let samples = CaptureSamples()
        try stream.addStreamOutput(samples, type: .screen, sampleHandlerQueue: DispatchQueue(label: "LumaTodo.QA.Frames"))
        let output = SCRecordingOutputConfiguration()
        output.outputURL = destination
        let delegate = RecordingDelegate()
        let recording = SCRecordingOutput(configuration: output, delegate: delegate)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        do {
            try await Task.sleep(for: .milliseconds(400))
            let before = ResourceSample()
            try await perform()
            ResourceSample().report(since: before, label: name)
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        for _ in 0..<50 where delegate.result == nil { try await Task.sleep(for: .milliseconds(30)) }
        try delegate.result?.get()
        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw RecordingFailure("No video track in " + name) }
        let duration = try await asset.load(.duration).seconds
        let rate = try await track.load(.nominalFrameRate)
        print("VIDEO: \(name), \(String(format: "%.2f", duration)) seconds, \(String(format: "%.2f", rate)) FPS average.")
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(trackOutput)
        guard reader.startReading() else { throw RecordingFailure("Could not inspect recorded samples") }
        var pts: [Double] = []
        var blankTimes: [Double] = []
        while let buffer = trackOutput.copyNextSampleBuffer() {
            let time = buffer.presentationTimeStamp.seconds
            pts.append(time)
            if let image = buffer.imageBuffer, Self.isBackdropOnly(image) { blankTimes.append(time) }
        }
        pts.sort()
        print("FRAMES: \(name), source \(frameIntervals(samples.times)), encoded \(frameIntervals(pts)).")
        let visibleTimeline = blankTimes.filter { $0 > 0.08 && $0 < duration - 0.08 }
        print("HANDOFF: \(name), \(visibleTimeline.count) backdrop-only samples in the recorded timeline.")
    }

    private static func isBackdropOnly(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let backdrop = (height - 30) * row + 50 * 4
        var changed = 0
        for y in stride(from: 8, to: height - 8, by: 12) {
            for x in stride(from: 8, to: width - 8, by: 12) {
                let index = y * row + x * 4
                let difference = (0..<3).reduce(0) { $0 + abs(Int(pixels[index + $1]) - Int(pixels[backdrop + $1])) }
                if difference > 35 {
                    changed += 1
                    if changed >= 4 { return false }
                }
            }
        }
        return true
    }
}

private final class CaptureSamples: NSObject, SCStreamOutput, Sendable {
    private let samples = OSAllocatedUnfairLock(initialState: [CFTimeInterval]())
    var times: [CFTimeInterval] { samples.withLock { $0 } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.imageBuffer != nil else { return }
        let timestamp = sampleBuffer.presentationTimeStamp.seconds
        samples.withLock { $0.append(timestamp) }
    }
}

private struct ResourceSample {
    let time = ProcessInfo.processInfo.systemUptime
    let cpu: Double
    let peakMiB: Double

    init() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        peakMiB = Double(usage.ru_maxrss) / (1024 * 1024)
    }

    func report(since before: Self, label: String) {
        let percent = 100 * (cpu - before.cpu) / max(0.001, time - before.time)
        print("PROCESS: \(label), \(String(format: "%.1f", percent))% of one CPU, peak resident \(String(format: "%.1f", peakMiB)) MiB.")
    }
}

@MainActor
private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    var result: Result<Void, any Error>?
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in result = .success(()) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in result = .failure(error) }
    }
}

private struct RecordingFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
