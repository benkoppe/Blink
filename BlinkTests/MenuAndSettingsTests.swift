import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Menu action context")
struct MenuActionContextTests {
    private let displayA = DisplayID(rawValue: "display-a")!
    private let displayB = DisplayID(rawValue: "display-b")!
    private let managedA = ManagedDisplayID(rawValue: "display-a")!
    private let managedB = ManagedDisplayID(rawValue: "display-b")!

    private func space(_ value: UInt64) -> SpaceID {
        SpaceID(rawValue: value)!
    }

    private func presentation() -> SpacePresentation {
        SpacePresentation(
            snapshot: SystemSpaceSnapshot(
                topologiesByManagedDisplay: [
                    managedA: DisplayTopology(
                        managedDisplayID: managedA,
                        spaceIDs: [space(100), space(101)],
                        currentSpaceID: space(100)
                    )!,
                    managedB: DisplayTopology(
                        managedDisplayID: managedB,
                        spaceIDs: [space(200), space(201), space(202)],
                        currentSpaceID: space(202)
                    )!,
                ],
                menuBarDisplayID: displayA
            ),
            projectedSpaceByManagedDisplay: [
                managedA: space(101),
                managedB: space(202),
            ],
            lastSpaceByManagedDisplay: [managedB: space(201)]
        )
    }

    @Test("Labels, availability, and requests share one physical display context")
    func menuValuesUseCapturedPhysicalDisplay() throws {
        let context = try #require(presentation().actionContext(
            for: displayB,
            configuration: SpaceSwitchConfiguration(wraps: false, velocity: 75)
        ))

        #expect((0..<context.spaceInfo.spaceCount).map(context.title) == [
            "Space 1", "Space 2", "Space 3",
        ])
        #expect(context.spaceInfo == SpaceInfo(currentIndex: 2, spaceCount: 3))
        #expect(context.canSubmit(.step(.left)))
        #expect(!context.canSubmit(.step(.right)))
        #expect(context.canSubmit(.lastSpace))
        #expect(context.request(for: .lastSpace, source: .menu) == SpaceSwitchRequest(
            action: .lastSpace,
            source: .menu,
            targetDisplayID: displayB,
            wraps: false,
            velocity: 75
        ))
    }

    @Test("Captured menu actions do not follow a conceptual cursor change")
    func capturedActionKeepsItsDisplay() throws {
        let value = presentation()
        let captured = try #require(value.actionContext(
            for: displayA,
            configuration: SpaceSwitchConfiguration(wraps: false, velocity: 100)
        ))
        let currentAfterCursorMove = try #require(value.actionContext(
            for: displayB,
            configuration: SpaceSwitchConfiguration(wraps: true, velocity: 200)
        ))

        #expect(currentAfterCursorMove.targetDisplayID == displayB)
        #expect(captured.request(for: .step(.left), source: .menu).targetDisplayID == displayA)
    }

    @Test("Menu-bar icon information remains separate from physical action context")
    func iconAndActionDisplaysRemainSeparate() throws {
        let value = presentation()
        let context = try #require(value.actionContext(
            for: displayB,
            configuration: .defaultValue
        ))

        #expect(value.menuBarSpaceInfo == SpaceInfo(currentIndex: 1, spaceCount: 2))
        #expect(context.spaceInfo == SpaceInfo(currentIndex: 2, spaceCount: 3))
        #expect(context.targetDisplayID == displayB)
    }

    @Test("Wrap and velocity are captured as one current configuration value")
    func configurationIsOneSnapshot() throws {
        var current = SpaceSwitchConfiguration(wraps: false, velocity: 90)
        var captureCount = 0
        func capture() throws -> SpaceActionContext {
            captureCount += 1
            let configuration = current
            return try #require(presentation().actionContext(
                for: displayB,
                configuration: configuration
            ))
        }

        let first = try capture()
        current = SpaceSwitchConfiguration(wraps: true, velocity: 180)
        let second = try capture()

        #expect(captureCount == 2)
        #expect(first.request(for: .step(.right), source: .menu).wraps == false)
        #expect(first.request(for: .step(.right), source: .menu).velocity == 90)
        #expect(second.request(for: .step(.right), source: .menu).wraps == true)
        #expect(second.request(for: .step(.right), source: .menu).velocity == 180)
        #expect(!first.canSubmit(.step(.right)))
        #expect(second.canSubmit(.step(.right)))
    }
}

