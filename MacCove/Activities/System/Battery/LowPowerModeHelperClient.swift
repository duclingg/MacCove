//
//  LowPowerModeHelperClient.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import Foundation
import ServiceManagement

/// Talks to MacCoveHelper, the launch daemon that changes Low Power Mode as
/// root, so there's no password prompt. The first time, it registers the
/// daemon with launchd; macOS then asks the user to allow it once in
/// System Settings › General › Login Items, which this opens.
final class LowPowerModeHelperClient {
    private let service = SMAppService.daemon(plistName: LowPowerModeHelper.plistName)
    private var connection: NSXPCConnection?

    /// Whether the helper changed it. False also while it awaits approval.
    func setLowPowerMode(_ enabled: Bool) async -> Bool {
        guard isRegistered() else { return false }
        let connection = currentConnection()
        return await withCheckedContinuation { continuation in
            // XPC calls exactly one of the error handler and the reply.
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: false)
            } as? LowPowerModeHelperProtocol
            guard let proxy else {
                continuation.resume(returning: false)
                return
            }
            proxy.setLowPowerMode(enabled) { changed in
                continuation.resume(returning: changed)
            }
        }
    }

    private func isRegistered() -> Bool {
        if service.status != .enabled, service.status != .requiresApproval {
            // Throws while approval is pending, which the status shows anyway.
            try? service.register()
        }
        if service.status == .requiresApproval {
            SystemSettings.openLoginItems()
        }
        return service.status == .enabled
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: LowPowerModeHelper.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LowPowerModeHelperProtocol.self)
        connection.setCodeSigningRequirement(LowPowerModeHelper.helperRequirement)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}
