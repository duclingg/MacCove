//
//  SettingsCategory.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import SwiftUI

enum SettingsCategory: String, CaseIterable {
    case general = "General"
    case activities = "Activities"
    case developerTools = "Developer Tools"
    case extensions = "Extensions"
    case displays = "Displays"
    case permissions = "Permissions"
    case updates = "Updates"
    case about = "About"
    
    var icon: String {
        switch self {
        case .general: "gear"
        case .activities: "rectangle.stack"
        case .developerTools: "chevron.left.chevron.right"
        case .extensions: "puzzlepiece.extension"
        case .displays: "display"
        case .permissions: "shield"
        case .updates: "arrow.trianglehead.clockwise.rotate.90"
        case .about: "info.circle"
        }
    }
    
    var color: Color {
        switch self {
        case .general: .gray
        case .activities: .orange
        case .developerTools: .indigo
        case .extensions: .purple
        case .displays: .blue
        case .permissions: .cyan
        case .updates: .green
        case .about: .gray
        }
    }
}
