import Foundation

@objc public protocol PrivilegedHelperProtocol {
    func trashFiles(_ paths: [String], withReply reply: @escaping (Bool, String?) -> Void)
    func getVersion(withReply reply: @escaping (String) -> Void)
}

@objc public protocol AppProtocol {
    func reportProgress(_ progress: Double, withReply reply: @escaping (Bool) -> Void)
}
