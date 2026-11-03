import AppKit
import OSLog

/// Keeps the island above the lock screen, so a locked Mac shows Touch ID
/// in the notch the way an iPhone shows Face ID in its island.
///
/// Ordinary windows sit under the lock screen whatever their level. This
/// moves the panel into a window server space of its own, at the level
/// macOS gives Notification Center on the lock screen, through SkyLight's
/// private functions, as other notch apps do. They're looked up at run
/// time, so if a macOS update renames them the island just stays off the
/// lock screen.
enum LockScreenSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private static let log = Logger(subsystem: "com.justinhoang.MacCove", category: "LockScreenSpace")
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    /// Notification Center's level on the lock screen.
    private static let lockScreenLevel: Int32 = 400

    /// Call once the window has a window number, after it's first ordered in.
    static func move(_ window: NSWindow) {
        guard let skyLight = dlopen(skyLightPath, RTLD_NOW),
              let mainConnectionID = function("SLSMainConnectionID", in: skyLight, as: MainConnectionID.self),
              let createSpace = function("SLSSpaceCreate", in: skyLight, as: SpaceCreate.self),
              let setAbsoluteLevel = function("SLSSpaceSetAbsoluteLevel", in: skyLight, as: SpaceSetAbsoluteLevel.self),
              let showSpaces = function("SLSShowSpaces", in: skyLight, as: ShowSpaces.self),
              let addWindows = function("SLSSpaceAddWindowsAndRemoveFromSpaces", in: skyLight, as: SpaceAddWindowsAndRemoveFromSpaces.self)
        else {
            log.error("SkyLight's space functions are missing; the island won't show on the lock screen")
            return
        }

        let connection = mainConnectionID()
        let space = createSpace(connection, 1, 0)
        _ = setAbsoluteLevel(connection, space, lockScreenLevel)
        _ = showSpaces(connection, [space] as CFArray)
        // 7 moves the window out of every other space as it joins this one.
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }

    private static func function<Function>(_ name: String, in library: UnsafeMutableRawPointer, as type: Function.Type) -> Function? {
        guard let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
