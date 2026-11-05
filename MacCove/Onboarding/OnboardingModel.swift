//
//  OnboardingModel.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import AVFoundation
import Contacts
import SwiftUI

/// The welcome that drops out of the notch the first time MacCove opens:
/// which step it's on, and the switches and buttons on each. Everything it
/// turns on goes straight to the monitor or setting that Settings uses, so
/// leaving partway keeps what was chosen.
@Observable
final class OnboardingModel {
    enum Step: Hashable {
        /// Running from the disk image.
        case move
        /// Copied out, with the disk image still mounted.
        case cleanup
        case welcome
        case how
        case access
        case connect
        /// What Set Up will add to an agent's settings, before it does.
        case preview(AITool)
        /// Only when a display has no notch.
        case displays
        case updates
        case done

        /// The card's width, from the design. Its height follows what's in it.
        var width: CGFloat {
            switch self {
            case .move, .cleanup: 460
            case .welcome: 520
            case .how, .access: 580
            case .connect, .preview: 620
            case .displays, .updates: 560
            case .done: 340
            }
        }
    }

    enum Tab: String, CaseIterable {
        case everyday
        case developerTools

        var title: String {
            switch self {
            case .everyday: "Everyday"
            case .developerTools: "Developer tools"
            }
        }
    }

    /// Whether this welcome is set to show at launch.
    static let completedKey = "OnboardingCompleted"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    private(set) var step: Step
    /// Dropped out of the notch. False while it drops and folds back.
    var isOpen = false
    /// Folded to the pill at the top edge, on a display without a notch,
    /// before it slides away.
    private(set) var isPill = false
    /// The pill has slid up past the top edge, all of it at once and in
    /// its own shape.
    private(set) var isSlidAway = false
    /// Whether the notch has something to show, or always shows its pill,
    /// to take over from the welcome's at the end.
    @ObservationIgnored var notchHasActivities: () -> Bool = { false }
    var tab: Tab = .everyday
    /// A button is doing something that takes a moment: copying, ejecting.
    private(set) var isWorking = false
    /// Why copying or cleaning up didn't work, shown in the card.
    private(set) var installError: String?

    // MARK: The display

    /// The notch the card drops out of, or on a display without one, the
    /// strip along the top edge it drops from.
    private(set) var notchSize = CGSize(width: NSScreen.virtualNotchWidth, height: 24)
    private(set) var hasNotch = true
    private(set) var hasDisplayWithoutNotch = false
    /// The card, in the panel's coordinates, so clicks beside it go to
    /// what's underneath.
    var cardFrame: CGRect = .zero
    /// The bottom middle of MacCove's menu bar item in the panel's
    /// coordinates, for Done to point at; `nil` when it's hidden.
    private(set) var menuItemPoint: CGPoint?

    // MARK: Install

    let installLocation: InstallLocation
    /// Opened from the disk image after the welcome was already done: only
    /// the offer to copy it shows.
    private let isInstallOnly: Bool

    // MARK: Allow a few things

