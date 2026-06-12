import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement=true in Info.plist 已等效设置 .accessory，无需重复调用
withExtendedLifetime(delegate) { app.run() }
