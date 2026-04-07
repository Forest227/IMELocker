import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let lockService = InputSourceLockService()
  private let launchAtLoginService = LaunchAtLoginService()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let menuBuilder = StatusMenuBuilder()
  private lazy var menuActions = StatusMenuActionHandlers(
    target: self,
    toggleEnabled: #selector(toggleEnabled(_:)),
    selectTarget: #selector(selectTarget(_:)),
    toggleLaunchAtLogin: #selector(toggleLaunchAtLogin(_:)),
    openLoginItemsSettings: #selector(openLoginItemsSettings),
    restart: #selector(restart),
    quit: #selector(quit)
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    menu.delegate = self
    statusItem.menu = menu

    lockService.addStateChangeHandler { [weak self] in
      self?.handleLockStateChanged()
    }

    lockService.start()
    updateStatusButton(using: currentState())
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuBuilder.rebuild(menu: menu, using: currentState(), actions: menuActions)
  }

  private func currentState() -> AppViewState {
    AppViewState(lockService: lockService, launchAtLoginService: launchAtLoginService)
  }

  private func handleLockStateChanged() {
    let state = currentState()
    updateStatusButton(using: state)
  }

  private func updateStatusButton(using state: AppViewState) {
    guard let button = statusItem.button else { return }
    button.image = makeStatusImage(enabled: state.isLockEnabled)
    button.imagePosition = .imageOnly
  }

  private func makeStatusImage(enabled: Bool) -> NSImage? {
    let symbolName = enabled ? "keyboard.badge.checkmark" : "keyboard"
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    if let symbol = (
      NSImage(systemSymbolName: symbolName, accessibilityDescription: AppConstants.statusImageAccessibilityDescription)
        ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: AppConstants.statusImageAccessibilityDescription)
    )?
      .withSymbolConfiguration(config)
    {
      symbol.isTemplate = true
      return symbol
    }

    // 极端兜底：如果系统符号不可用，用应用图标（非模板）。
    return NSImage(named: NSImage.applicationIconName)
  }

  @objc private func toggleEnabled(_ sender: NSMenuItem) {
    lockService.isEnabled.toggle()
    lockService.enforce(reason: "toggle")
  }

  @objc private func selectTarget(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    lockService.targetInputSourceID = id
    lockService.isEnabled = true
    lockService.enforce(reason: "selectTarget")
  }

  @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
    do {
      try launchAtLoginService.setEnabled(!launchAtLoginService.isEnabled)
    } catch {
      AlertPresenter.show(title: "无法设置登录启动", message: String(describing: error))
    }
  }

  @objc private func openLoginItemsSettings() {
    launchAtLoginService.openSystemLoginItemsSettings()
  }

  @objc private func restart() {
    guard let bundleURL = relaunchBundleURL() else {
      AlertPresenter.show(title: "无法重启应用", message: "没有找到可用于重启的应用包，请先重新运行“输入法锁定”。")
      return
    }

    do {
      try launchNewInstance(at: bundleURL)
      NSApplication.shared.terminate(nil)
    } catch {
      AlertPresenter.show(title: "无法重启应用", message: "启动新实例失败：\(error.localizedDescription)")
    }
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func relaunchBundleURL() -> URL? {
    let fileManager = FileManager.default
    let currentBundleURL = Bundle.main.bundleURL
    let parentDirectoryURL = currentBundleURL.deletingLastPathComponent()

    let candidateURLs = [
      currentBundleURL,
      parentDirectoryURL.appendingPathComponent("\(AppConstants.displayName).app"),
      parentDirectoryURL.appendingPathComponent("\(AppConstants.legacyDisplayName).app"),
    ]

    return candidateURLs.first(where: { fileManager.fileExists(atPath: $0.path) })
  }

  private func launchNewInstance(at bundleURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", bundleURL.path]
    try process.run()
  }
}

enum AppConstants {
  static let displayName = "输入法锁定"
  static let legacyDisplayName = "微信输入法锁定"
  static let loggerSubsystem = "InputSourceLock"
  static let statusImageAccessibilityDescription = "Input Source Lock"
  static let unknownInputSourceName = "未知"
  static let noSelectableInputSourcesText = "（未发现可选输入法）"
}

enum AlertPresenter {
  static func show(title: String, message: String) {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
  }
}

struct AppViewState {
  let currentInputSourceName: String
  let isSecureInputEnabled: Bool
  let isLockEnabled: Bool
  let selectableInputSources: [InputSource]
  let targetInputSourceID: String?
  let targetInputSourceName: String?
  let launchAtLoginStatus: LaunchAtLoginStatus