    private(set) var music: OnboardingAccess = .notAsked
    /// Bringing forward the Terminal or iTerm window a command or agent
    /// ran in, and pressing Esc in iTerm.
    private(set) var terminalControl: OnboardingAccess = .notAsked
    private(set) var iTermControl: OnboardingAccess = .notAsked
    let hasITerm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalWindow.iTerm) != nil
    /// Keeps bubbles clear of app menus. Waiting once asked, until it's
    /// turned on in System Settings.
    private(set) var accessibility: OnboardingAccess = AppMenuExtent.isAllowed ? .allowed : .notAsked
    let network = LocalNetworkProbe.shared
    private(set) var helper: OnboardingAccess = LowPowerModeHelperSetup.access
    let hasHelper = LowPowerModeHelperSetup.isAvailable
    let launchAtLogin = LaunchAtLogin()
    @ObservationIgnored private var approvalWatch: Task<Void, Never>?

    // MARK: What shows up

    let calendar: CalendarMonitor
    /// Xcode's setup guide, shown in the card while the welcome is up.
    let xcode: XcodeBuildMonitor?
    let reminders: RemindersMonitor
    let mirror: MirrorCamera
    /// For messaging people on their birthday, from Next meeting.
    private(set) var contacts = OnboardingModel.contactsAccess
    let shelf: FileShelf
    let deviceBatteries: DeviceBatteryMonitor
    let downloads: DownloadMonitor
    let github: GitHubMonitor
    let menuBarItem: MenuBarItem
    private(set) var isClipboardEnabled = ClipboardMonitor.isEnabled
    @ObservationIgnored private let setClipboard: (Bool) -> Void

    private(set) var installedAgents: [AITool] = []
    private(set) var agentsWithHooks: Set<AITool> = []
    private(set) var isXcodeInstalled = false
    /// Set up, with every event added in Xcode's Behaviors: On, from the
    /// moment the guide sees the last one, rather than when the step's
    /// next opened. Follows Xcode's settings as the guide reads them.
    var hasXcodeScripts: Bool {
        XcodeSetupProgress.shared.isComplete && XcodeBehaviorScripts.isSetUp
    }
    private(set) var hasTerminalHook = false
    /// From the moment GitHub accepts the sign-in.
    var isGitHubConnected: Bool {
        GitHubConnection.shared.isConnected && !github.needsSignIn
    }

    // MARK: Given by the window

    /// Runs while macOS asks for something, with the card lowered beneath
    /// macOS's prompt until it's done.
    /// Runs while System Settings is up, with the card below it, since
    /// System Settings is an ordinary window.
    @ObservationIgnored var whileInSystemSettings: (_ work: @escaping @MainActor () async -> Void) -> Void = { work in
        Task { await work() }
    }
    @ObservationIgnored var whileAsking: (_ work: @escaping @MainActor () async -> Void) -> Void = { work in
        Task { await work() }
    }
    @ObservationIgnored var locateMenuItem: () -> CGPoint? = { nil }
    /// Folded back into the notch: the window can go.
    @ObservationIgnored var onFinish: () -> Void = {}

    init(
        installLocation: InstallLocation,
        isFirstRun: Bool,
        calendar: CalendarMonitor,
        xcode: XcodeBuildMonitor?,
        reminders: RemindersMonitor,
        mirror: MirrorCamera,
        shelf: FileShelf,
        deviceBatteries: DeviceBatteryMonitor,
        downloads: DownloadMonitor,
        github: GitHubMonitor,
        menuBarItem: MenuBarItem,
        setClipboardEnabled: @escaping (Bool) -> Void
    ) {
        self.installLocation = installLocation
        isInstallOnly = !isFirstRun
        self.calendar = calendar
        self.reminders = reminders
        self.xcode = xcode
        self.mirror = mirror
        self.shelf = shelf
        self.deviceBatteries = deviceBatteries
        self.downloads = downloads
        self.github = github
        self.menuBarItem = menuBarItem
        setClipboard = setClipboardEnabled
        step = switch installLocation {
        case .diskImage: .move
        case .leftoverImage where isFirstRun: .cleanup
        default: .welcome
        }
        refreshTools()
        Task { [weak self] in
            let music = await MusicAutomation.status()
            let terminal = await AutomationPermission.status(of: TerminalWindow.terminal)
            let iTerm = await AutomationPermission.status(of: TerminalWindow.iTerm)
            self?.music = music
            self?.terminalControl = terminal
            self?.iTermControl = iTerm
        }
    }

    func setDisplay(notchSize: CGSize, hasNotch: Bool) {
        self.notchSize = notchSize
        self.hasNotch = hasNotch
        hasDisplayWithoutNotch = NSScreen.screens.contains { !$0.hasNotch }
    }

    // MARK: - Steps

    /// The steps after the install ones, in order.
    var flow: [Step] {
        var steps: [Step] = [.welcome, .how, .access, .connect]
        if hasDisplayWithoutNotch {
            steps.append(.displays)
        }
        return steps + [.updates, .done]
    }

    /// The steps the dots stand for, and which one's lit. `nil` before
    /// the welcome and on Done.
    var progress: (count: Int, current: Int)? {
        let dotted = flow.filter { $0 != .done }
        let shown: Step = if case .preview = step { .connect } else { step }
        guard let index = dotted.firstIndex(of: shown) else { return nil }
        return (dotted.count, index)
    }

    var primaryTitle: String {
        switch step {
        case .move: "Copy and Relaunch"
        case .cleanup: "Clean Up"
        case .welcome: "Get Started"
        case .preview: "Add Hooks"
        case .updates: "Finish"
        case .done: "Done"
        case .how, .access, .connect, .displays: "Continue"
        }
    }

    var secondaryTitle: String? {
        switch step {
        case .move: "Not Now"
        case .cleanup: "Keep It"
        case .preview: "Cancel"
        case .welcome, .done: nil
        case .how, .access, .connect, .displays, .updates: "Back"
        }
    }

    func primaryAction() {
        switch step {
        case .move:
            copyToApplications()
        case .cleanup:
            cleanUp()
        case let .preview(tool):
            tool.setup.setup()
            refreshTools()
            go(to: .connect)
            if agentsWithHooks.contains(tool) {
                whileAsking { await tool.askForPermissions() }
            }
        case .done:
            finish()
        default:
            goForward()
        }
    }

    func secondaryAction() {
        switch step {
        case .move:
            if isInstallOnly {
                finish()
            } else {
                go(to: .welcome)
            }
        case .cleanup:
            go(to: .welcome)
        case .preview:
            go(to: .connect)
        default:
            goBack()
        }
    }

    func showPreview(_ tool: AITool) {
        go(to: .preview(tool))
    }

    private func goForward() {
        guard let index = flow.firstIndex(of: step), index + 1 < flow.count else { return }
        go(to: flow[index + 1])
    }

    private func goBack() {
        guard let index = flow.firstIndex(of: step), index > 0 else { return }
        go(to: flow[index - 1])
    }

    private func go(to next: Step) {
        let wasDone = step == .done
        withAnimation(.island) {
            step = next
        }
        stepChanged(wasDone: wasDone)
    }

    private func stepChanged(wasDone: Bool) {
        switch step {
        case .access:
            // Already on from before the welcome shows as Allowed.
            network.refresh()
            helper = LowPowerModeHelperSetup.access
            if AppMenuExtent.isAllowed {
                accessibility = .allowed
            }
            launchAtLogin.refresh()
            if helper == .waiting || accessibility == .waiting {
                watchApprovals()
            }
        case .connect:
            calendar.refreshPermissions()
            reminders.refreshPermissions()
            mirror.refreshPermissions()
            contacts = Self.contactsAccess
            refreshTools()
        case .done:
            menuItemPoint = menuBarItem.isShown ? locateMenuItem() : nil
            menuBarItem.setHighlighted(true)
        default:
            break
        }
        if wasDone, step != .done {
            menuBarItem.setHighlighted(false)
        }
        if step != .access {
            approvalWatch?.cancel()
        }
    }

    /// The welcome won't show at launch again, and the card folds back
    /// into the notch.
    func finish() {
        if !isInstallOnly {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
        }
        menuBarItem.setHighlighted(false)
        approvalWatch?.cancel()
        network.stop()
        guard !hasNotch else {
            withAnimation(.island) {
                isOpen = false
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.onFinish()
            }
            return
        }
        // No notch to fold into: it folds to the pill at the top edge, where
        // activities show, and stays there a moment so you see where. Then
        // the notch takes over if it has something to show; otherwise the
        // pill slides up out of sight.
        withAnimation(.island) {
            isPill = true
            isOpen = false
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            if !self.notchHasActivities() {
                withAnimation(.islandSlide) {
                    self.isSlidAway = true
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
            self.onFinish()
        }
    }

    // MARK: - Install

    private func copyToApplications() {
        isWorking = true
        installError = nil
        Task { [weak self] in
            do {
                try await InstallLocation.copyToApplicationsAndRelaunch()
            } catch {
                self?.isWorking = false
                self?.installError = "Couldn’t copy MacCove. \(error.localizedDescription)"
            }
        }
    }

    private func cleanUp() {
        guard case let .leftoverImage(volume, image) = installLocation else {
            go(to: .welcome)
            return
        }
        isWorking = true
        installError = nil
        Task { [weak self] in
            do {
                try await InstallLocation.cleanUp(volume: volume, image: image)
                self?.isWorking = false
                self?.go(to: .welcome)
            } catch {
                self?.isWorking = false
                self?.installError = "Couldn’t clean up. \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Allow a few things

    func allowMusic() {
        music = .asking
        whileAsking { [weak self] in
            let music = await MusicAutomation.request()
            self?.music = music
        }
    }

    /// Opens Terminal hidden first if it isn't open, since only an open app
    /// can be asked about.
    func allowTerminal() {
        terminalControl = .asking
        whileAsking { [weak self] in
            let access = await AutomationPermission.request(TerminalWindow.terminal, openingHidden: true)
            self?.terminalControl = access
        }
    }

    func allowITerm() {
        iTermControl = .asking
        whileAsking { [weak self] in
            let access = await AutomationPermission.request(TerminalWindow.iTerm, openingHidden: true)
            self?.iTermControl = access
        }
    }

    func installHelper() {
        openSystemSettings { [weak self] in
            self?.helper = LowPowerModeHelperSetup.install()
            if self?.helper == .waiting {
                self?.watchApprovals()
            }
        }
    }

    /// Find AirPlay speakers: macOS asks if it never has. If it was turned
    /// off, Privacy & Security opens with the steps, and the card stays
    /// lowered beneath it while it's up.
    /// Find AirPlay speakers: Privacy & Security opens with the steps, and
    /// the card steps below it. It comes back in front and in focus the
    /// moment Local Network is on, with System Settings still open, or if
    /// you leave System Settings, or the guide's closed.
    func allowNetwork() {
        network.ask()
        whileInSystemSettings { [weak self] in
            guard let self else { return }
            var wasInFront = false
            // Up to five minutes.
            for _ in 0..<600 {
                if self.network.access == .allowed { return }
                if !NotchGuides.shared.isShowing(LocalNetworkProbe.guideID) { return }
                if SystemSettings.isInFront {
                    wasInFront = true
                } else if wasInFront {
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Opens System Settings with the card lowered beneath it for as long
    /// as it's in front, so the card never covers it.
    func openSystemSettings(_ open: @escaping () -> Void) {
        whileInSystemSettings {
            open()
            // A moment for it to come forward.
            try? await Task.sleep(for: .seconds(1))
            // Up to five minutes.
            for _ in 0..<600 {
                guard SystemSettings.isInFront else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// macOS's own prompt, which offers to open Accessibility in System
    /// Settings.
    func allowAccessibility() {
        whileAsking { [weak self] in
            AppMenuExtent.requestPermission()
            self?.accessibility = AppMenuExtent.isAllowed ? .allowed : .waiting
            if self?.accessibility == .waiting {
                self?.watchApprovals()
            }
            // macOS's prompt stays up after this returns: lowered until
            // it's allowed, or long enough to read it.
            for _ in 0..<40 {
                if AppMenuExtent.isAllowed { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Turned on in Login Items or Accessibility, which MacCove isn't told
    /// about.
    private func watchApprovals() {
        approvalWatch?.cancel()
        approvalWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                if self.helper == .waiting {
                    self.helper = LowPowerModeHelperSetup.access
                }
                if self.accessibility == .waiting, AppMenuExtent.isAllowed {
                    self.accessibility = .allowed
                }
                if self.helper != .waiting, self.accessibility != .waiting { return }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin.setEnabled(enabled)
    }

    // MARK: - What shows up

    /// Turned on, it reads what's copied now, which is when macOS asks
    /// whether MacCove may paste from other apps.
    func setClipboardEnabled(_ enabled: Bool) {
        isClipboardEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: ClipboardMonitor.enabledKey)
        setClipboard(enabled)
        guard enabled else { return }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow, .alwaysDeny:
            break
        default:
            whileAsking {
                _ = NSPasteboard.general.string(forType: .string)
            }
        }
    }

    // MARK: Asked for from the tiles

    /// Next meeting: turning it on asks for Calendar. The card waits below
    /// macOS's prompt for the answer, then takes focus back.
    func allowCalendar() {
        let calendar = calendar
        whileAsking {
            calendar.setEnabled(true)
            // Up to a minute for an answer, read from macOS each time
            // rather than trusting the first read after it.
            for _ in 0..<120 {
                calendar.refreshPermissions()
                if calendar.access != .notDetermined { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func allowReminders() {
        let reminders = reminders
        whileAsking {
            reminders.setEnabled(true)
            for _ in 0..<120 {
                reminders.refreshPermissions()
                if reminders.access != .notDetermined { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Mirror's camera, asked for now rather than the first time it opens.
    func allowCamera() {
        whileAsking { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .video)
            self?.mirror.refreshPermissions()
        }
    }

    /// Show when to leave, under Next meeting, which asks where you are.
    func allowLeaveTime() {
        calendar.setLeaveTimeEnabled(true)
        whileAsking { [weak self] in
            // Answered through Calendar's location delegate.
            for _ in 0..<40 {
                if self?.calendar.locationAccess != .notDetermined { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Who to message on their birthday, from Next meeting.
    func allowContacts() {
        whileAsking { [weak self] in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                CNContactStore().requestAccess(for: .contacts) { _, _ in
                    done.resume()
                }
            }
            self?.contacts = Self.contactsAccess
        }
    }

    private static var contactsAccess: OnboardingAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// What's installed and what's set up, read again after each Set Up.
    func refreshTools() {
        installedAgents = AITool.allCases.filter { $0.setup.isInstalled() }
        agentsWithHooks = Set(AITool.allCases.filter { $0.setup.hooksSetup() })
        isXcodeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") != nil
        XcodeSetupProgress.shared.refreshBehaviors()
        hasTerminalHook = TerminalHook.isInstalled()
    }

    /// Xcode's setup guide, in the card while the welcome has the notch's
    /// place, and kept open there until it's closed with Done.
    func setUpXcode() {
        guard XcodeBehaviorScripts.prepare() else { return }
        xcode?.startGuide(staysOpen: true)
        // macOS asks to let MacCove control Xcode now, with the card below
        // its prompt, then the card takes focus back.
        whileAsking {
            await XcodeSetupProgress.shared.askToControlAtSetUp()
        }
    }

    /// Xcode's guide is up, in the card.
    var isXcodeGuiding: Bool {
        xcode?.guide != nil
    }

    /// Opening a new terminal window is left, which the card's guide says.
    func setUpTerminal() {
        TerminalHook.setUp()
        refreshTools()
        if hasTerminalHook {
            whileAsking { await TerminalWindow.askToControl() }
        }
    }

    /// One step with the GitHub CLI signed in; without, the card's guide
    /// walks through gh auth login, and connects once it's done.
    func connectGitHub() {
        guard !isWaitingForGitHub, !isGitHubConnected else { return }
        let github = github
        Task {
            await GitHubSetup.connect(monitor: github)
        }
    }

    /// Checking the GitHub CLI's sign-in with GitHub, or waiting in the
    /// card's guide for gh auth login.
    var isWaitingForGitHub: Bool {
        GitHubConnection.shared.isBusy
    }

    /// The guide or notice MacCove has for you, shown in the card while it
    /// has the notch's place.
    var guide: NotchGuide? {
        NotchGuides.shared.current
    }
}
