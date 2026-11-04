//
//  SettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import SwiftUI

struct SettingsView: View {
    // MARK: States
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedCategory: SettingsCategory = .general
    @State private var searchText = ""
    
    // MARK: View
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedCategory) {
                ForEach(SettingsCategory.allCases, id: \.self) { category in
                    categoryRow(category)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 174, ideal: 174, max: 240)
        } detail: {
            Group {
                switch selectedCategory {
                case .general: GeneralSettingsView()
                case .activities: ActivitiesSettingsView()
                case .developerTools: DeveloperToolsSettingsView()
                case .extensions: ExtensionsSettingsView()
                case .displays: DisplaysSettingsView()
                case .permissions: PermissionsSettingsView()
                case .updates: UpdatesSettingsView()
                case .about: AboutSettingsView()
                }
            }
            .navigationTitle(selectedCategory.rawValue)
        }
        .searchable(text: $searchText, placement: .sidebar)
    }
    
    // MARK: View Components
    private func categoryRow(_ category: SettingsCategory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: category.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(category.color)
                )

            Text(category.rawValue)
                .lineLimit(1)
        }
    }
}
