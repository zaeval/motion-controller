import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GestureCore

/// `PRINT_TRACES=scroll swift test --filter RecordingTraces` prints what the analyzer and the pointer saw on every
/// frame of the recordings whose names contain the label.
struct RecordingTraces {
    /// `FLICK_FEATURES=scroll swift test --filter RecordingTraces` prints, per recording, how two-finger flicks move
    /// the fingers against their resting reach and how the palm moves with them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLICK_FEATURES"] != nil))
    func printFlickFeatures() throws {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let meanA = a.reduce(0, +) / Double(a.count), meanB = b.reduce(0, +) / Double(b.count)
            let cov = zip(a, b).reduce(0) { $0 + ($1.0 - meanA) * ($1.1 - meanB) }
            let varA = a.reduce(0) { $0 + ($1 - meanA) * ($1 - meanA) }, varB = b.reduce(0) { $0 + ($1 - meanB) * ($1 - meanB) }
            return varA > 0 && varB > 0 ? cov / (varA * varB).squareRoot() : 0
        }
        for recording in try SwipeFixtureTests.recordings(containing: ProcessInfo.processInfo.environment["FLICK_FEATURES"] ?? "") {
            var samples: [(time: TimeInterval, reach: Double, palmY: Double, tipY: Double)] = []
            for frame in recording.frames {
                guard let hand = SwipeFixtureTests.trackedHand(in: frame), let features = HandFeatures(hand),
                      let anchor = features.anchor,
                      let indexTip = hand[.indexTip], let indexMCP = hand[.indexMCP],
                      let middleTip = hand[.middleTip], let middleMCP = hand[.middleMCP]
                else { continue }
                let reach = (indexTip.distance(to: indexMCP) + middleTip.distance(to: middleMCP)) / 2 / features.scale
                samples.append((frame.timestamp, reach, anchor.y, (indexTip.y + middleTip.y) / 2))
            }
            guard samples.count > 4 else { continue }
            let rest = median(samples.map(\.reach))
            var line = "\(recording.name.padding(toLength: 32, withPad: " ", startingAt: 0)) n \(samples.count) rest \(String(format: "%.2f", rest))"
            let above = samples.filter { $0.reach > rest + 0.15 }.count
            let below = samples.filter { $0.reach < rest - 0.15 }.count
            line += String(format: " | above+0.15 %2d below-0.15 %2d", above, below)
            line += String(format: " | max %.2f min %.2f", samples.map(\.reach).max()!, samples.map(\.reach).min()!)
            var fastUp: [(speed: Double, palmDY: Double, endExcursion: Double)] = []
            var fastDown: [(speed: Double, palmDY: Double, endExcursion: Double)] = []
            var deltaReach: [Double] = [], deltaPalm: [Double] = []
            for (previous, current) in zip(samples, samples.dropFirst()) where current.time - previous.time <= 0.08 {
                let dt = current.time - previous.time
                let speed = (current.reach - previous.reach) / dt
                deltaReach.append(current.reach - previous.reach)
                deltaPalm.append(current.palmY - previous.palmY)
                let event = (abs(speed), (current.palmY - previous.palmY) / previous.reach, current.reach - rest)
                if speed > 2.5 { fastUp.append(event) } else if speed < -2.5 { fastDown.append(event) }
            }
            func summary(_ events: [(speed: Double, palmDY: Double, endExcursion: Double)]) -> String {
                guard !events.isEmpty else { return " 0" }
                let n = events.count
                return String(format: "%2d v%.1f palmDY%+.3f end%+.2f", n,
                              events.map(\.speed).reduce(0, +) / Double(n),
                              events.map(\.palmDY).reduce(0, +) / Double(n),
                              events.map(\.endExcursion).reduce(0, +) / Double(n))
            }
            line += " | fast extend " + summary(fastUp) + " | fast flex " + summary(fastDown)
            line += String(format: " | corr(reach,palmY) %+.2f corr(dReach,dPalm) %+.2f",
                           correlation(samples.map(\.reach), samples.map(\.palmY)), correlation(deltaReach, deltaPalm))
            print(line)
        }
    }

    /// `RENDER_HANDS=scroll RENDER_DIR=/some/dir swift test --filter RecordingTraces` draws the tracked hand of every
    /// frame as a contact sheet, mirrored like the preview and centered on the palm so finger movement stands out.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_HANDS"] != nil))
    func renderHands() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(filePath: environment["RENDER_DIR"] ?? NSTemporaryDirectory())
        for recording in try SwipeFixtureTests.recordings(containing: environment["RENDER_HANDS"] ?? "") {
            let start = recording.frames.first?.timestamp ?? 0
            var analyzer = GestureAnalyzer()
            let cells: [(hand: HandFrame, reading: GestureReading, time: TimeInterval)] = recording.frames.compactMap { frame in
                let hand = SwipeFixtureTests.trackedHand(in: frame)
                guard let reading = analyzer.update(hand: hand, at: frame.timestamp), let hand else { return nil }
                return (hand, reading, frame.timestamp - start)
            }
            let sizes = cells.compactMap(\.hand.handSize).sorted()
            guard !sizes.isEmpty else { continue }
            let cell = 160
            let columns = 8
            let rows = (cells.count + columns - 1) / columns
            guard let context = CGContext(
                data: nil, width: cell * columns, height: cell * rows, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: cell * columns, height: cell * rows))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let pixelsPerUnit = Double(cell) / (3.2 * sizes[sizes.count / 2])
            let chains: [([HandJoint], CGColor)] = [
                ([.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip], CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)),
                ([.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip], CGColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1)),
                ([.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip], CGColor(red: 0.2, green: 0.4, blue: 0.95, alpha: 1)),
                ([.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip], CGColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1)),
                ([.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip], CGColor(red: 0.6, green: 0.3, blue: 0.8, alpha: 1)),
            ]
            for (index, item) in cells.enumerated() {
                let origin = CGPoint(x: index % columns * cell, y: (rows - 1 - index / columns) * cell)
                context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
                context.setLineWidth(1)
                context.stroke(CGRect(origin: origin, size: CGSize(width: cell, height: cell)))
                guard let anchor = HandFeatures(item.hand)?.anchor else { continue }
                func place(_ joint: HandJoint) -> CGPoint? {
                    item.hand[joint].map {
                        CGPoint(
                            x: origin.x + Double(cell) / 2 - ($0.x - anchor.x) * pixelsPerUnit,
                            y: origin.y + Double(cell) * 0.35 + ($0.y - anchor.y) * pixelsPerUnit
                        )
                    }
                }
                context.setLineWidth(2)
                for (chain, color) in chains {
                    context.setStrokeColor(color)
                    let points = chain.map(place)
                    for (from, to) in zip(points, points.dropFirst()) {
                        guard let from, let to else { continue }
                        context.move(to: from)
                        context.addLine(to: to)
                        context.strokePath()
                    }
                }
                let label = String(format: "%.2f %@ y%.2f", item.time, item.reading.pose.map { "\($0)" } ?? "-", item.reading.pointer?.y ?? 0)
                (label as NSString).draw(at: CGPoint(x: origin.x + 4, y: origin.y + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            }
            NSGraphicsContext.current = nil
            let url = directory.appending(path: recording.name.replacingOccurrences(of: ".json", with: ".png"))
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    /// `CURSOR_FEATURES=cursor swift test --filter RecordingTraces` prints, per frame, how far the index reaches along
    /// the palm and how far it tilts off it, to tell a finger bent toward the camera from one held straight up.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CURSOR_FEATURES"] != nil))
    func printCursorFeatures() throws {
        func percentiles(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "-" }
            func at(_ q: Double) -> Double { sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)] }
            return String(format: "p10 %.2f p50 %.2f p90 %.2f", at(0.1), at(0.5), at(0.9))
        }
        for recording in try SwipeFixtureTests.recordings(containing: ProcessInfo.processInfo.environment["CURSOR_FEATURES"] ?? "") {
            let start = recording.frames.first?.timestamp ?? 0
            var analyzer = GestureAnalyzer()
            var reaches: [Double] = [], alongs: [Double] = [], tilts: [Double] = [], chains: [Double] = []
            print("=== \(recording.name)")
            print("    t  pose           v     s     reach along  across tilt°  chain  prox  dist  palmW")
            for frame in recording.frames {
                let hand = SwipeFixtureTests.trackedHand(in: frame)
                let reading = analyzer.update(hand: hand, at: frame.timestamp)
                let line = String(format: "%5.2f", frame.timestamp - start)
                guard let reading, let hand, let features = HandFeatures(hand),
                      let wrist = hand[.wrist], let middleMCP = hand[.middleMCP], let littleMCP = hand[.littleMCP],
                      let mcp = hand[.indexMCP], let pip = hand[.indexPIP], let dip = hand[.indexDIP], let tip = hand[.indexTip]
                else {
                    print(line + " -")
                    continue
                }
                let scale = features.scale
                let axisLength = max(wrist.distance(to: middleMCP), 1e-6)
                let ax = (middleMCP.x - wrist.x) / axisLength, ay = (middleMCP.y - wrist.y) / axisLength
                let fx = tip.x - mcp.x, fy = tip.y - mcp.y
                let reach = tip.distance(to: mcp) / scale
                let along = (fx * ax + fy * ay) / scale
                let across = (fx * ay - fy * ax) / scale
                let tilt = atan2(across, along) * 180 / .pi
                let proximal = mcp.distance(to: pip) / scale
                let distal = (pip.distance(to: dip) + dip.distance(to: tip)) / scale
                let pose = (reading.pose.map { "\($0)" } ?? "-").padding(toLength: 12, withPad: " ", startingAt: 0)
                var text = line + " \(pose)"
                text += String(format: "  %.2f  %.3f  %.2f  %.2f  %+.2f  %+4.0f   %.2f  %.2f  %.2f  %.2f",
                               reading.palmSpeed, scale, reach, along, across, tilt, proximal + distal, proximal, distal,
                               mcp.distance(to: littleMCP) / scale)
                text += reading.isPinching ? "  PINCH" : ""
                text += reading.isTapDipping ? "  dip" : ""
                text += reading.tap.map { "  <<< TAP \($0)" } ?? ""
                print(text)
                if reading.pose == .pointIndex {
                    reaches.append(reach)
                    alongs.append(along)
                    tilts.append(tilt)
                    chains.append(proximal + distal)
                }
            }
            print("  pointIndex n \(reaches.count) | reach \(percentiles(reaches)) | along \(percentiles(alongs)) | tilt \(percentiles(tilts)) | chain \(percentiles(chains))")
        }
    }

    /// `SWIPE_MARGIN=1 swift test --filter RecordingTraces` prints, per recording, the strongest swipe-like window:
    /// how far the palm travelled sideways (frame widths), how fast, and by how much it beat the vertical. The swipe
    /// clips show what a real swipe has to spare; the rest show how much room is left before one fires by accident.
    /// `SWIPE_COUNTS=1 swift test --filter RecordingTraces` prints, per recording, every swipe the analyzer fired
    /// with its time, so a clip recorded as one, two or three swipes can be checked against what came out.
    /// One stretch of sideways palm travel between reversals.
    struct PalmRun {
        /// The user's left or right, from un-mirrored image x (which grows toward their left).
        var direction: String
        var travel: Double
        var duration: TimeInterval
        var start: TimeInterval
        var flatRun: Int
        var pinchShare: Double
        var palmShare: Double
        var meanY: Double

        var text: String {
            String(
                format: "%@%.3f/%.2fs@%.2f v%.2f flat%d pinch%.0f%% palm%.0f%% y%.2f", direction, travel, duration,
                start, duration > 0 ? travel / duration : 0, flatRun, pinchShare * 100, palmShare * 100, meanY
            )
        }
    }

    /// Splits a recording's palm travel into monotonic runs. A reversal has to clear `hysteresis` before it closes a
    /// run, or 30 fps jitter splits one stroke into several, and the recording's end closes the last run — dropping
    /// it hid the final stroke of every clip.
    static func palmRuns(in recording: SwipeFixtureTests.Recording, hysteresis: Double = 0.01, minTravel: Double = 0.02) -> [PalmRun] {
        let start = recording.frames.first?.timestamp ?? 0
        let samples: [(time: TimeInterval, x: Double, y: Double, flat: Bool, pinch: Bool, palm: Bool)] =
            recording.frames.compactMap { frame in
                guard let hand = SwipeFixtureTests.trackedHand(in: frame), let features = HandFeatures(hand),
                      let anchor = features.anchor
                else { return nil }
                let flat = Finger.allCases.filter { features.isExtended($0) == true }.count >= 3
                let pinch = (features.pinchRatio ?? 1) < 0.35
                return (frame.timestamp - start, anchor.x / frame.imageAspect, anchor.y, flat,
                        pinch, features.palmFacesCamera == true)
            }
        guard var began = samples.first else { return [] }
        var runs: [PalmRun] = []
        var direction = 0.0
        var extreme = began

        func close(at end: (time: TimeInterval, x: Double, y: Double, flat: Bool, pinch: Bool, palm: Bool)) {
            let travel = end.x - began.x
            guard abs(travel) >= minTravel else { return }
            let window = samples.filter { $0.time >= began.time && $0.time <= end.time }
            var run = 0, longest = 0
            for point in window {
                run = point.flat ? run + 1 : 0
                longest = max(longest, run)
            }
            guard !window.isEmpty else { return }
            runs.append(PalmRun(
                direction: travel > 0 ? "L" : "R", travel: abs(travel), duration: end.time - began.time,
                start: began.time, flatRun: longest,
                pinchShare: Double(window.filter(\.pinch).count) / Double(window.count),
                palmShare: Double(window.filter(\.palm).count) / Double(window.count),
                meanY: window.map(\.y).reduce(0, +) / Double(window.count)
            ))
        }

        for sample in samples.dropFirst() {
            let step = sample.x - extreme.x
            if direction == 0 {
                guard abs(step) > hysteresis else { continue }
                direction = step > 0 ? 1 : -1
                extreme = sample
            } else if step * direction > 0 {
                extreme = sample
            } else if abs(step) > hysteresis {
                close(at: extreme)
                began = extreme
                direction = step > 0 ? 1 : -1
                extreme = sample
            }
        }
        close(at: extreme)
        return runs
    }

    /// `SWIPE_RUNS=swipe swift test --filter RecordingTraces` breaks each recording's sideways palm motion into
    /// monotonic runs, so a wind-up, the stroke itself and the return stroke can be told apart.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIPE_RUNS"] != nil))
    func printSwipeRuns() throws {
        for recording in try SwipeFixtureTests.recordings(containing: ProcessInfo.processInfo.environment["SWIPE_RUNS"] ?? "") {
            let name = recording.name.replacingOccurrences(of: ".json", with: "")
            let runs = Self.palmRuns(in: recording).map(\.text).joined(separator: "\n\t")
            print("\(name)\n\t\(runs)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIPE_COUNTS"] != nil))
    func printSwipeCounts() throws {
        for recording in try SwipeFixtureTests.recordings(containing: ProcessInfo.processInfo.environment["SWIPE_COUNTS_LABEL"] ?? "") {
            let swipes = SwipeFixtureTests.timedSwipes(in: recording).map {
                String(format: "%@@%.2f", $0.direction == .left ? "L" : "R", $0.time)
            }
            let name = recording.name.replacingOccurrences(of: ".json", with: "")
            print("\(name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(swipes.count): \(swipes.joined(separator: " "))")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIPE_MARGIN"] != nil))
    func printSwipeMargins() throws {
        let window = Double(ProcessInfo.processInfo.environment["SWIPE_WINDOW"] ?? "") ?? 0.4
        let all = try SwipeFixtureTests.recordings(containing: "")
        print("recordings \(all.count) window \(window)")
        for recording in all {
            let samples: [(time: TimeInterval, anchor: Vec2, aspect: Double, fingers: Int)] = recording.frames.compactMap { frame in
                guard let hand = SwipeFixtureTests.trackedHand(in: frame), let features = HandFeatures(hand),
                      let anchor = features.anchor
                else { return nil }
                let fingers = Finger.allCases.filter { features.isExtended($0) == true }.count
                return (frame.timestamp, anchor, frame.imageAspect, fingers)
            }
            var best = (travel: 0.0, speed: 0.0, ratio: 0.0, seconds: 0.0)
            var flat = 0.0
            var longestRun = 0
            var windowFrames = 0
            var loose = 0.0
            for (index, start) in samples.enumerated() {
                for end in samples.dropFirst(index + 1) where end.time - start.time <= window {
                    let dx = abs(end.anchor.x - start.anchor.x), dy = abs(end.anchor.y - start.anchor.y)
                    let travel = dx / end.aspect
                    loose = max(loose, travel)
                    let ratio = dy > 0 ? dx / dy : 99
                    guard ratio >= 1.2, travel > best.travel else { continue }
                    best = (travel, travel / (end.time - start.time), ratio, end.time - start.time)
                    let window = samples.filter { $0.time >= start.time && $0.time <= end.time }
                    flat = Double(window.filter { $0.fingers >= 3 }.count) / Double(max(window.count, 1))
                    var run = 0
                    longestRun = 0
                    for point in window {
                        run = point.fingers >= 3 ? run + 1 : 0
                        longestRun = max(longestRun, run)
                    }
                    windowFrames = window.count
                }
            }
            let name = recording.name.replacingOccurrences(of: "20260912-", with: "").replacingOccurrences(of: ".json", with: "")
            print(String(
                format: "%@ travel %.3f speed %.2f ratio %.1f over %.2fs  flat %.0f%% run %d/%d  (any axis %.3f)",
                name.padding(toLength: 26, withPad: " ", startingAt: 0), best.travel, best.speed, best.ratio,
                best.seconds, flat * 100, longestRun, windowFrames, loose
            ))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINT_TRACES"] != nil))
    func printTraces() throws {
        let label = ProcessInfo.processInfo.environment["PRINT_TRACES"] ?? ""
        for recording in try SwipeFixtureTests.recordings(containing: label) {
            let start = recording.frames.first?.timestamp ?? 0
            print("=== \(recording.name) aspect \(String(format: "%.3f", recording.frames.first?.imageAspect ?? 0)) frames \(recording.frames.count)")
            print("    t  pose         T I M R L  pip°(I M R L)   reach(I M)  pinch  open  p(x,y)        v     ptr")
            var analyzer = GestureAnalyzer()
            var pointer = PointerController()
            for frame in recording.frames {
                let hand = SwipeFixtureTests.trackedHand(in: frame)
                let reading = analyzer.update(hand: hand, at: frame.timestamp)
                var line = String(format: "%5.2f", frame.timestamp - start)
                let heads = frame.bodies.filter { $0.normalizedPosition(of: .nose) != nil || $0.normalizedPosition(of: .neck) != nil }.count
                guard let reading, let hand, let features = HandFeatures(hand) else {
                    _ = pointer.update(nil, at: frame.timestamp)
                    print(line + " no hand  bodies \(frame.bodies.count)/\(heads) loose \(frame.looseHands.count)")
                    continue
                }
                func reach(_ finger: Finger) -> String {
                    guard let tip = hand[finger.tip], let mcp = hand[finger.mcp] else { return "  - " }
                    return String(format: "%.2f", tip.distance(to: mcp) / features.scale)
                }
                let angles = Finger.allCases.map { finger in
                    features.pipAngle(finger).map { String(format: "%3.0f", $0 * 180 / .pi) } ?? "  -"
                }
                line += " \((reading.pose.map { "\($0)" } ?? "-").padding(toLength: 12, withPad: " ", startingAt: 0))"
                line += " " + reading.extendedFingers.map { $0 ? "1" : "0" }.joined(separator: " ")
                line += "  " + angles.joined(separator: " ")
                line += "   \(reach(.index)) \(reach(.middle))"
                line += String(format: "   %.2f", features.pinchRatio ?? -1)
                line += String(format: "  %.2f", features.openness ?? -1)
                if let point = reading.pointer {
                    line += String(format: "  %.3f,%.3f", point.x, point.y)
                }
                line += String(format: "  %.2f", reading.palmSpeed)
                line += String(format: "  s %.3f", features.scale)
                line += features.isClosedHand ? " closed" : ""
                line += features.palmFacesCamera.map { $0 ? " palm" : " back" } ?? ""
                line += " bodies \(frame.bodies.count)/\(heads) loose \(frame.looseHands.count)"
                let tips = [HandJoint.indexTip, .middleTip].compactMap { hand.normalizedPosition(of: $0) }
                if tips.count == 2 {
                    line += String(format: "  tipY %.3f", (tips[0].y + tips[1].y) / 2)
                }
                let commands = pointer.update(
                    reading.pointer.map {
                        PointerController.Sample(point: $0, handScale: reading.handScale, pinching: reading.isPinching, scrollPose: reading.pose == .victory)
                    },
                    at: frame.timestamp
                )
                let scroll = commands.compactMap { command -> Double? in
                    if case .scroll(let amount) = command { return amount }
                    return nil
                }.reduce(0, +)
                line += pointer.isScrolling ? String(format: "  SCROLL %+.3f", scroll) : ""
                line += pointer.isPressed ? "  PRESSED" : ""
                line += reading.isTapDipping ? "  dip" : ""
                line += reading.tap.map { "  <<< TAP \($0)" } ?? ""
                line += reading.idleGesture ? "  <<< IDLE" : ""
                print(line)
            }
        }
    }
}
