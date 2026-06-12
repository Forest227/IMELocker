import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let lockService = InputSourceLockService()
  private let launchAtLoginService = LaunchAtLoginService()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let menuBuilder = StatusMenuBuilder()
  private lazy var menuActions = StatusMenuActionHandlers(
    target: self,
    selectTarget: #selector(selectTarget(_:)),
    toggleLaunchAtLogin: #selector(toggleLaunchAtLogin(_:)),
    openLoginItemsSettings: #selector(openLoginItemsSettings),
    restart: #selector(restart),
    about: #selector(about),
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
    // 不设置 contentTintColor，由系统根据菜单栏外观自动着色（暗色=白，亮色=黑）
  }

  private func makeStatusImage(enabled: Bool) -> NSImage? {
    let desc = AppConstants.statusImageAccessibilityDescription
    let candidates = enabled ? SFSymbol.statusLockEnabled : SFSymbol.statusLockDisabled
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    if let symbol = SFSymbol.image(candidates, description: desc)?.withSymbolConfiguration(config) {
      symbol.isTemplate = true
      return symbol
    }

    // 极端兜底：如果所有 SF Symbol 均不可用，用应用图标（非模板）。
    return NSImage(named: NSImage.applicationIconName)
  }

  @objc private func selectTarget(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    if lockService.targetInputSourceID == id && lockService.isEnabled {
      // 已锁定到此项 → 解锁
      lockService.isEnabled = false
    } else {
      // 锁定到新目标
      lockService.targetInputSourceID = id
      lockService.isEnabled = true
      lockService.enforceSync(reason: "selectTarget")
    }
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

  @objc private func about() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    let latestVersion = fetchLatestVersion()
    let hasUpdate = latestVersion.map { $0 != version } ?? false

    let alert = NSAlert()
    alert.messageText = AppConstants.displayName

    // 版本信息 + 红点提示
    let versionLine = NSMutableAttributedString()
    versionLine.append(NSAttributedString(
      string: "版本 \(version) (\(build))",
      attributes: [.foregroundColor: NSColor.labelColor]
    ))
    if hasUpdate {
      versionLine.append(NSAttributedString(
        string: " ●",
        attributes: [.foregroundColor: NSColor.systemRed]
      ))
      versionLine.append(NSAttributedString(
        string: " 有新版本 \(latestVersion!)",
        attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .light)]
      ))
    }
    alert.informativeText = " "
    alert.accessoryView = makeAboutAccessoryView(versionLine: versionLine)

    // 按钮：有更新时高亮
    if hasUpdate {
      alert.addButton(withTitle: "查看更新 (\(latestVersion!))")
    } else {
      alert.addButton(withTitle: "查看更新")
    }
    alert.addButton(withTitle: "好")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      NSWorkspace.shared.open(URL(string: "https://github.com/Forest227/IMELocker/releases/latest")!)
    }
  }

  private func makeAboutAccessoryView(versionLine: NSAttributedString) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))

    let versionLabel = NSTextField(labelWithAttributedString: versionLine)
    versionLabel.frame = NSRect(x: 0, y: 30, width: 260, height: 20)

    let descLabel = NSTextField(labelWithString: "轻量 macOS 菜单栏工具，将输入法锁定到指定目标，防止应用偷偷切换。")
    descLabel.frame = NSRect(x: 0, y: 0, width: 260, height: 30)
    descLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    descLabel.textColor = .secondaryLabelColor
    descLabel.maximumNumberOfLines = 2
    descLabel.lineBreakMode = .byWordWrapping

    container.addSubview(versionLabel)
    container.addSubview(descLabel)
    return container
  }

  /// 从 GitHub API 获取最新 release 版本号，超时 3 秒
  private func fetchLatestVersion() -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: String?

    var request = URLRequest(url: URL(string: "https://api.github.com/repos/Forest227/IMELocker/releases/latest")!)
    request.timeoutInterval = 3
    request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

    URLSession.shared.dataTask(with: request) { data, _, _ in
      defer { semaphore.signal() }
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String
      else { return }
      result = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }.resume()

    _ = semaphore.wait(timeout: .now() + 3)
    return result
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

/// SF Symbol 降级加载器。
/// 每个符号维护一条回退链：首选（SF Symbols 3+）→ 简化版 → 基础版（SF Symbols 1）。
/// macOS 12+ 对应 SF Symbols 3，但早期 12.0 构建可能存在个别缺失，
/// 因此所有链的最后一项均为 SF Symbols 1 就有的符号。
enum SFSymbol {
  // MARK: - 锁定图标（状态栏 + 菜单共用）

  static let statusLockEnabled = ["lock.shield.fill", "lock.shield", "lock.fill", "lock"]
  static let statusLockDisabled = ["lock.shield", "lock.open", "lock"]

  // MARK: - 菜单操作

  static let restart = ["arrow.clockwise", "arrow.2.circlepath"]
  static let quit = ["xmark.circle", "xmark.square", "xmark"]
  static let info = ["info.circle", "info"]
  static let openExternal = ["arrow.up.right.square", "arrow.up.right", "arrow.right"]
  static let launchAtLogin = ["power", "bolt"]

  // MARK: - 安全状态

