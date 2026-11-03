import Foundation

/// MacCoveHelper runs as root. launchd starts it on demand when MacCove
/// connects to its Mach service, and it does only what MacCove needs an
/// administrator for.
final class LowPowerModeService: NSObject, LowPowerModeHelperProtocol {
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping @Sendable (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "lowpowermode", enabled ? "1" : "0"]
        do {
            try process.run()
            process.waitUntilExit()
            reply(process.terminationStatus == 0)
        } catch {
            reply(false)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LowPowerModeHelperProtocol.self)
        connection.exportedObject = LowPowerModeService()
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: LowPowerModeHelper.label)
// Refuses any process that isn't MacCove signed by us, before the delegate
// ever sees it.
listener.setConnectionCodeSigningRequirement(LowPowerModeHelper.appRequirement)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
dispatchMain()
