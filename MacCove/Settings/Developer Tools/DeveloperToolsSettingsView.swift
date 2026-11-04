//
//  DeveloperToolsSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import SwiftUI

struct DeveloperToolsSettingsView: View {
    // MARK: States
    @State private var installedTools: Set<AITool> = []
    @State private var toolsWithHooks: Set<AITool> = []

    // MARK: View
    var body: some View {
        Form {
            Section("Coding agents") {
                ForEach(AITool.allCases, id: \.self) { tool in
                    aiToolRow(tool)
                }
            }

            Section("Editors and terminal") {

            }

            Section("Accounts") {

            }
        }
        .formStyle(.grouped)
        .onAppear {
            for tool in AITool.allCases {
                refresh(tool)
            }
        }
    }

    private func refresh(_ tool: AITool) {
        if tool.setup.isInstalled() {
            installedTools.insert(tool)
        } else {
            installedTools.remove(tool)
        }
        if tool.setup.hooksSetup() {
            toolsWithHooks.insert(tool)
        } else {
            toolsWithHooks.remove(tool)
        }
    }

    // MARK: View Components
    private func toolLabel<Icon: View>(_ name: String, detail: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon()
                .frame(width: 25, height: 25)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func aiToolDetail(_ tool: AITool) -> String {
        if toolsWithHooks.contains(tool) {
            "Hooks in \(tool.path)"
        } else if installedTools.contains(tool) {
            "Adds hooks to \(tool.path)"
        } else {
            "Install \(tool.name) to use this"
        }
    }
    
    private func aiToolRow(_ tool: AITool) -> some View {
        let hasHooks = toolsWithHooks.contains(tool)
        return HStack(spacing: 12) {
            toolLabel(tool.name, detail: aiToolDetail(tool)) {
                tool.icon
            }
            Spacer(minLength: 0)
            if hasHooks {
                onStatus
            }
            Button(hasHooks ? "Remove" : "Set Up") {
                if hasHooks {
                    tool.setup.remove()
                } else {
                    tool.setup.setup()
                }
                refresh(tool)
            }
            .disabled(!hasHooks && !installedTools.contains(tool))
        }
    }
    
    private var onStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: 8, height: 8)
            Text("On")
        }
        .foregroundStyle(.green)
    }
}

#if DEBUG
#Preview {
    DeveloperToolsSettingsView()
}
#endif