  static let secureInput = ["lock.shield", "lock.shield.fill", "lock"]
  static let secureInputBadge = ["lock.shield.fill", "lock.shield", "lock.fill", "lock"]

  // MARK: - 输入法列表

  static let inputSourceSelected = ["checkmark.circle.fill", "checkmark.circle", "checkmark"]
  static let inputSourceUnselected = ["circle", "minus"]

  // MARK: - 加载

  /// 按优先级尝试加载 SF Symbol，返回第一个成功匹配的 NSImage。
  /// 所有候选均失败时返回 nil（调用方自行兜底）。
  static func image(_ candidates: [String], description: String? = nil) -> NSImage? {
    for name in candidates {
      if let img = NSImage(systemSymbolName: name, accessibilityDescription: description) {
        return img
      }
    }
    return nil
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

  var lockStatusText: String {
    isLockEnabled ? "输入法已锁定" : "输入法已解锁"
  }

  var currentInputSourceText: String {
    "当前输入法：\(currentInputSourceName)"
  }

  var secureInputText: String {
    if isSecureInputEnabled {
      return "Secure Input 已开启"
    }
    return "Secure Input 未开启"
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
  let selectTarget: Selector
  let toggleLaunchAtLogin: Selector
  let openLoginItemsSettings: Selector
  let restart: Selector
  let about: Selector
  let quit: Selector
}

final class StatusMenuBuilder {
  func rebuild(menu: NSMenu, using state: AppViewState, actions: StatusMenuActionHandlers) {
    menu.removeAllItems()

    // ── 区域 1：锁定状态标题 ──
    let statusIcon = state.isLockEnabled
      ? SFSymbol.image(SFSymbol.statusLockEnabled, description: "已锁定")
      : SFSymbol.image(SFSymbol.statusLockDisabled, description: "未锁定")
    addBoldItem(title: state.lockStatusText, image: statusIcon, to: menu)

    // 当前输入法 + Secure Input
    let secureSuffix = state.isSecureInputEnabled ? "    ▸ Secure Input" : ""
    addDisabledItem(title: "当前：" + state.currentInputSourceName + secureSuffix, to: menu)

    menu.addItem(.separator())

    // ── 区域 2：目标输入法（点击锁定，再点解锁）──
    addDisabledItem(title: "选择目标输入法：", to: menu)
    addInputSourceItems(
      state.selectableInputSources,
      selectedID: state.targetInputSourceID,
      to: menu,
      actions: actions
    )

    menu.addItem(.separator())

    // ── 区域 3：快捷操作 ──
    let launchItem = makeActionItem(
      title: "开机自启",
      action: actions.toggleLaunchAtLogin,
      image: SFSymbol.image(SFSymbol.launchAtLogin, description: "开机自启"),
      target: actions.target
    )
    launchItem.state = state.launchAtLoginControlState
    launchItem.isEnabled = state.isLaunchAtLoginToggleEnabled
    menu.addItem(launchItem)

    if state.shouldShowOpenLoginItemsSettings {
      menu.addItem(
        makeActionItem(
          title: "打开系统登录项设置…",
          action: actions.openLoginItemsSettings,
          image: SFSymbol.image(SFSymbol.openExternal, description: "打开设置"),
          target: actions.target
        )
      )
    }

    menu.addItem(.separator())

    // ── 区域 4：应用操作 ──
    menu.addItem(
      makeActionItem(
        title: "重启应用",
        action: actions.restart,
        image: SFSymbol.image(SFSymbol.restart, description: "重启"),
        target: actions.target
      )
    )
    menu.addItem(
      makeActionItem(
        title: "关于「输入法锁定」",
        action: actions.about,
        image: SFSymbol.image(SFSymbol.info, description: "关于"),
        target: actions.target
      )
    )

    menu.addItem(.separator())

    menu.addItem(
      makeActionItem(
        title: "退出",
        action: actions.quit,
        keyEquivalent: "q",
        image: SFSymbol.image(SFSymbol.quit, description: "退出"),
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
      let isSelected = source.id == selectedID
      let icon = isSelected
        ? SFSymbol.image(SFSymbol.inputSourceSelected, description: "已选中")
        : SFSymbol.image(SFSymbol.inputSourceUnselected, description: "未选中")
      let item = makeActionItem(
        title: source.name,
        action: actions.selectTarget,
        image: icon,
        target: actions.target
      )
      item.representedObject = source.id
      item.state = isSelected ? .on : .off
      menu.addItem(item)
    }
  }

  /// 粗体不可点击项（用于菜单顶部状态标题）
  private func addBoldItem(title: String, image: NSImage? = nil, to menu: NSMenu) {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let attrTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    item.attributedTitle = attrTitle
    item.isEnabled = false
    if let image { item.image = image }
    menu.addItem(item)
  }

  /// 普通不可点击项（用于信息展示行）
  private func addDisabledItem(title: String, image: NSImage? = nil, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    if let image { item.image = image }
    menu.addItem(item)
  }

  /// 可点击操作项
  private func makeActionItem(
    title: String,
    action: Selector,
    keyEquivalent: String = "",
    image: NSImage? = nil,
    target: AnyObject
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = target
    if let image { item.image = image }
    return item
  }
}
