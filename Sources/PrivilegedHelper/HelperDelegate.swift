import Foundation
import Security

private let callerRequirement = "anchor apple generic and identifier \"com.cullapp.CullApp\""

private func isCallerAuthorized(_ connection: NSXPCConnection) -> Bool {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else { return false }

    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(callerRequirement as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }

    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isCallerAuthorized(newConnection) else {
            newConnection.invalidate()
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        newConnection.exportedObject = HelperImpl()

        newConnection.invalidationHandler = {
            // Connection was invalidated
        }

        newConnection.interruptionHandler = {
            // Connection was interrupted
        }

        newConnection.resume()
        return true
    }
}

class HelperImpl: NSObject, PrivilegedHelperProtocol {

    func trashFiles(_ paths: [String], withReply reply: @escaping (Bool, String?) -> Void) {
        var successCount = 0
        var lastError: String?

        for path in paths {
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                successCount += 1
            } catch {
                lastError = "Failed to trash \(path): \(error.localizedDescription)"
            }
        }

        let allSucceeded = successCount == paths.count
        reply(allSucceeded, lastError)
    }

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply("1.0.0")
    }
}
