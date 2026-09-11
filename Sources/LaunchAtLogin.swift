import Foundation
import ServiceManagement

/// Launch-at-login via the modern SMAppService API (macOS 13+).
enum LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Tidier: LaunchAtLogin toggle failed: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
}
