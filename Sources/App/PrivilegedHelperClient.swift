import Foundation
import ServiceManagement

actor PrivilegedHelperClient {
    static let shared = PrivilegedHelperClient()

    private let helperMachServiceName = "com.cullapp.CullApp.PrivilegedHelper"
    private var connection: NSXPCConnection?

    private init() {}

    func installHelperIfNeeded() async {
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let auth = authRef else {
            print("Failed to create authorization: \(status)")
            return
        }

        var cfError: Unmanaged<CFError>?
        let success = SMJobBless(
            "kSMBlessPrivilegedHelper" as CFString,
            helperMachServiceName as CFString,
            auth,
            &cfError
        )

        if !success {
            if let error = cfError?.takeRetainedValue() {
                print("SMJobBless failed: \(error)")
            }
        }

        AuthorizationFree(auth, [])
    }

    func trashFiles(_ paths: [String]) async -> Bool {
        let conn = getConnection()
        guard let helper = conn.remoteObjectProxyWithErrorHandler({ error in
            print("XPC error: \(error)")
        }) as? PrivilegedHelperProtocol else {
            print("Failed to get helper proxy")
            return false
        }

        return await withCheckedContinuation { continuation in
            helper.trashFiles(paths) { success, errorMessage in
                if let msg = errorMessage {
                    print("Helper error: \(msg)")
                }
                continuation.resume(returning: success)
            }
        }
    }

    private func getConnection() -> NSXPCConnection {
        if let existing = connection {
            return existing
        }

        let conn = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { [weak self] in
                await self?.removeConnection()
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { [weak self] in
                await self?.removeConnection()
            }
        }
        conn.resume()
        connection = conn
        return conn
    }

    private func removeConnection() {
        connection = nil
    }
}
