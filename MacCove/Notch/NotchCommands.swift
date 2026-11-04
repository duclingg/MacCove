//
//  NotchCommands.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import Observation

/// What Settings can open in the notch. `AppDelegate` fills these in once
/// the notch exists; until then, and in previews, they do nothing.
@Observable
final class NotchCommands {
    @ObservationIgnored var showClipboardHistory: () -> Void = {}
    @ObservationIgnored var showTodayEvents: () -> Void = {}
    @ObservationIgnored var showShelf: () -> Void = {}
}
