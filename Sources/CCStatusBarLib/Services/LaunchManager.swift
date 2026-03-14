import ServiceManagement

enum LaunchManager {
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        DebugLog.log("[LaunchManager] SMAppService status: \(status.rawValue) (enabled=\(status == .enabled))")
        return status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        DebugLog.log("[LaunchManager] setEnabled(\(enabled)) called, current status: \(SMAppService.mainApp.status.rawValue)")
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        let newStatus = SMAppService.mainApp.status
        DebugLog.log("[LaunchManager] After set: status=\(newStatus.rawValue) (enabled=\(newStatus == .enabled))")
        AppSettings.launchAtLogin = enabled
        DebugLog.log("[LaunchManager] Launch at login: \(enabled)")
    }
}
