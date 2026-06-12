import Cocoa
import Carbon
import os.log

struct InputSource: Hashable {
  let id: String
  let name: String
}

final class InputSourceLockService {
  private enum Timing {
    static let enforceDelay: TimeInterval = 0.05
    static let periodicCheckInterval: TimeInterval = 5.0
  }

  private let log = Logger(subsystem: AppConstants.loggerSubsystem, category: "InputSourceLockService")
  private let defaults = UserDefaults.standard
  private let distributedNotificationCenter = DistributedNotificationCenter.default()
  private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
  private var enforceWorkItem: DispatchWorkItem?
  private var periodicCheckTimer: Timer?
  private var hasStarted = false

  private let handlerQueue = DispatchQueue(label: "com.inputsourcelock.handlers")
  private var stateChangeHandlers: [UUID: () -> Void] = [:]

  // 输入法列表缓存，在 kTISNotifyEnabledKeyboardInputSourcesChanged 时失效
  private var cachedSelectableSources: [InputSource]?

  private enum DefaultsKey {
    static let enabled = "enabled"
    static let targetID = "targetInputSourceID"
  }

  deinit {
    periodicCheckTimer?.invalidate()
    distributedNotificationCenter.removeObserver(self)
    workspaceNotificationCenter.removeObserver(self)
  }

  @discardableResult
  func addStateChangeHandler(_ handler: @escaping () -> Void) -> UUID {
    let id = UUID()
    handlerQueue.sync { stateChangeHandlers[id] = handler }
    return id
  }

  func removeStateChangeHandler(_ id: UUID) {
    handlerQueue.sync { stateChangeHandlers[id] = nil }
  }