  init(lockService: InputSourceLockService, launchAtLoginService: LaunchAtLoginService) {
    let availableInputSources = lockService.selectableInputSources()
    let selectedTargetInputSourceID = lockService.targetInputSourceID

    currentInputSourceName = lockService.currentInputSource()?.name ?? AppConstants.unknownInputSourceName
    isSecureInputEnabled = lockService.isSecureInputEnabled
    isLockEnabled = lockService.isEnabled
    selectableInputSources = availableInputSources
    targetInputSourceID = selectedTargetInputSourceID
    targetInputSourceName = availableInputSources
      .first(where: { $0.id == selectedTargetInputSourceID })?
      .name
    launchAtLoginStatus = launchAtLoginService.status
  }

  var currentInputSourceText: String {
    "当前输入法：\(currentInputSourceName)"
  }

  var secureInputText: String {
    if isSecureInputEnabled {
      return "Secure Input：已开启（暂停强制切换）"
    }
    return "Secure Input：未开启"
  }

  var targetInputSourceText: String {
    if let targetInputSourceName {
      return "目标输入法：\(targetInputSourceName)"
    }
    return "目标输入法：未选择"
  }

  var launchAtLoginStatusText: String {
    "登录启动：\(launchAtLoginStatus.description)"
  }

  var launchAtLoginControlState: NSControl.StateValue {
    switch launchAtLoginStatus {
    case .enabled:
      return .on
    case .requiresApproval:
      return .mixed
    case .disabled, .notFound, .unsupported:
      return .off
    }
  }

  var isLaunchAtLoginToggleEnabled: Bool {
    launchAtLoginStatus != .unsupported
  }

  var shouldShowOpenLoginItemsSettings: Bool {
    launchAtLoginStatus == .requiresApproval
  }
}

struct StatusMenuActionHandlers {
  let target: AnyObject
  let toggleEnabled: Selector
  let selectTarget: Selector
  let toggleLaunchAtLogin: Selector
  let openLoginItemsSettings: Selector
  let restart: Selector
  let quit: Selector
}

final class StatusMenuBuilder {
  func rebuild(menu: NSMenu, using state: AppViewState, actions: StatusMenuActionHandlers) {
    menu.removeAllItems()

    addDisabledItem(title: state.currentInputSourceText, to: menu)
    if state.isSecureInputEnabled {
      addDisabledItem(title: state.secureInputText, to: menu)
    }

    menu.addItem(.separator())

    let enabledItem = makeActionItem(
      title: "锁定启用",
      action: actions.toggleEnabled,
      target: actions.target
    )
    enabledItem.state = state.isLockEnabled ? .on : .off
    menu.addItem(enabledItem)

    menu.addItem(.separator())

    addDisabledItem(title: state.targetInputSourceText, to: menu)
    addInputSourceItems(
      state.selectableInputSources,
      selectedID: state.targetInputSourceID,
      to: menu,
      actions: actions
    )

    menu.addItem(.separator())

    let launchItem = makeActionItem(
      title: "登录时启动",
      action: actions.toggleLaunchAtLogin,
      target: actions.target
    )
    launchItem.state = state.launchAtLoginControlState
    launchItem.isEnabled = state.isLaunchAtLoginToggleEnabled
    menu.addItem(launchItem)

    addDisabledItem(title: state.launchAtLoginStatusText, to: menu)
    if state.shouldShowOpenLoginItemsSettings {
      menu.addItem(
        makeActionItem(
          title: "打开系统登录项设置…",
          action: actions.openLoginItemsSettings,
          target: actions.target
        )
      )
    }

    menu.addItem(.separator())
    menu.addItem(
      makeActionItem(
        title: "重启",
        action: actions.restart,
        target: actions.target
      )
    )
    menu.addItem(
      makeActionItem(
        title: "退出",
        action: actions.quit,
        keyEquivalent: "q",
        target: actions.target
      )
    )
  }

  private func addInputSourceItems(
    _ sources: [InputSource],
    selectedID: String?,
    to menu: NSMenu,
    actions: StatusMenuActionHandlers
  ) {
    guard !sources.isEmpty else {
      addDisabledItem(title: AppConstants.noSelectableInputSourcesText, to: menu)
      return
    }

    for source in sources {
      let item = makeActionItem(
        title: source.name,
        action: actions.selectTarget,
        target: actions.target
      )
      item.representedObject = source.id
      item.state = (source.id == selectedID) ? .on : .off
      menu.addItem(item)
    }
  }

  private func addDisabledItem(title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
  }

  private func makeActionItem(
    title: String,
    action: Selector,
    keyEquivalent: String = "",
    target: AnyObject
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = target
    return item
  }
}
