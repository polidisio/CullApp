import Foundation

let listener = NSXPCListener(machServiceName: "com.cullapp.CullApp.PrivilegedHelper")
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