  var isEnabled: Bool {
    get { defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: DefaultsKey.enabled)
      if newValue {
        startPeriodicCheck()
      } else {
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = nil
      }
      notifyStateChanged()
    }
  }

  var targetInputSourceID: String? {
    get { defaults.string(forKey: DefaultsKey.targetID) }
    set {
      if let newValue {
        defaults.set(newValue, forKey: DefaultsKey.targetID)
      } else {
        defaults.removeObject(forKey: DefaultsKey.targetID)
      }
      notifyStateChanged()
    }
  }

  var isSecureInputEnabled: Bool {
    IsSecureEventInputEnabled()
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true

    autoPickWeChatIfNeeded()
    observeSystemNotifications()
    startPeriodicCheck()
    enforce(reason: "start")
  }

  private func observeSystemNotifications() {
    distributedNotificationCenter.addObserver(
      self,
      selector: #selector(inputSourceChanged(_:)),
      name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil
    )
    distributedNotificationCenter.addObserver(
      self,
      selector: #selector(inputSourcesEnabledChanged(_:)),
      name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
      object: nil
    )

    workspaceNotificationCenter.addObserver(
      self,
      selector: #selector(activeAppChanged(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
  }

  private func startPeriodicCheck() {
    guard isEnabled else { return }
    periodicCheckTimer?.invalidate()

    let timer = Timer(
      timeInterval: Timing.periodicCheckInterval,
      repeats: true
    ) { [weak self] _ in
      self?.handlePeriodicCheck()
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    periodicCheckTimer = timer
  }

  func selectableInputSources() -> [InputSource] {
    if let cached = cachedSelectableSources {
      return cached
    }
    let sources = fetchSelectableInputSources()
    cachedSelectableSources = sources
    return sources
  }

  func currentInputSource() -> InputSource? {
    guard let unmanaged = TISCopyCurrentKeyboardInputSource() else { return nil }
    let source = unmanaged.takeRetainedValue()
    guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
    guard let name = stringProperty(source, kTISPropertyLocalizedName) else { return nil }
    return InputSource(id: id, name: name)
  }

  func targetInputSource() -> InputSource? {
    guard let id = targetInputSourceID else { return nil }
    // 优先从缓存中查找，避免重复调用 TISCreateInputSourceList
    if let cached = cachedSelectableSources {
      return cached.first(where: { $0.id == id })
    }
    return inputSourceRef(byID: id).flatMap { ref in
      guard let name = stringProperty(ref, kTISPropertyLocalizedName) else { return nil }
      return InputSource(id: id, name: name)
    }
  }

  func enforce(reason: String) {
    scheduleEnforce(reason: reason)
  }

  func enforceSync(reason: String) {
    enforceNow(reason: reason)
  }

  private func scheduleEnforce(reason: String) {
    enforceWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.enforceNow(reason: reason)
    }
    enforceWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Timing.enforceDelay, execute: item)
  }

  private func enforceNow(reason: String) {
    guard isEnabled else { return }
    guard !isSecureInputEnabled else { return }
    guard let targetID = targetInputSourceID else { return }

    let current = currentInputSource()
    if current?.id == targetID { return }

    guard let targetRef = inputSourceRef(byID: targetID) else {
      log.error("Target input source not found: \(targetID, privacy: .public)")
      return
    }

    let status = TISSelectInputSource(targetRef)
    if status != noErr {
      log.error("TISSelectInputSource failed: \(status, privacy: .public) reason=\(reason, privacy: .public)")
    } else {
      log.debug("Switched input source: \(targetID, privacy: .public) reason=\(reason, privacy: .public)")
    }
  }

  private func autoPickWeChatIfNeeded() {
    guard targetInputSourceID == nil else { return }

    let candidates = selectableInputSources()
    if let wechat = candidates.first(where: matchesWeChatByName) {
      targetInputSourceID = wechat.id
      log.debug("Auto-picked target input source: \(wechat.id, privacy: .public)")
      return
    }

    if let wechat = candidates.first(where: matchesWeChatByID) {
      targetInputSourceID = wechat.id
      log.debug("Auto-picked target input source by id: \(wechat.id, privacy: .public)")
    }
  }

  @objc private func inputSourceChanged(_ notification: Notification) {
    enforce(reason: "inputSourceChanged")
    notifyStateChanged()
  }

  @objc private func inputSourcesEnabledChanged(_ notification: Notification) {
    cachedSelectableSources = nil
    autoPickWeChatIfNeeded()
    notifyStateChanged()
  }

  @objc private func activeAppChanged(_ notification: Notification) {
    enforce(reason: "activeAppChanged")
    notifyStateChanged()
  }

  private func handlePeriodicCheck() {
    guard isEnabled else { return }
    guard targetInputSourceID != nil else { return }

    enforce(reason: "periodicCheck")
  }

  private func inputSourceRef(byID id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
      return nil
    }
    return list.first
  }

  private func matchesWeChatByName(_ source: InputSource) -> Bool {
    let normalizedName = source.name.lowercased()
    return source.name.contains("微信") || normalizedName.contains("wechat")
  }

  private func matchesWeChatByID(_ source: InputSource) -> Bool {
    let normalizedID = source.id.lowercased()
    return normalizedID.contains("tencent") || normalizedID.contains("wechat")
  }

  private func fetchSelectableInputSources() -> [InputSource] {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
      return []
    }

    var sources: [InputSource] = []
    sources.reserveCapacity(list.count)
    for source in list {
      guard boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else { continue }
      guard boolProperty(source, kTISPropertyInputSourceIsEnabled) else { continue }
      guard let id = stringProperty(source, kTISPropertyInputSourceID) else { continue }
      guard let name = stringProperty(source, kTISPropertyLocalizedName) else { continue }

      sources.append(InputSource(id: id, name: name))
    }

    // 稳定排序：先按名称，再按 id
    sources.sort { lhs, rhs in
      if lhs.name == rhs.name { return lhs.id < rhs.id }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    return sources
  }

  private func anyProperty(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
  }

  private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    anyProperty(source, key) as? String
  }

  private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let value = anyProperty(source, key) else { return false }
    if CFGetTypeID(value) == CFBooleanGetTypeID(), let bool = value as? Bool {
      return bool
    }
    if let number = value as? NSNumber { return number.boolValue }
    return false
  }

  private func notifyStateChanged() {
    let handlers: [() -> Void] = handlerQueue.sync {
      Array(stateChangeHandlers.values)
    }
    guard !handlers.isEmpty else { return }

    if Thread.isMainThread {
      handlers.forEach { $0() }
    } else {
      DispatchQueue.main.async {
        handlers.forEach { $0() }
      }
    }
  }
}
