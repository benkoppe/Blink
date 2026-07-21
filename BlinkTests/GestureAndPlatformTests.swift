import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Gesture and platform domain")
struct GestureAndPlatformTests {
    @Test("Swipe recognizer emits a horizontal gesture")
    func recognizerEmitsSwipe() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: false,
            sameDirectionRepeatSensitivity: 0.06
        )

        let first = GestureSample(touches: touches(at: 0))
        let second = GestureSample(touches: touches(at: 0.08))
        #expect(
            recognizer.consume(
                first,
                configuration: configuration,
                ignoreNewGesture: false
            ) == nil
        )
        let result = recognizer.consume(
            second,
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(result?.direction == .right)
        #expect(result?.fingerCount == 3)
    }

    @Test("Ignored gesture sessions remain ignored")
    func recognizerIgnoresWholeSession() {
        var recognizer = SwipeRecognizer()
        let configuration = SwipeRecognizer.Configuration(
            flipsDirection: false,
            allowsSameDirectionRepeat: true,
            sameDirectionRepeatSensitivity: 0
        )
        _ = recognizer.consume(
            GestureSample(touches: touches(at: 0)),
            configuration: configuration,
            ignoreNewGesture: true
        )
        let result = recognizer.consume(
            GestureSample(touches: touches(at: 0.2)),
            configuration: configuration,
            ignoreNewGesture: false
        )
        #expect(result == nil)
    }

    @Test("Overlay classifier distinguishes Expose and Mission Control")
    func overlayClassifierDistinguishesModes() {
        let classifier = OverlayClassifier()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let backdrop = WindowDescriptor(
            ownerName: "Dock",
            ownerBundleID: "com.apple.dock",
            layer: 18,
            bounds: bounds,
            name: nil
        )
        let preview = WindowDescriptor(
            ownerName: "Dock",
            ownerBundleID: "com.apple.dock",
            layer: 20,
            bounds: bounds,
            name: nil
        )

        #expect(
            classifier.classify(
                windows: [backdrop, preview],
                displayBounds: bounds
            ) == .appExpose
        )
        #expect(
            classifier.classify(
                windows: [backdrop, preview, preview],
                displayBounds: bounds
            ) == .appExpose
        )
        #expect(
            classifier.classify(
                windows: [backdrop, preview, preview, preview],
                displayBounds: bounds
            ) == .missionControl
        )
    }

    @Test("CGS parser rejects an active Space absent from topology")
    func parserRejectsInvalidCurrentSpace() {
        let display: NSDictionary = [
            "Display Identifier": "display-a",
            "Current Space": ["id64": NSNumber(value: 999), "type": 0],
            "Spaces": [
                ["id64": NSNumber(value: 100)],
                ["id64": NSNumber(value: 101)],
            ],
        ]

        #expect(
            CGSSpaceSystemClient.parseTopology(
                display,
                globalActiveSpaceID: 999
            ) == nil
        )
    }

    private func touches(at x: CGFloat) -> [GestureTouchSample] {
        (0..<3).map {
            GestureTouchSample(
                identity: String($0),
                position: CGPoint(x: x, y: CGFloat($0) * 0.01),
                isEnded: false
            )
        }
    }
}