@MainActor
@Suite("Injected settings defaults", .serialized)
struct InjectedSettingsDefaultsTests {
    @Test("Injected suites load and persist independently without standard defaults")
    func injectedDefaultsAreIndependent() async throws {
        let suiteAName = "com.thekoppe.BlinkTests.settings.a.\(UUID().uuidString)"
        let suiteBName = "com.thekoppe.BlinkTests.settings.b.\(UUID().uuidString)"
        let defaultsA = try #require(UserDefaults(suiteName: suiteAName))
        let defaultsB = try #require(UserDefaults(suiteName: suiteBName))
        defer {
            defaultsA.removePersistentDomain(forName: suiteAName)
            defaultsB.removePersistentDomain(forName: suiteBName)
        }

        let standardKeys = [
            "hotkeys",
            "swipeGestures",
            "settings.wrapSpaceSwitching",
            "settings.instantGestureSpeed",
            "settings.iconSize",
            "settings.iconSpacing",
            "settings.iconCornerRadius",
            "settings.iconStyle",
            "settings.disableSystemSwipeGestures",
            "settings.flipSwipeDirection",
            "settings.allowSameDirectionRepeat",
            "settings.sameDirectionRepeatSensitivity",
        ]
        let standardBefore = values(in: .standard, for: standardKeys)

        let generalA = GeneralSettingsManager(userDefaults: defaultsA)
        generalA.bindingsEnabled = false
        generalA.wrapSpaceSwitching = true
        generalA.instantGestureSpeed = InstantGestureSpeedSetting(
            preset: .custom,
            customValue: 123
        )
        let menuA = MenuBarSettingsManager(userDefaults: defaultsA)
        menuA.iconSize = 31

        let generalB = GeneralSettingsManager(userDefaults: defaultsB)
        generalB.bindingsEnabled = false
        let menuB = MenuBarSettingsManager(userDefaults: defaultsB)
        #expect(!generalB.wrapSpaceSwitching)
        #expect(generalB.instantGestureSpeed == InstantGestureSpeedSetting())
        #expect(menuB.iconSize == MenuBarSettingsManager.defaultIconSize)

        let dispatcherA = makeDispatcher()
        let hotkeysA = HotkeySettingsManager(
            registry: HotkeyRegistry { _ in SettingsFakeHotkeyMonitor() },
            dispatcher: dispatcherA,
            generalSettings: generalA,
            userDefaults: defaultsA
        )
        hotkeysA.performSetup()
        let customHotkey = KeyCombination(key: .grave, modifiers: [.control, .option])
        hotkeysA.assignRecordedCombination(customHotkey, to: .left)
        hotkeysA.shutdown()

        let gesturesA = GestureSettingsManager(
            dispatcher: dispatcherA,
            generalSettings: generalA,
            missionControlCapability: .init(),
            userDefaults: defaultsA
        )
        gesturesA.disableSystemSwipeGestures = false
        gesturesA.performSetup()
        let gestureID = SwipeGestureID(direction: .left, fingerCount: 4)
        gesturesA.gesture(withID: gestureID)?.action = .lastSpace
        await gesturesA.shutdown()
        await dispatcherA.shutdown()

        let reloadedGeneralA = GeneralSettingsManager(userDefaults: defaultsA)
        let reloadedMenuA = MenuBarSettingsManager(userDefaults: defaultsA)
        #expect(reloadedGeneralA.wrapSpaceSwitching)
        #expect(reloadedGeneralA.instantGestureSpeed.velocity == 123)
        #expect(reloadedMenuA.iconSize == 31)

        let dispatcherReloadedA = makeDispatcher()
        reloadedGeneralA.bindingsEnabled = false
        let reloadedHotkeysA = HotkeySettingsManager(
            registry: HotkeyRegistry { _ in SettingsFakeHotkeyMonitor() },
            dispatcher: dispatcherReloadedA,
            generalSettings: reloadedGeneralA,
            userDefaults: defaultsA
        )
        reloadedHotkeysA.performSetup()
        #expect(reloadedHotkeysA.hotkey(withAction: .left)?.keyCombination == customHotkey)

        let reloadedGesturesA = GestureSettingsManager(
            dispatcher: dispatcherReloadedA,
            generalSettings: reloadedGeneralA,
            missionControlCapability: .init(),
            userDefaults: defaultsA
        )
        reloadedGesturesA.disableSystemSwipeGestures = false
        reloadedGesturesA.performSetup()
        #expect(reloadedGesturesA.gesture(withID: gestureID)?.action == .lastSpace)

        let dispatcherB = makeDispatcher()
        let hotkeysB = HotkeySettingsManager(
            registry: HotkeyRegistry { _ in SettingsFakeHotkeyMonitor() },
            dispatcher: dispatcherB,
            generalSettings: generalB,
            userDefaults: defaultsB
        )
        hotkeysB.performSetup()
        #expect(hotkeysB.hotkey(withAction: .left)?.keyCombination == .init(
            key: .leftArrow,
            modifiers: .control
        ))
        let gesturesB = GestureSettingsManager(
            dispatcher: dispatcherB,
            generalSettings: generalB,
            missionControlCapability: .init(),
            userDefaults: defaultsB
        )
        gesturesB.disableSystemSwipeGestures = false
        gesturesB.performSetup()
        #expect(gesturesB.gesture(withID: gestureID)?.action == nil)

        reloadedHotkeysA.shutdown()
        await reloadedGesturesA.shutdown()
        hotkeysB.shutdown()
        await gesturesB.shutdown()
        await dispatcherReloadedA.shutdown()
        await dispatcherB.shutdown()

        let standardAfter = values(in: .standard, for: standardKeys)
        #expect(NSDictionary(dictionary: standardAfter).isEqual(to: standardBefore))
    }

    private func makeDispatcher() -> ActionDispatcher {
        ActionDispatcher(
            captureRequest: { _, _ in nil },
            submitRequest: { _ in .unavailable }
        )
    }

    private func values(
        in defaults: UserDefaults,
        for keys: [String]
    ) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
    }
}

@MainActor
private final class SettingsFakeHotkeyMonitor: HotkeyEventMonitoring {
    var isHealthy = true

    func enable() {}
    func disable() { isHealthy = false }
    func recoverIfNeeded() { isHealthy = true }
}
