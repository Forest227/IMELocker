import Foundation
import ServiceManagement
import os.log

enum LaunchAtLoginStatus: Equatable {
  case enabled
  case disabled
  case requiresApproval
  case notFound
  case unsupported

  var isEffectivelyEnabled: Bool {
    switch self {
    case .enabled, .requiresApproval:
      return true
    case .disabled, .notFound, .unsupported:
      return false
    }
  }

  var description: String {
    switch self {
    case .enabled:
      return "已开启"
    case .disabled:
      return "未开启"
    case .requiresApproval:
      return "需在系统设置批准"
    case .notFound:
      return "未找到（请将 App 放到“应用程序”后重试）"
    case .unsupported:
      return "系统不支持（macOS 13+）"
    }
  }
}

final class LaunchAtLoginService {
  private let log = Logger(subsystem: AppConstants.loggerSubsystem, category: "LaunchAtLoginService")

  var status: LaunchAtLoginStatus {
    guard #available(macOS 13.0, *) else { return .unsupported }
    return mapStatus(SMAppService.mainApp.status)
  }

  var isEnabled: Bool {
    status.isEffectivelyEnabled
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try enable()
    } else {
      try disable()
    }
  }

  func enable() throws {
    guard #available(macOS 13.0, *) else { return }
    try perform("register()") {
      try SMAppService.mainApp.register()
    }
  }

  func disable() throws {
    guard #available(macOS 13.0, *) else { return }
    try perform("unregister()") {
      try SMAppService.mainApp.unregister()
    }
  }

  func openSystemLoginItemsSettings() {
    guard #available(macOS 13.0, *) else { return }
    SMAppService.openSystemSettingsLoginItems()
  }

  @available(macOS 13.0, *)
  private func mapStatus(_ serviceStatus: SMAppService.Status) -> LaunchAtLoginStatus {
    switch serviceStatus {
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notRegistered:
      return .disabled
    case .notFound:
      return .notFound
    @unknown default:
      return .disabled
    }
  }

  @available(macOS 13.0, *)
  private func perform(_ actionName: String, operation: () throws -> Void) throws {
    do {
      try operation()
    } catch {
      log.error("\(actionName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      throw error
    }
  }
}
