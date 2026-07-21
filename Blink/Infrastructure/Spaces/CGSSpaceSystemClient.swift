import AppKit
import CoreGraphics
import Darwin
import Foundation

private typealias CGSConnectionIDFn = @convention(c) () -> Int32
private typealias CGSGetActiveSpaceFn = @convention(c) (Int32) -> UInt64
private typealias CGSCopyDisplaySpacesFn =
    @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?
private typealias CGSCopyMenuBarDisplayFn =
    @convention(c) (Int32) -> Unmanaged<CFString>?

nonisolated protocol SpaceSystemClient: Sendable {
    func loadSnapshot() throws -> SystemSpaceSnapshot
}

nonisolated final class CGSSpaceSystemClient: SpaceSystemClient, @unchecked Sendable {
    private struct Symbols {
        let connection: CGSConnectionIDFn
        let activeSpace: CGSGetActiveSpaceFn
        let displaySpaces: CGSCopyDisplaySpacesFn
        let menuBarDisplay: CGSCopyMenuBarDisplayFn?
    }

    private let symbols: Result<Symbols, SpaceSystemError>

    init() {
        symbols = Self.loadSymbols()
    }

    func loadSnapshot() throws -> SystemSpaceSnapshot {
        let symbols = try symbols.get()
        let connection = symbols.connection()
        guard connection != 0 else {
            throw SpaceSystemError.invalidConnection
        }

        let globalActiveSpaceID = symbols.activeSpace(connection)
        guard
            globalActiveSpaceID != 0,
            let rawDisplays = symbols.displaySpaces(connection, nil)?.takeRetainedValue()
        else {
            throw SpaceSystemError.unavailableSpaceList
        }

        let menuBarDisplayID = symbols.menuBarDisplay?(connection)
            .map { $0.takeRetainedValue() as String }
            .flatMap(DisplayID.init(rawValue:))
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        var topologies: [DisplayID: DisplayTopology] = [:]

        for value in rawDisplays as NSArray {
            guard let display = value as? NSDictionary else { continue }

            if let topology = Self.parseTopology(
                display,
                globalActiveSpaceID: globalActiveSpaceID
            ) {
                topologies[topology.displayID] = topology
            }
        }

        guard !topologies.isEmpty else {
            throw SpaceSystemError.noValidDisplays
        }

        return SystemSpaceSnapshot(
            topologiesByDisplay: topologies,
            menuBarDisplayID: menuBarDisplayID,
            frontmostBundleID: frontmostBundleID
        )
    }

    private static func loadSymbols() -> Result<Symbols, SpaceSystemError> {
        guard
            let handle = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL
            )
        else {
            return .failure(.requiredSymbolUnavailable("CoreGraphics"))
        }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }

        guard let connection = load("CGSMainConnectionID", as: CGSConnectionIDFn.self) else {
            return .failure(.requiredSymbolUnavailable("CGSMainConnectionID"))
        }
        guard
            let activeSpace = load("CGSGetActiveSpace", as: CGSGetActiveSpaceFn.self)
        else {
            return .failure(.requiredSymbolUnavailable("CGSGetActiveSpace"))
        }
        guard
            let displaySpaces = load(
                "CGSCopyManagedDisplaySpaces",
                as: CGSCopyDisplaySpacesFn.self
            )
        else {
            return .failure(.requiredSymbolUnavailable("CGSCopyManagedDisplaySpaces"))
        }

        return .success(
            Symbols(
                connection: connection,
                activeSpace: activeSpace,
                displaySpaces: displaySpaces,
                menuBarDisplay: load(
                    "CGSCopyActiveMenuBarDisplayIdentifier",
                    as: CGSCopyMenuBarDisplayFn.self
                )
            )
        )
    }

    static func parseTopology(
        _ display: NSDictionary,
        globalActiveSpaceID: UInt64
    ) -> DisplayTopology? {
        guard
            let rawDisplayID = display["Display Identifier"] as? String,
            let displayID = DisplayID(rawValue: rawDisplayID),
            let rawSpaces = display["Spaces"] as? NSArray
        else {
            return nil
        }

        let currentSpace = display["Current Space"] as? NSDictionary
        let rawCurrentSpaceID =
            (currentSpace?["id64"] as? NSNumber)?.uint64Value
            ?? globalActiveSpaceID

        guard let currentSpaceID = SpaceID(rawValue: rawCurrentSpaceID) else {
            return nil
        }

        let spaceIDs = rawSpaces.compactMap { value -> SpaceID? in
            guard let space = value as? NSDictionary else { return nil }
            return (space["id64"] as? NSNumber)
                .flatMap { SpaceID(rawValue: $0.uint64Value) }
        }

        return DisplayTopology(
            displayID: displayID,
            spaceIDs: spaceIDs,
            currentSpaceID: currentSpaceID,
            currentSpaceKind: SpaceKind(
                rawValueOrUnknown: (currentSpace?["type"] as? NSNumber)?.intValue
            )
        )
    }
}
