import Foundation

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Verify the calling app's code signature
        // In production, verify code signature matches expected value
        let callingApp = newConnection.exportedInterface

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
