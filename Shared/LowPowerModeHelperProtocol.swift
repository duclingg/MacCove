//
//  LowPowerModeHelperProtocol.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import Foundation

/// What MacCoveHelper, the launch daemon, does for MacCove: change Low
/// Power Mode, which only root can do. Compiled into both targets.
@objc nonisolated protocol LowPowerModeHelperProtocol {
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping @Sendable (Bool) -> Void)
}

nonisolated enum LowPowerModeHelper {
    /// The launchd label and Mach service, also the name of the plist in
    /// Contents/Library/LaunchDaemons.
    static let label = "com.ducling.MacCove.helper"
    static let plistName = "\(label).plist"

    private static let team = "9MZKF3V7G9"

    /// The helper only takes connections from MacCove, signed by us.
    static let appRequirement = #"anchor apple generic and identifier "com.ducling.MacCove" and certificate leaf[subject.OU] = "\#(team)""#
    /// MacCove only talks to a helper signed by us.
    static let helperRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
}
