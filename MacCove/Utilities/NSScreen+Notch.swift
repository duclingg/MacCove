import AppKit

extension NSScreen {
    /// The display chosen as main in System Settings › Displays, the one
    /// with the menu bar. Unlike `NSScreen.main`, this doesn't follow the
    /// key window between displays.
    static var primary: NSScreen? {
        screens.first
    }

    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// Size of the camera housing in points. Screens without one get a
    /// virtual notch the height of the menu bar so the island still lines up.
    var notchSize: CGSize {
        guard hasNotch,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            let menuBarHeight = frame.maxY - visibleFrame.maxY
            return CGSize(width: 186, height: max(menuBarHeight, 24))
        }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }
}
