//
//  LiveSpaceIndicator.swift
//  Blink
//

import AppKit
import ApplicationServices
import Observation

/// Draws outside macOS 27's deferred status-item surface. The transparent
/// native item remains responsible for layout, hit testing and accessibility.
@MainActor
final class LiveSpaceIndicator {
    private let appState: AppState
    private let panel: NSPanel
    private let imageView = NSImageView()
    private let applicationElement = AXUIElementCreateApplication(getpid())
    private var geometryTimer: Timer?
    private var isActive = false

    init(appState: AppState) {
        self.appState = appState
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilityElement(false)
        imageView.setAccessibilityElement(false)
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = .labelColor
        panel.contentView = imageView

        // The status item can be rearranged independently of Blink's state.
        // Only geometry is sampled; image rendering remains observation-driven.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGeometry() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        geometryTimer = timer
        observeImage()
    }

    deinit {
        MainActor.assumeIsolated {
            geometryTimer?.invalidate()
            panel.orderOut(nil)
        }
    }

    // MARK: - Appearance

    func setDarkAppearance(_ isDark: Bool) {
        imageView.contentTintColor = isDark ? .white : .black
    }

    private func observeImage() {
        withObservationTracking {
            imageView.image = SpaceIconRenderer.image(appState: appState)
            updateGeometry()
            imageView.displayIfNeeded()
            panel.displayIfNeeded()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeImage()
            }
        }
    }

    // MARK: - Native status-item geometry

    private func updateGeometry() {
        guard
            imageView.image != nil,
            let frame = statusItemFrame(),
            frame.width > 0,
            frame.height > 0
        else {
            panel.orderOut(nil)
            setActive(false)
            return
        }
        setActive(true)
        if NSMenu.menuBarVisible() {
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderOut(nil)
        }
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        appState.usesLiveSpaceIndicator = active
    }

    private func statusItemFrame() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        var bar: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(applicationElement, kAXExtrasMenuBarAttribute as CFString, &bar) == .success,
            let bar,
            CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return nil }

        var children: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
            let item = (children as? [AXUIElement])?.first
        else { return nil }

        var position: CFTypeRef?
        var size: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
            let position,
            let size,
            CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard
            AXValueGetValue(position as! AXValue, .cgPoint, &point),
            AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
            let top = NSScreen.screens.first?.frame.maxY
        else { return nil }

        return NSRect(
            x: point.x,
            y: top - point.y - dimensions.height,
            width: dimensions.width,
            height: dimensions.height
        )
    }
}
