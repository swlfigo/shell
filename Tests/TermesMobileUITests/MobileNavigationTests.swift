import XCTest

@MainActor
final class MobileNavigationTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    app = XCUIApplication()
    app.launchEnvironment["TERMES_UI_TESTING"] = "1"
    app.launchEnvironment["TERMES_UI_TEST_RESET"] = "1"
    app.launch()
    let portrait = expectation(for: NSPredicate { [weak app] _, _ in
      guard let app else { return false }
      return app.frame.height > app.frame.width
    }, evaluatedWith: nil)
    await fulfillment(of: [portrait], timeout: 5)
  }

  func testCreateSearchEditAndPersistHost() {
    addHost(name: "Development")
    XCTAssertTrue(app.cells["host.Development"].waitForExistence(timeout: 5))
    let search = app.searchFields.firstMatch
    search.tap(); search.typeText("missing-host")
    XCTAssertFalse(app.cells["host.Development"].exists)
    search.buttons.firstMatch.tap()
    search.tap()
    search.typeText("127.0.0.1")
    XCTAssertTrue(app.cells["host.Development"].exists)
    app.terminate()
    app.launchEnvironment["TERMES_UI_TEST_RESET"] = "0"
    app.launch()
    let host = app.cells["host.Development"]
    XCTAssertTrue(host.waitForExistence(timeout: 5))
    host.press(forDuration: 1)
    app.buttons["编辑主机"].tap()
    let name = app.textFields["hostEditor.name"]
    XCTAssertTrue(name.waitForExistence(timeout: 3))
    name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Development".count) + "Production")
    app.buttons["hostEditor.save"].tap()
    XCTAssertTrue(app.cells["host.Production"].waitForExistence(timeout: 5))
    attachScreenshot("主机列表")
  }

  func testConnectionFailureCanReturnToHostsAndReopenSession() {
    addHost(name: "Offline")
    app.cells["host.Offline"].tap()
    XCTAssertTrue(app.buttons["terminal.reconnect"].waitForExistence(timeout: 12))
    app.buttons["terminal.progress"].tap()
    XCTAssertTrue(app.navigationBars["连接详情"].waitForExistence(timeout: 3))
    attachScreenshot("连接详情")
    app.buttons["完成"].tap()
    if app.navigationBars.buttons["Vaults"].exists { app.navigationBars.buttons["Vaults"].tap() }
    XCTAssertTrue(app.cells["host.Offline"].waitForExistence(timeout: 3))
    app.cells["host.Offline"].tap()
    XCTAssertTrue(app.buttons["terminal.reconnect"].waitForExistence(timeout: 12))
    app.buttons["terminal.menu"].tap()
    app.buttons["关闭会话"].tap()
    XCTAssertTrue(app.cells["host.Offline"].waitForExistence(timeout: 5))
  }

  func testFormValidationAndSettings() {
    app.buttons["hosts.add"].tap()
    XCTAssertFalse(app.buttons["hostEditor.save"].isEnabled)
    fillAddress(name: "Missing credential")
    app.buttons["hostEditor.save"].tap()
    XCTAssertTrue(app.staticTexts["请输入登录密码。"].waitForExistence(timeout: 3))
    attachScreenshot("主机表单")
    app.buttons["hostEditor.cancel"].tap()
    app.buttons["settings.open"].tap()
    XCTAssertTrue(app.steppers["settings.fontSize"].waitForExistence(timeout: 3))
    app.steppers["settings.fontSize"].buttons.element(boundBy: 1).tap()
    attachScreenshot("外观设置")
    app.buttons["完成"].tap()
    XCTAssertTrue(app.buttons["hosts.add"].exists)
  }

  func testSSHTrustKeyboardRotationAndSessionReuse() throws {
    guard let value = ProcessInfo.processInfo.environment["TERMES_SSH_TEST_PORT"], let port = Int(value), port > 0 else {
      throw XCTSkip("Set TERMES_SSH_TEST_PORT to run against the optional local SSH fixture.")
    }
    addHost(name: "Loopback", port: String(port))
    app.cells["host.Loopback"].tap()
    XCTAssertTrue(app.buttons["hostTrust.accept"].waitForExistence(timeout: 10))
    attachScreenshot("主机指纹确认")
    app.buttons["hostTrust.accept"].tap()
    let keyboard = app.buttons["terminal.keyboard"]
    let ready = NSPredicate(format: "enabled == true")
    expectation(for: ready, evaluatedWith: keyboard)
    waitForExpectations(timeout: 10)
    keyboard.tap()
    app.typeText("echo mobile-ssh-ok\n")
    attachScreenshot("SSH 终端与键盘")
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = expectation(for: NSPredicate { [weak app] _, _ in
      guard let app else { return false }
      return app.frame.width > app.frame.height
    }, evaluatedWith: nil)
    wait(for: [landscape], timeout: 5)
    XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
    attachScreenshot("横屏终端")
    XCUIDevice.shared.orientation = .portrait
    let portrait = expectation(for: NSPredicate { [weak app] _, _ in
      guard let app else { return false }
      return app.frame.height > app.frame.width
    }, evaluatedWith: nil)
    wait(for: [portrait], timeout: 5)
    if app.navigationBars.buttons["Vaults"].exists { app.navigationBars.buttons["Vaults"].tap() }
    if app.cells["host.Loopback"].isHittable { app.cells["host.Loopback"].tap() }
    XCTAssertTrue(keyboard.isEnabled)
    XCTAssertFalse(app.buttons["hostTrust.accept"].exists)

    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.navigationBars["Loopback"].waitForExistence(timeout: 5))
    XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
    XCTAssertTrue(keyboard.isEnabled)
    XCTAssertFalse(app.buttons["hostTrust.accept"].exists)
    keyboard.tap()
    app.typeText("echo mobile-foreground-ok\n")
    attachScreenshot("回到前台继续终端输入")

    app.buttons["terminal.menu"].tap()
    app.buttons["关闭会话"].tap()
    XCTAssertTrue(app.alerts["关闭会话？"].waitForExistence(timeout: 3))
    app.alerts.buttons["取消"].tap()
    XCTAssertTrue(keyboard.isEnabled)
  }

  func testSSHNewOutputNoticeReturnsToLatestWithoutShowingKeyboard() throws {
    guard let value = ProcessInfo.processInfo.environment["TERMES_SSH_TEST_PORT"], let port = Int(value), port > 0 else {
      throw XCTSkip("Set TERMES_SSH_TEST_PORT to run against the optional local SSH fixture.")
    }
    addHost(name: "Output notice", port: String(port))
    app.cells["host.Output notice"].tap()
    XCTAssertTrue(app.buttons["hostTrust.accept"].waitForExistence(timeout: 10))
    app.buttons["hostTrust.accept"].tap()
    let keyboard = app.buttons["terminal.keyboard"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: keyboard)
    waitForExpectations(timeout: 10)
    keyboard.tap()
    app.typeText("mobile-notice-stream\n")

    // The fixture sends 200 history lines before its timed stream. Going through
    // connection details lets that burst render and dismisses the input keyboard.
    app.buttons["terminal.progress"].tap()
    XCTAssertTrue(app.navigationBars["连接详情"].waitForExistence(timeout: 3))
    app.buttons["完成"].tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
    waitForExpectations(timeout: 3)

    let terminal = app.descendants(matching: .any)["terminal.surface"].firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout: 3))
    let notice = app.buttons["terminal.newOutput"]
    XCTAssertFalse(notice.exists)
    terminal.swipeDown()
    XCTAssertTrue(notice.waitForExistence(timeout: 8))
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    attachScreenshot("回看历史时的新输出提醒")

    notice.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notice)
    waitForExpectations(timeout: 3)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(keyboard.isEnabled)
    XCTAssertTrue(app.staticTexts["已连接"].exists)
    attachScreenshot("回到终端最新输出")
  }

  func testSSHServerMonitoringPauseResumeAndReturnToTerminal() throws {
    guard let value = ProcessInfo.processInfo.environment["TERMES_SSH_TEST_PORT"], let port = Int(value), port > 0 else {
      throw XCTSkip("Set TERMES_SSH_TEST_PORT to run against the optional local SSH fixture.")
    }
    defer { XCUIDevice.shared.orientation = .portrait }
    addHost(name: "Monitored Linux", port: String(port))
    app.cells["host.Monitored Linux"].tap()
    XCTAssertTrue(app.buttons["hostTrust.accept"].waitForExistence(timeout: 10))
    app.buttons["hostTrust.accept"].tap()
    let keyboard = app.buttons["terminal.keyboard"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: keyboard)
    waitForExpectations(timeout: 10)

    app.buttons["terminal.monitor"].tap()
    XCTAssertTrue(app.navigationBars["服务器监控"].waitForExistence(timeout: 5))
    let screen = app.descendants(matching: .any)["monitor.screen"].firstMatch
    XCTAssertTrue(screen.exists)
    let memory = app.staticTexts["monitor.memory"]
    let disk = app.staticTexts["monitor.disk"]
    waitForMetric(memory, containing: "%")
    waitForMetric(disk, containing: "%")
    // CPU and transfer rates require two samples; the fixture advances its
    // cumulative /proc counters for each exec without touching the shell channel.
    let cpu = app.staticTexts["monitor.cpu"]
    let network = app.staticTexts["monitor.network"]
    waitForMetric(cpu, containing: "%")
    waitForMetric(network, containing: "/s")
    attachScreenshot("Linux 服务器监控")

    let pause = app.buttons["monitor.pause"]
    XCTAssertTrue(pause.isEnabled)
    pause.tap()
    let status = app.staticTexts["monitor.status"]
    waitForMetric(status, containing: "暂停", timeout: 3)
    XCTAssertTrue(cpu.exists)
    pause.tap()
    waitForMetric(status, containing: "实时")
    waitForMetric(cpu, containing: "%")
    waitForMetric(network, containing: "/s")

    let monitorScroll = screen.scrollViews.firstMatch
    XCTAssertTrue(monitorScroll.exists)
    let range = screen.segmentedControls["monitor.range"]
    revealMonitorElement(range, in: monitorScroll)
    range.buttons["1 分钟"].tap()
    XCTAssertTrue(range.buttons["1 分钟"].isSelected)
    range.buttons["15 分钟"].tap()
    XCTAssertTrue(range.buttons["15 分钟"].isSelected)
    let usageChart = screen.descendants(matching: .any)["monitor.usageChart"].firstMatch
    revealMonitorElement(usageChart, in: monitorScroll)
    attachScreenshot("服务器资源使用趋势 · 15 分钟")

    let interface = screen.buttons["monitor.interface"]
    revealMonitorElement(interface, in: monitorScroll)
    let networkChart = screen.descendants(matching: .any)["monitor.networkChart"].firstMatch
    revealMonitorElement(networkChart, in: monitorScroll)
    attachScreenshot("服务器网络流量趋势")

    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = expectation(for: NSPredicate { [weak app] _, _ in
      guard let app else { return false }
      return app.frame.width > app.frame.height
    }, evaluatedWith: nil)
    wait(for: [landscape], timeout: 5)
    XCTAssertTrue(app.buttons["monitor.close"].isHittable)
    attachScreenshot("横屏服务器监控")

    app.buttons["monitor.close"].tap()
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    XCTAssertTrue(keyboard.isEnabled)
    XCTAssertTrue(app.staticTexts["已连接"].exists)
    XCTAssertFalse(app.buttons["hostTrust.accept"].exists)
    keyboard.tap()
    app.typeText("echo mobile-after-monitor-ok\n")
    // A retained, connected terminal can still exchange interactive data after
    // the dedicated monitoring transport has closed. Keep the visible response
    // as evidence that collection output did not enter the terminal viewport.
    attachScreenshot("关闭监控后终端继续交互")

    app.buttons["terminal.menu"].tap()
    app.collectionViews.buttons["服务器监控"].tap()
    XCTAssertTrue(app.navigationBars["服务器监控"].waitForExistence(timeout: 5))
    waitForMetric(memory, containing: "%")
    let retry = app.buttons["monitor.retry"]
    XCTAssertTrue(retry.isEnabled)
    retry.tap()
    waitForMetric(status, containing: "实时")
    app.buttons["monitor.close"].tap()
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    XCTAssertTrue(keyboard.isEnabled)
  }

  func testLibrarySavesSnippetsAndOfflineForwardRules() {
    addHost(name: "Library host")
    createSnippet()
    app.buttons["library.open"].tap()
    app.cells["library.0.1"].tap()
    app.cells["forwardHost.Library host"].tap()
    XCTAssertTrue(app.buttons["forwards.add"].waitForExistence(timeout: 3))
    app.buttons["forwards.add"].tap()
    let port = app.textFields["forwardEditor.localPort"]
    port.tap(); port.typeText("18080")
    let target = app.textFields["forwardEditor.targetPort"]
    target.tap(); target.typeText("8080")
    app.buttons["forwardEditor.save"].tap()
    let forward = app.cells["forward.18080"]
    XCTAssertTrue(forward.waitForExistence(timeout: 3))
    forward.tap()
    XCTAssertFalse(app.buttons["启动"].isEnabled)
    if app.buttons["取消"].exists { app.buttons["取消"].tap() }
    else { app.navigationBars.staticTexts.firstMatch.tap() }
    attachScreenshot("未连接时保存端口转发规则")
    app.terminate(); app.launchEnvironment["TERMES_UI_TEST_RESET"] = "0"; app.launch()
    app.buttons["library.open"].tap(); app.cells["library.0.2"].tap()
    XCTAssertTrue(app.cells["snippet.Greeting"].waitForExistence(timeout: 3))
    attachScreenshot("移动端常用命令资料库")
    app.buttons["完成"].tap()
    app.buttons["library.open"].tap(); app.cells["library.0.1"].tap(); app.cells["forwardHost.Library host"].tap()
    XCTAssertTrue(app.cells["forward.18080"].waitForExistence(timeout: 3))
    app.cells["forwards.connection"].tap()
    XCTAssertTrue(app.buttons["terminal.reconnect"].waitForExistence(timeout: 12))
  }

  func testSplitLayoutAndSessionRestoration() {
    addHost(name: "Split host")
    app.cells["host.Split host"].tap()
    XCTAssertTrue(app.buttons["terminal.reconnect"].waitForExistence(timeout: 12))
    app.buttons["terminal.menu"].tap(); app.buttons["复制到新标签"].tap()
    XCTAssertTrue(app.buttons["terminal.reconnect"].waitForExistence(timeout: 12))
    app.buttons["terminal.menu"].tap(); app.buttons["合并到右侧分屏"].tap()
    app.collectionViews.buttons["Split host"].firstMatch.tap()
    let paneTabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'paneTab.'"))
    XCTAssertEqual(paneTabs.count, 2)
    paneTabs.element(boundBy: 0).tap()
    attachScreenshot("移动端分屏工作区")
    app.terminate(); app.launchEnvironment["TERMES_UI_TEST_RESET"] = "0"; app.launch()
    XCTAssertTrue(app.buttons["terminal.reconnect"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(paneTabs.count, 2)
    XCTAssertFalse(app.buttons["hostTrust.accept"].exists)
    attachScreenshot("重启后恢复布局并等待手动连接")
  }

  func testSSHSFTPTextEditingPermissionsDownloadAndSnippetInsertion() throws {
    guard let value = ProcessInfo.processInfo.environment["TERMES_SSH_TEST_PORT"], let port = Int(value), port > 0 else {
      throw XCTSkip("Set TERMES_SSH_TEST_PORT to run against the optional local SSH fixture.")
    }
    addHost(name: "File server", port: String(port)); createSnippet()
    app.cells["host.File server"].tap()
    XCTAssertTrue(app.buttons["hostTrust.accept"].waitForExistence(timeout: 10)); app.buttons["hostTrust.accept"].tap()
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["terminal.keyboard"])
    waitForExpectations(timeout: 10)
    app.buttons["terminal.menu"].tap(); app.buttons["文件"].tap()
    let file = app.cells["remoteFile.README.txt"]
    XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap(); app.buttons["编辑文本"].tap()
    let editor = app.textViews["remoteEditor.text"]
    waitForMetric(editor, containing: "Termes SFTP fixture")
    editor.tap(); editor.typeText("\nmobile-sftp-edited")
    app.buttons["remoteEditor.save"].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已保存到远端'")).firstMatch.waitForExistence(timeout: 10))
    attachScreenshot("移动端远端文本编辑")
    app.buttons["关闭"].tap()
    file.tap(); app.buttons["权限"].tap()
    let octal = app.textFields["permissions.octal"]
    XCTAssertTrue(octal.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["permissions.apply"])
    waitForExpectations(timeout: 10)
    octal.tap(); octal.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "0600")
    app.buttons["permissions.apply"].tap()
    XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap(); app.buttons["下载到本机"].tap()
    let transfer = app.cells["transfer.README.txt"]
    let completed = transfer.staticTexts.matching(NSPredicate(format: "label CONTAINS '已完成'")).firstMatch
    XCTAssertTrue(completed.waitForExistence(timeout: 15))
    attachScreenshot("移动端 SFTP 下载队列")
    app.buttons["完成"].tap()
    app.buttons["terminal.menu"].tap(); app.buttons["插入常用命令"].tap()
    app.cells["snippet.Greeting"].tap()
    let parameter = app.textFields["snippetParameter.name"]
    parameter.tap(); parameter.typeText("mobile-ssh-ok")
    waitForMetric(app.textViews["snippet.preview"], containing: "echo mobile-ssh-ok")
    app.buttons["snippet.insert"].tap()
    XCTAssertTrue(app.buttons["terminal.keyboard"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    app.typeText("\n")
    attachScreenshot("参数化命令插入保留终端连接")
  }

  private func createSnippet() {
    app.buttons["library.open"].tap(); app.cells["library.0.2"].tap(); app.buttons["snippets.add"].tap()
    let name = app.textFields["snippetEditor.name"]
    name.tap(); name.typeText("Greeting")
    let group = app.textFields["snippetEditor.group"]
    group.tap(); group.typeText("Operations")
    let command = app.textViews["snippetEditor.command"]
    command.tap(); command.typeText("echo {{name}}")
    let parameters = app.switches["snippetEditor.parameters"]
    if !parameters.isHittable { app.scrollViews.firstMatch.swipeUp() }
    parameters.tap(); app.buttons["snippetEditor.save"].tap()
    XCTAssertTrue(app.cells["snippet.Greeting"].waitForExistence(timeout: 3))
    app.buttons["完成"].tap()
  }

  private func revealMonitorElement(_ element: XCUIElement, in scrollView: XCUIElement) {
    for _ in 0..<6 {
      if element.isHittable,
         scrollView.frame.intersection(element.frame).height >= min(element.frame.height, scrollView.frame.height) - 2 { return }
      let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    XCTAssertTrue(element.isHittable, "监控内容应能在有限次数滚动后访问：\(element.identifier)")
  }

  private func waitForMetric(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 15) {
    let content = NSPredicate { _, _ in
      guard element.exists else { return false }
      return (element.label + " " + (element.value as? String ?? "")).contains(text)
    }
    expectation(for: content, evaluatedWith: nil)
    waitForExpectations(timeout: timeout)
  }

  private func addHost(name: String, port: String = "1") {
    XCTAssertTrue(app.buttons["hosts.add"].waitForExistence(timeout: 5))
    app.buttons["hosts.add"].tap()
    fillAddress(name: name, port: port)
    let password = app.secureTextFields["hostEditor.password"]
    password.tap(); password.typeText("test-password")
    app.buttons["hostEditor.save"].tap()
    let later = app.buttons["以后"]
    if later.waitForExistence(timeout: 2) { later.tap() }
    else if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
    XCTAssertTrue(app.cells["host.\(name)"].waitForExistence(timeout: 5), app.debugDescription)
  }

  private func fillAddress(name: String, port value: String = "1") {
    let nameField = app.textFields["hostEditor.name"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 3))
    nameField.tap(); nameField.typeText(name)
    let host = app.textFields["hostEditor.hostname"]
    host.tap(); host.typeText("127.0.0.1")
    let port = app.textFields["hostEditor.port"]
    port.tap(); port.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + value)
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways
    add(attachment)
  }
}
