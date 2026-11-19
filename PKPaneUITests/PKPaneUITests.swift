import AppKit
import XCTest

@MainActor
final class PKPaneUITests: XCTestCase {
  private var testFolderURL: URL!

  override func setUpWithError() throws {
    testFolderURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PKPaneUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: testFolderURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: testFolderURL.appending(path: "Documents/caria", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: testFolderURL.appending(path: "caria-link", directoryHint: .notDirectory).path,
      withDestinationPath: "Documents/caria")
    try Data("表示形式テスト".utf8).write(to: testFolderURL.appending(path: "report.txt"))
    try Data("複数削除テスト".utf8).write(to: testFolderURL.appending(path: "delete-me.txt"))
    try Data(repeating: 0, count: 1).write(to: testFolderURL.appending(path: "a-size-small.txt"))
    try Data(repeating: 0, count: 4_096).write(
      to: testFolderURL.appending(path: "z-size-large.txt"))
    // 複数選択テスト用: 名前順で並びが決め打ちできる専用フォルダに3ファイルだけ置く。
    try FileManager.default.createDirectory(
      at: testFolderURL.appending(path: "MultiSelect", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("複数選択テストA".utf8).write(
      to: testFolderURL.appending(path: "MultiSelect/select-a.txt"))
    try Data("複数選択テストB".utf8).write(
      to: testFolderURL.appending(path: "MultiSelect/select-b.txt"))
    try Data("複数選択テストC".utf8).write(
      to: testFolderURL.appending(path: "MultiSelect/select-c.txt"))
    // ツリー展開テスト用: 子ファイル1件を持つ専用フォルダ。
    try FileManager.default.createDirectory(
      at: testFolderURL.appending(path: "TreeExpand", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("ツリー展開テスト".utf8).write(
      to: testFolderURL.appending(path: "TreeExpand/inner-file.txt"))
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: testFolderURL)
  }

  func testLaunchShowsFolderSelectionGuide() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = ["-reset-folder-bookmark"]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 3))
    XCTAssertEqual(window.title, "フォルダを選択")
    XCTAssertNotEqual(window.title, "PKPane")
    XCTAssertTrue(app.staticTexts["フォルダを選択"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["フォルダを選択"].exists)
    XCTAssertTrue(app.buttons["サーバへ接続…"].exists)
  }

  func testNASConnectionFormValidatesRequiredName() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = ["-reset-folder-bookmark"]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.buttons["サーバへ接続…"].firstMatch.click()
    XCTAssertTrue(app.buttons["新規接続…"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["新規接続…"].firstMatch.click()

    XCTAssertTrue(app.textFields["nas-connection-name"].waitForExistence(timeout: 3))
    app.buttons["保存して接続"].firstMatch.click()

    XCTAssertTrue(
      app.staticTexts["NAS接続名が正しくありません。"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["connect-panel-back"].click()
    app.buttons["閉じる"].click()
  }

  func testSFTPConnectionSaveAddsConnectionToSidebar() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = ["-reset-folder-bookmark"]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.buttons["サーバへ接続…"].click()
    XCTAssertTrue(app.buttons["新規接続…"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["新規接続…"].firstMatch.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel-protocol"].waitForExistence(timeout: 3))
    app.radioButtons["SFTP"].click()
    let hostField = app.textFields["sftp-connection-host"]
    XCTAssertTrue(hostField.waitForExistence(timeout: 3))
    hostField.click()
    app.typeText("example.com")
    app.textFields["sftp-connection-username"].click()
    app.typeText("tester")
    app.secureTextFields["sftp-connection-password"].click()
    app.typeText("password")
    app.buttons["保存して接続"].click()

    XCTAssertTrue(app.buttons["tester@example.com:22"].waitForExistence(timeout: 3))
  }

  func testSFTPConnectionFormAcceptsStartDirectory() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = ["-reset-folder-bookmark"]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.buttons["サーバへ接続…"].click()
    XCTAssertTrue(app.buttons["新規接続…"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["新規接続…"].firstMatch.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel-protocol"].waitForExistence(timeout: 3))
    app.radioButtons["SFTP"].click()

    let startDirectoryField = app.textFields["sftp-connection-start-directory"]
    XCTAssertTrue(startDirectoryField.waitForExistence(timeout: 3))
    startDirectoryField.click()
    app.typeText("/srv/projects")

    XCTAssertEqual(startDirectoryField.value as? String, "/srv/projects")
  }

  func testConnectPanelOpensViaKeyboardShortcutAndSwitchesProtocol() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))

    app.typeKey("k", modifierFlags: .command)

    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel"].waitForExistence(timeout: 3))
    app.buttons["新規接続…"].firstMatch.click()

    XCTAssertTrue(app.textFields["nas-connection-name"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.descendants(matching: .any)["connect-panel-protocol"].exists)

    app.radioButtons["SFTP"].click()
    XCTAssertTrue(app.textFields["sftp-connection-host"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textFields["nas-connection-name"].exists)

    app.radioButtons["FTP/FTPS"].click()
    XCTAssertTrue(app.textFields["ftp-connection-host"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["ftp-connection-test"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textFields["sftp-connection-host"].exists)

    app.buttons["connect-panel-back"].click()
    app.buttons["閉じる"].click()
  }

  func testConnectPanelOpensViaKeyboardShortcutShowsListMode() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))

    app.typeKey("k", modifierFlags: .command)

    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel-search"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.descendants(matching: .any)["connect-panel-list"].exists)
    XCTAssertFalse(app.textFields["nas-connection-name"].exists)

    app.buttons["閉じる"].click()
  }

  func testConnectPanelNewConnectionButtonNavigatesToFormAndBackReturnsToList() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel-list"].waitForExistence(timeout: 3))

    app.buttons["新規接続…"].firstMatch.click()
    XCTAssertTrue(app.textFields["nas-connection-name"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.descendants(matching: .any)["connect-panel-protocol"].exists)

    app.radioButtons["SFTP"].click()
    XCTAssertTrue(app.textFields["sftp-connection-host"].waitForExistence(timeout: 3))

    app.buttons["connect-panel-back"].click()
    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel-list"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textFields["sftp-connection-host"].exists)

    app.buttons["閉じる"].click()
  }

  func testConnectPanelFormShowsConnectionTestButtonForAllProtocols() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = ["-reset-folder-bookmark"]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.buttons["サーバへ接続…"].click()
    XCTAssertTrue(app.buttons["新規接続…"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["新規接続…"].firstMatch.click()

    XCTAssertTrue(app.textFields["nas-connection-name"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["nas-connection-test"].waitForExistence(timeout: 3))

    app.radioButtons["SFTP"].click()
    XCTAssertTrue(app.textFields["sftp-connection-host"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["sftp-connection-test"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["nas-connection-test"].exists)

    app.radioButtons["FTP/FTPS"].click()
    XCTAssertTrue(app.textFields["ftp-connection-host"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["ftp-connection-test"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["sftp-connection-test"].exists)

    let plainFTP = app.radioButtons["FTP（暗号化なし）"]
    XCTAssertTrue(plainFTP.waitForExistence(timeout: 3))
    plainFTP.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(app.descendants(matching: .any)["ftp-unencrypted-warning"].exists)

    app.buttons["connect-panel-back"].click()
    app.buttons["閉じる"].click()
  }

  func testConnectPanelConnectionTestShowsUnreachableGuidanceForInvalidHost() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = ["-reset-folder-bookmark"]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.buttons["サーバへ接続…"].click()
    XCTAssertTrue(app.buttons["新規接続…"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["新規接続…"].firstMatch.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel-protocol"].waitForExistence(timeout: 3))

    let hostField = app.textFields["nas-connection-host"]
    XCTAssertTrue(hostField.waitForExistence(timeout: 3))
    // 標準のclick()は祖先ScrollView内のヒットポイント解決に失敗することがある
    // (Unable to find hit point for ScrollView)。要素の座標を直接指定してクリックすることで
    // 回避する。
    hostField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    app.typeText("connect-panel-test.invalid")
    app.buttons["nas-connection-test"].click()

    XCTAssertTrue(
      app.staticTexts["サーバーに到達できません。ホスト名とネットワーク接続を確認してください。"]
        .waitForExistence(timeout: 8))

    app.buttons["connect-panel-back"].click()
    app.buttons["閉じる"].click()
  }

  func testSidebarConnectButtonOpensConnectPanel() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = ["-reset-folder-bookmark"]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.buttons["サーバへ接続…"].click()

    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["新規接続…"].firstMatch.waitForExistence(timeout: 3))

    app.buttons["閉じる"].click()
  }

  func testSidebarConnectionCanBeHiddenAndRestoredFromConnectPanel() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let connectionButton = app.buttons["tester@host-key-test.invalid:22"]
    XCTAssertTrue(connectionButton.waitForExistence(timeout: 6))
    connectionButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    let hideMenuItem = app.menuItems["サイドバーから隠す"]
    XCTAssertTrue(hideMenuItem.waitForExistence(timeout: 3))
    hideMenuItem.click()

    let disappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: connectionButton)
    wait(for: [disappearance], timeout: 3)

    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel-list"].waitForExistence(timeout: 3))
    let row = app.descendants(matching: .any)[
      "connect-panel-row-sftp:host-key-test.invalid:22:tester"
    ].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 3))
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    let showMenuItem = app.menuItems["サイドバーに表示"]
    XCTAssertTrue(showMenuItem.waitForExistence(timeout: 3))
    showMenuItem.click()
    app.buttons["閉じる"].click()

    XCTAssertTrue(connectionButton.waitForExistence(timeout: 3))
  }

  func testSFTPConnectionContextMenuDeletesConnection() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let connection = app.buttons["tester@host-key-test.invalid:22"]
    XCTAssertTrue(connection.waitForExistence(timeout: 6))
    connection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    let deleteMenuItem = app.menuItems["削除"]
    XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 3))
    deleteMenuItem.click()

    let disappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: connection)
    wait(for: [disappearance], timeout: 3)
  }

  func testRestoredLocalFolderUsesCommonWorkspace() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 3))
    let breadcrumbs = window.scrollViews["provider-browser-breadcrumbs"]
    XCTAssertTrue(breadcrumbs.waitForExistence(timeout: 3))
    XCTAssertTrue(window.descendants(matching: .any)["provider-browser-action-menu"].exists)
    // 2ペインが既定のため、起動直後からセカンダリ一覧が存在する。
    XCTAssertTrue(window.buttons["1ペイン"].exists)
    XCTAssertTrue(
      window.descendants(matching: .any)["provider-browser-list-secondary"]
        .waitForExistence(timeout: 3))

    let primaryPane = window.buttons["provider-browser-pane-primary"]
    let secondaryPane = window.buttons["provider-browser-pane-secondary"]
    let secondaryList = window.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(primaryPane.waitForExistence(timeout: 3))
    XCTAssertTrue(secondaryPane.exists)
    XCTAssertEqual(primaryPane.label, "左ペイン、操作対象")
    XCTAssertEqual(secondaryPane.label, "右ペイン、操作対象にする")

    secondaryPane.click()
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象にする"))
    // 操作対象の切替は現在位置を変えてはならない。透明なアクセシビリティ要素が
    // パンくずの実ボタンをクリックして親フォルダへ移動する回帰を防ぐ。
    XCTAssertTrue(secondaryList.staticTexts["Documents"].waitForExistence(timeout: 3))
  }

  func testDefaultLaunchUsesTwoPaneLayout() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 3))

    // 何も操作していない初回起動時点で2ペイン表示になっていること
    // (「1ペイン」ボタンが見えるのは現在2ペイン表示中であることを示す)。
    XCTAssertTrue(window.buttons["1ペイン"].waitForExistence(timeout: 3))
    XCTAssertFalse(window.buttons["2ペイン"].exists)
    XCTAssertTrue(
      window.descendants(matching: .any)["provider-browser-list-secondary"]
        .waitForExistence(timeout: 3))
    XCTAssertTrue(window.descendants(matching: .any)["provider-browser-list"].exists)
  }

  /// ダークモードのツールバーを画素解析し、背景色の分断と境界線の回帰を防ぐ。
  func testToolbarDoesNotShowSplitViewSeparators() throws {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_APPEARANCE"] = "dark"

    launch(app)
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 3))
    let toolbar = window.toolbars.firstMatch
    XCTAssertTrue(toolbar.waitForExistence(timeout: 3))
    let firstSidebarHeader = window.buttons["sidebar-section-favorites"]
    XCTAssertTrue(firstSidebarHeader.waitForExistence(timeout: 3))
    let primaryBreadcrumbs = window.scrollViews["provider-browser-breadcrumbs"]
    let secondaryBreadcrumbs = window.scrollViews["provider-browser-breadcrumbs-secondary"]
    let primaryList = window.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(primaryBreadcrumbs.waitForExistence(timeout: 6))
    XCTAssertTrue(secondaryBreadcrumbs.waitForExistence(timeout: 3))
    XCTAssertTrue(primaryList.waitForExistence(timeout: 3))

    // サイドバーの再構成後も、先頭項目がツールバー下へ潜り込まないことを確認する。
    let hideSidebarButton = window.buttons["サイドバーを非表示"]
    XCTAssertTrue(hideSidebarButton.waitForExistence(timeout: 3))
    hideSidebarButton.click()
    let showSidebarButton = window.buttons["サイドバーを表示"]
    XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 3))
    showSidebarButton.click()
    XCTAssertTrue(firstSidebarHeader.waitForExistence(timeout: 3))

    app.typeKey("p", modifierFlags: [.command, .shift])
    let inspector = window.descendants(matching: .any)["details-inspector-pane"]
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))

    let screenshot = window.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "ツールバー境界線"
    attachment.lifetime = .keepAlways
    add(attachment)

    // macOS 26ではXCUIのToolbar.frameがウインドウ全体を返すことがあるため、
    // 実際のコンテンツ開始位置であるパンくず上端を境界として使う。
    let toolbarBottomY = min(
      primaryBreadcrumbs.frame.minY,
      secondaryBreadcrumbs.frame.minY)
    let paneSeparatorRatio = try verticalEdgeRatio(
      in: screenshot,
      windowFrame: window.frame,
      screenX: primaryList.frame.maxX,
      toolbarBottomY: toolbarBottomY)
    let inspectorSeparatorRatio = try verticalEdgeRatio(
      in: screenshot,
      windowFrame: window.frame,
      screenX: inspector.frame.minX,
      toolbarBottomY: toolbarBottomY)
    let horizontalSeparatorRatio = try horizontalEdgeRatio(
      in: screenshot,
      windowFrame: window.frame,
      screenMinX: primaryList.frame.minX,
      screenMaxX: primaryList.frame.maxX,
      toolbarBottomY: toolbarBottomY)
    let sidebarBackgroundDistance = try pixelColorDistance(
      in: screenshot,
      windowFrame: window.frame,
      firstScreenPoint: CGPoint(
        x: window.frame.minX + 100,
        y: window.frame.minY + 20),
      secondScreenPoint: CGPoint(
        x: window.frame.minX + 100,
        y: toolbarBottomY + 14))
    let detailBackgroundDistance = try backgroundColorDistance(
      in: screenshot,
      windowFrame: window.frame,
      screenMinX: primaryList.frame.minX,
      screenMaxX: primaryList.frame.maxX,
      firstScreenY: toolbarBottomY - 10,
      secondScreenY: toolbarBottomY + 14)

    XCTAssertLessThan(
      paneSeparatorRatio,
      0.45,
      "ペイン境界の縦線がツールバー内に残っています: \(paneSeparatorRatio)、"
        + "window=\(window.frame)、primary=\(primaryBreadcrumbs.frame)")
    XCTAssertLessThan(
      inspectorSeparatorRatio,
      0.45,
      "詳細境界の縦線がツールバー内に残っています: \(inspectorSeparatorRatio)、"
        + "inspector=\(inspector.frame)")
    XCTAssertLessThan(
      horizontalSeparatorRatio,
      0.65,
      "ツールバー下端の横線が残っています: \(horizontalSeparatorRatio)")
    XCTAssertGreaterThanOrEqual(
      firstSidebarHeader.frame.minY,
      toolbarBottomY,
      "サイドバー上端がツールバーに隠れています: toolbar=\(toolbar.frame)、"
        + "header=\(firstSidebarHeader.frame)")
    XCTAssertLessThan(
      sidebarBackgroundDistance,
      0.01,
      "サイドバー背景がツールバーで分断されています: \(sidebarBackgroundDistance)")
    XCTAssertLessThan(
      detailBackgroundDistance,
      0.01,
      "メイン領域の背景がツールバーで分断されています: \(detailBackgroundDistance)")
  }

  func testMainMenuProvidesFileEditViewAndGoMenus() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)

    for title in ["ファイル", "編集", "表示", "移動"] {
      XCTAssertTrue(
        app.menuBars.menuBarItems[title].waitForExistence(timeout: 3),
        "\(title)メニューがメニューバーに存在するはず")
    }
  }

  func testMainEditMenuCopyPasteTransfersFile() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let (_, primaryList, secondaryList) = prepareLocalTwoPaneTransferTest(app)

    let sourceRow = primaryList.staticTexts["report.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
    sourceRow.click()

    app.menuBars.menuBarItems["編集"].click()
    app.menuItems["コピー"].firstMatch.click()

    activatePaneByClickingList(secondaryList)
    app.menuBars.menuBarItems["編集"].click()
    app.menuItems["ペースト"].firstMatch.click()

    XCTAssertTrue(secondaryList.staticTexts["report.txt"].waitForExistence(timeout: 5))
    XCTAssertTrue(primaryList.staticTexts["report.txt"].exists)
  }

  func testMainViewMenuChangesListSortOrder() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    XCTAssertTrue(browser.staticTexts["a-size-small.txt"].waitForExistence(timeout: 5))
    XCTAssertTrue(browser.staticTexts["z-size-large.txt"].exists)

    app.menuBars.menuBarItems["表示"].click()
    let sortMenu = app.menuItems["並び順"]
    XCTAssertTrue(sortMenu.waitForExistence(timeout: 3))
    sortMenu.hover()
    app.menuItems["サイズ"].click()

    XCTAssertTrue(
      waitForRowOrder(browser, expectingBefore: "a-size-small.txt", after: "z-size-large.txt"))
  }

  /// ⌘3で第3の表示形式へ切り替え、最後のカラムのフォルダ選択で右に子カラムが
  /// 追加される基本動線を検証する。
  func testColumnViewShortcutExpandsSelectedFolder() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    XCTAssertTrue(
      window.descendants(matching: .any)["provider-browser-list"]
        .waitForExistence(timeout: 6))

    app.typeKey("3", modifierFlags: .command)

    let browser = window.descendants(matching: .any)["provider-browser-column"]
    XCTAssertTrue(browser.waitForExistence(timeout: 5))
    let currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(currentColumn.waitForExistence(timeout: 3))
    let documents = currentColumn.staticTexts["Documents"]
    XCTAssertTrue(documents.waitForExistence(timeout: 3))
    documents.click()

    XCTAssertTrue(browser.staticTexts["caria"].waitForExistence(timeout: 5))
  }

  /// カラム行がリストと同じネイティブ右クリックメニューを表示することを確認する。
  func testColumnViewRowShowsContextMenu() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    app.typeKey("3", modifierFlags: .command)

    let browser = window.descendants(matching: .any)["provider-browser-column"]
    XCTAssertTrue(browser.waitForExistence(timeout: 5))
    let report = browser.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 3))
    report.rightClick()

    let openMenuItem = hittableMenuItem(in: app, title: "開く")
    XCTAssertTrue(openMenuItem.waitForExistence(timeout: 3))
    XCTAssertTrue(openMenuItem.isHittable)
    app.typeKey(.escape, modifierFlags: [])
  }

  /// セカンダリペインを操作対象にしてサイドバーから別の場所を開いた場合も、移動先の
  /// 先頭カラムが表示され、反対側のプライマリペインのカラム状態が変わらないことを確認する。
  func testColumnViewShowsItemsAfterOpeningSidebarFavorite() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let list = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(list.waitForExistence(timeout: 6))

    let actionMenu = app.descendants(matching: .any)["provider-browser-action-menu"]
    XCTAssertTrue(actionMenu.waitForExistence(timeout: 3))
    actionMenu.click()
    hittableMenuItem(in: app, title: "お気に入りに追加").click()
    let favorite = app.buttons["saved-location-\(testFolderURL.lastPathComponent)"]
    XCTAssertTrue(favorite.waitForExistence(timeout: 3))

    app.typeKey("3", modifierFlags: .command)
    let primaryColumn = app.descendants(matching: .any)["provider-browser-column"]
    let secondaryColumn = app.descendants(matching: .any)["provider-browser-column-secondary"]
    XCTAssertTrue(primaryColumn.waitForExistence(timeout: 5))
    XCTAssertTrue(secondaryColumn.waitForExistence(timeout: 5))

    let primaryDocuments = primaryColumn.staticTexts["Documents"]
    XCTAssertTrue(primaryDocuments.waitForExistence(timeout: 3))
    primaryDocuments.click()
    let primaryCurrentColumn =
      primaryColumn.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(primaryCurrentColumn.staticTexts["caria"].waitForExistence(timeout: 5))

    let secondaryPane = app.buttons["provider-browser-pane-secondary"]
    secondaryPane.click()
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    let secondaryDocuments = secondaryColumn.staticTexts["Documents"]
    XCTAssertTrue(secondaryDocuments.waitForExistence(timeout: 3))
    secondaryDocuments.click()
    var secondaryCurrentColumn =
      secondaryColumn.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(secondaryCurrentColumn.staticTexts["caria"].waitForExistence(timeout: 5))

    favorite.click()

    secondaryCurrentColumn =
      secondaryColumn.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(secondaryCurrentColumn.staticTexts["report.txt"].waitForExistence(timeout: 5))
    XCTAssertTrue(primaryCurrentColumn.staticTexts["caria"].waitForExistence(timeout: 3))
    XCTAssertFalse(primaryCurrentColumn.staticTexts["report.txt"].exists)
  }

  /// 恒久UI要件: カラムでファイルを1クリックすると、別ペインの詳細が同じ選択へ追従する。
  /// 繰り返し指摘された要件の防護テストなので、ユーザー承認なしに削除・スキップ化しない。
  func testColumnFileSelectionUpdatesDetailsInspector() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    XCTAssertTrue(
      window.descendants(matching: .any)["provider-browser-list"]
        .waitForExistence(timeout: 6))

    app.typeKey("p", modifierFlags: [.command, .shift])
    let inspector = window.descendants(matching: .any)["details-inspector-pane"]
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    let detailsMenu = app.descendants(matching: .any)["provider-browser-details-inspector-toggle"]
    XCTAssertEqual(detailsMenu.value as? String, "オン")
    app.typeKey("3", modifierFlags: .command)

    let browser = window.descendants(matching: .any)["provider-browser-column"]
    XCTAssertTrue(browser.waitForExistence(timeout: 5))
    let currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    let report = currentColumn.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 3))
    report.click()

    XCTAssertTrue(inspector.staticTexts["report.txt"].waitForExistence(timeout: 3))
  }

  /// カラム表示で上下キーが同一カラム内、左右キーが親子カラム間を移動することを
  /// 実入力から選択表示まで確認する。
  func testColumnArrowKeysMoveBetweenRowsAndColumns() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.typeKey("3", modifierFlags: .command)

    let browser = app.descendants(matching: .any)["provider-browser-column"]
    XCTAssertTrue(browser.waitForExistence(timeout: 5))
    let rootColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    let treeExpand = rootColumn.staticTexts["TreeExpand"]
    XCTAssertTrue(treeExpand.waitForExistence(timeout: 3))
    treeExpand.click()

    let childColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    let child = childColumn.staticTexts["inner-file.txt"]
    XCTAssertTrue(child.waitForExistence(timeout: 5))

    app.typeKey(.rightArrow, modifierFlags: [])
    let childRow = tableRow(in: childColumn, staticText: "inner-file.txt")
    XCTAssertTrue(childRow.isSelected)

    app.typeKey(.leftArrow, modifierFlags: [])
    let treeExpandRow = tableRow(in: browser, staticText: "TreeExpand")
    XCTAssertTrue(treeExpandRow.isSelected)

    app.typeKey(.upArrow, modifierFlags: [])
    let reportRow = tableRow(in: browser, staticText: "report.txt")
    XCTAssertTrue(reportRow.isSelected)
  }

  /// カラム境界をドラッグすると左側のカラムだけが変わり、その幅が次回の既定幅になる。
  func testColumnWidthCanBeResizedAndPersistsAcrossRelaunch() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    var window = app.windows.firstMatch
    app.typeKey("3", modifierFlags: .command)

    var browser = window.descendants(matching: .any)["provider-browser-column"]
    XCTAssertTrue(browser.waitForExistence(timeout: 5))
    var currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(currentColumn.waitForExistence(timeout: 3))
    let treeExpand = currentColumn.staticTexts["TreeExpand"]
    XCTAssertTrue(treeExpand.waitForExistence(timeout: 3))
    treeExpand.click()

    var parentColumn = browser.descendants(matching: .any)["file-browser-column-parent"]
    currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(parentColumn.waitForExistence(timeout: 3))
    XCTAssertTrue(currentColumn.waitForExistence(timeout: 3))
    let resizeHandle = browser.descendants(matching: .any)["file-column-resize-handle-0"]
    XCTAssertTrue(resizeHandle.waitForExistence(timeout: 3))

    // 保存済み値が上限側なら左、それ以外は右へ60ptだけ動かし、ウィンドウ外へ出さない。
    let originalWidth = parentColumn.frame.width
    let unchangedWidth = currentColumn.frame.width
    let dragDelta: CGFloat = originalWidth > 360 ? -60 : 60
    let resizeStart = resizeHandle.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    resizeStart.press(
      forDuration: 0.2,
      thenDragTo: resizeStart.withOffset(CGVector(dx: dragDelta, dy: 0)))

    // 再起動前に実画面の幅が変わったことを確認し、ドラッグ失敗と永続化失敗を分離する。
    parentColumn = browser.descendants(matching: .any)["file-browser-column-parent"]
    currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(waitForWidthChange(of: parentColumn, from: originalWidth))
    XCTAssertEqual(currentColumn.frame.width, unchangedWidth, accuracy: 2)
    let resizedWidth = parentColumn.frame.width

    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    app.launchArguments = ["-ui-test-folder-path", testFolderURL.path]
    launch(app)

    window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 3))
    browser = window.descendants(matching: .any)["provider-browser-column"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    XCTAssertTrue(currentColumn.waitForExistence(timeout: 3))
    XCTAssertTrue(
      browser.descendants(matching: .any)["file-column-resize-handle-current"]
        .waitForExistence(timeout: 3))
    XCTAssertEqual(currentColumn.frame.width, resizedWidth, accuracy: 2)
  }

  /// 表示モードをカラムへ切り替えた状態がアプリ再起動後にも復元され、親ツールバーと
  /// ブラウザ本体が同じ永続値を参照することを確認する。
  func testColumnViewModePersistsAcrossRelaunch() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    app.typeKey("3", modifierFlags: .command)
    XCTAssertTrue(
      app.descendants(matching: .any)["provider-browser-column"]
        .waitForExistence(timeout: 5))

    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    app.launchArguments = ["-ui-test-folder-path", testFolderURL.path]
    launch(app)

    XCTAssertTrue(
      app.descendants(matching: .any)["provider-browser-column"]
        .waitForExistence(timeout: 6))
  }

  func testFileMoveAndCommandMenusExposeMenuBarCompleteItems() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)

    app.menuBars.menuBarItems["ファイル"].click()
    for title in ["開く", "複製", "選択項目をZIPに圧縮"] {
      XCTAssertTrue(
        app.menuItems[title].waitForExistence(timeout: 3),
        "\(title)がファイルメニューに存在するはず")
    }
    app.typeKey(.escape, modifierFlags: [])

    app.menuBars.menuBarItems["移動"].click()
    XCTAssertTrue(
      app.menuItems["サーバへ接続…"].waitForExistence(timeout: 3),
      "サーバへ接続…が移動メニューに存在するはず")
    app.typeKey(.escape, modifierFlags: [])

    app.menuBars.menuBarItems["表示"].click()
    let viewModeMenu = app.menuItems["表示形式"]
    XCTAssertTrue(viewModeMenu.waitForExistence(timeout: 3))
    viewModeMenu.hover()
    XCTAssertTrue(app.menuItems["カラム"].waitForExistence(timeout: 3))
    app.typeKey(.escape, modifierFlags: [])

    XCTAssertTrue(app.menuBars.menuBarItems["コマンド"].waitForExistence(timeout: 3))
  }

  func testFileMenuDuplicateCreatesCopyOfSelectedItem() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let sourceRow = browser.staticTexts["report.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
    sourceRow.click()

    app.menuBars.menuBarItems["ファイル"].click()
    app.menuItems["複製"].firstMatch.click()

    XCTAssertTrue(browser.staticTexts["reportのコピー.txt"].waitForExistence(timeout: 5))
    XCTAssertTrue(browser.staticTexts["report.txt"].exists)
  }

  func testGoMenuServerConnectionOpensConnectPanelListMode() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))

    app.menuBars.menuBarItems["移動"].click()
    app.menuItems["サーバへ接続…"].click()

    XCTAssertTrue(
      app.descendants(matching: .any)["connect-panel"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["新規接続…"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["閉じる"].click()
  }

  func testClickingInactivePaneListActivatesPane() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 3))

    let primaryPane = window.buttons["provider-browser-pane-primary"]
    let secondaryPane = window.buttons["provider-browser-pane-secondary"]
    XCTAssertTrue(primaryPane.waitForExistence(timeout: 3))
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象にする"))

    let secondaryList = window.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 3))
    let secondaryDocuments = secondaryList.staticTexts["Documents"]
    XCTAssertTrue(secondaryDocuments.waitForExistence(timeout: 3))

    // 選択が空のまま一覧の余白(行のない領域)をクリックしてもアクティブ化されること
    secondaryList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).click()
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象にする"))

    // ファイル行クリックでアクティブ化と選択が両立すること
    primaryPane.click()
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))
    secondaryDocuments.click()
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    let secondaryDocumentsRow = secondaryList.descendants(matching: .tableRow)
      .containing(.staticText, identifier: "Documents").firstMatch
    XCTAssertTrue(secondaryDocumentsRow.waitForExistence(timeout: 3))
    XCTAssertTrue(secondaryDocumentsRow.isSelected)

    // 既に選択済みの行を再クリックしても(選択集合が変化しなくても)アクティブ化が届くこと
    primaryPane.click()
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))
    secondaryDocuments.click()
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
  }

  func testColumnHeadersSortListAndToggleDirection() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    XCTAssertTrue(browser.staticTexts["a-size-small.txt"].waitForExistence(timeout: 5))
    XCTAssertTrue(browser.staticTexts["z-size-large.txt"].exists)

    // NSTableViewのヘッダボタンはXCUITestの当たり判定チェックで
    // "Not hittable"と誤判定される既知の弱点があるため、座標クリックで回避する。
    let sizeHeader = browser.buttons["サイズ"]
    XCTAssertTrue(sizeHeader.waitForExistence(timeout: 3))
    sizeHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    // Documents(フォルダ)はサイズ未定でboundBy:0の決め打ちが崩れるため、
    // 注目する2項目間の相対順序で降順を確認する。
    XCTAssertTrue(
      waitForRowOrder(browser, expectingBefore: "z-size-large.txt", after: "a-size-small.txt"))

    sizeHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(
      waitForRowOrder(browser, expectingBefore: "a-size-small.txt", after: "z-size-large.txt"))

    let nameHeader = browser.buttons["名前"]
    XCTAssertTrue(nameHeader.waitForExistence(timeout: 3))
    nameHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(
      waitForRowOrder(browser, expectingBefore: "a-size-small.txt", after: "z-size-large.txt"))
  }

  /// リスト表示の開閉三角クリックによるフォルダその場展開・折りたたみの再現テスト。
  /// doc/plans/2026-08-16-list-tree-expansion.md Step 2。
  func testListDisclosureTriangleExpandsAndCollapsesChildren() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    XCTAssertTrue(browser.staticTexts["TreeExpand"].waitForExistence(timeout: 5))
    XCTAssertFalse(browser.staticTexts["inner-file.txt"].exists)

    // NSTableViewのヘッダボタン同様、行内のNSButton(開閉三角)もXCUITestの当たり判定チェックで
    // "Not hittable"と誤判定されうるため座標クリックで回避する。
    let disclosureButton = browser.buttons["file-disclosure-TreeExpand"]
    XCTAssertTrue(disclosureButton.waitForExistence(timeout: 3))
    disclosureButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

    XCTAssertTrue(browser.staticTexts["inner-file.txt"].waitForExistence(timeout: 5))

    disclosureButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

    let disappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: browser.staticTexts["inner-file.txt"])
    wait(for: [disappearance], timeout: 5)
  }

  /// ←→キーによるフォルダその場展開・折りたたみ・親行への選択移動の再現テスト。
  /// doc/plans/2026-08-16-list-tree-expansion.md Step 2。
  func testListArrowKeysExpandCollapseAndSelectParentFolder() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    XCTAssertTrue(browser.staticTexts["TreeExpand"].waitForExistence(timeout: 5))

    browser.staticTexts["TreeExpand"].click()
    app.typeKey(.rightArrow, modifierFlags: [])
    XCTAssertTrue(browser.staticTexts["inner-file.txt"].waitForExistence(timeout: 5))

    // 子行(展開不可・深さ1)を選択して←キー: 親行(TreeExpand)へ選択が移動するはず。
    browser.staticTexts["inner-file.txt"].click()
    app.typeKey(.leftArrow, modifierFlags: [])
    let treeExpandRow = tableRow(in: browser, staticText: "TreeExpand")
    let selectsParent = expectation(
      for: NSPredicate(format: "isSelected == true"), evaluatedWith: treeExpandRow)
    wait(for: [selectsParent], timeout: 5)

    // 展開済みの親行(TreeExpand)で再度←キー: 折りたたむはず。
    app.typeKey(.leftArrow, modifierFlags: [])
    let disappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: browser.staticTexts["inner-file.txt"])
    wait(for: [disappearance], timeout: 5)
  }

  /// リスト表示でのCommand+クリックによる個別追加選択の再現テスト。
  /// 2026-08-12 ユーザー報告の退行(効かない)を検証する。
  func testListCommandClickTogglesMultipleSelection() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let browser = enterMultiSelectFixtureFolder(app)

    let rowA = tableRow(in: browser, staticText: "select-a.txt")
    let rowB = tableRow(in: browser, staticText: "select-b.txt")
    let rowC = tableRow(in: browser, staticText: "select-c.txt")
    XCTAssertTrue(rowA.waitForExistence(timeout: 3))
    XCTAssertTrue(rowB.waitForExistence(timeout: 3))
    XCTAssertTrue(rowC.waitForExistence(timeout: 3))

    browser.staticTexts["select-a.txt"].click()
    XCTAssertTrue(rowA.isSelected)
    XCTAssertFalse(rowC.isSelected)

    XCUIElement.perform(withKeyModifiers: .command) {
      browser.staticTexts["select-c.txt"].click()
    }

    XCTAssertTrue(rowA.isSelected, "Command+クリックは既存選択を保ったまま追加するはず")
    XCTAssertTrue(rowC.isSelected, "Command+クリックした行が選択されるはず")
    XCTAssertFalse(rowB.isSelected, "Command+クリックしていない行は選択されないはず")
  }

  /// Command+クリックで複数選択した後の⌘⌫削除が全選択項目に効くことの再現テスト。
  /// 2026-08-14 ユーザー報告「複数選択して削除しても1件しか消えない」の検証。
  func testCommandDeleteRemovesAllSelectedFiles() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let browser = enterMultiSelectFixtureFolder(app)

    let rowA = tableRow(in: browser, staticText: "select-a.txt")
    let rowC = tableRow(in: browser, staticText: "select-c.txt")
    XCTAssertTrue(rowA.waitForExistence(timeout: 3))
    XCTAssertTrue(rowC.waitForExistence(timeout: 3))

    browser.staticTexts["select-a.txt"].click()
    XCUIElement.perform(withKeyModifiers: .command) {
      browser.staticTexts["select-c.txt"].click()
    }
    XCTAssertTrue(rowA.isSelected)
    XCTAssertTrue(rowC.isSelected)

    app.typeKey(.delete, modifierFlags: .command)

    let disappearanceA = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: browser.staticTexts["select-a.txt"])
    let disappearanceC = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: browser.staticTexts["select-c.txt"])
    wait(for: [disappearanceA, disappearanceC], timeout: 5)
    XCTAssertTrue(browser.staticTexts["select-b.txt"].exists, "選択していない項目は残るはず")
  }

  /// リスト表示でのShift+クリックによる範囲選択の再現テスト。
  /// 2026-08-12 ユーザー報告の退行(効かない)を検証する。
  func testListShiftClickSelectsRange() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let browser = enterMultiSelectFixtureFolder(app)

    let rowA = tableRow(in: browser, staticText: "select-a.txt")
    let rowB = tableRow(in: browser, staticText: "select-b.txt")
    let rowC = tableRow(in: browser, staticText: "select-c.txt")
    XCTAssertTrue(rowA.waitForExistence(timeout: 3))
    XCTAssertTrue(rowB.waitForExistence(timeout: 3))
    XCTAssertTrue(rowC.waitForExistence(timeout: 3))

    browser.staticTexts["select-a.txt"].click()
    XCTAssertTrue(rowA.isSelected)

    XCUIElement.perform(withKeyModifiers: .shift) {
      browser.staticTexts["select-c.txt"].click()
    }

    XCTAssertTrue(rowA.isSelected, "Shift+クリックの範囲選択は起点行を含むはず")
    XCTAssertTrue(rowB.isSelected, "Shift+クリックの範囲選択は間の行を含むはず")
    XCTAssertTrue(rowC.isSelected, "Shift+クリックした行が選択されるはず")
  }

  /// アイコン表示でのCommand+クリック複数選択を、選択結果に依存する実際の操作
  /// (コピー&ペーストで両方が転送される)を通じて間接検証する。選択計算自体の
  /// 単体テストはIconGridSelectionTests(PKPaneTests)で網羅している。
  func testIconViewCommandClickSelectsMultipleItemsForCopy() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    _ = enterMultiSelectFixtureFolder(app)
    let window = app.windows.firstMatch

    let secondaryList = window.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 3))

    // アイコン表示へ切り替える(両ペイン共通の表示形式設定)。NSTableViewヘッダ同様、
    // ツールバーMenuの正確なAXロールは決め打ちできないためdescendants(matching: .any)で探す。
    let viewMenu = window.descendants(matching: .any)["provider-browser-view-menu"]
    XCTAssertTrue(viewMenu.waitForExistence(timeout: 3))
    viewMenu.click()
    hittableMenuItem(in: app, title: "アイコン").click()

    let primaryGrid = window.descendants(matching: .any)["provider-browser-icon-grid"]
    XCTAssertTrue(primaryGrid.waitForExistence(timeout: 5))
    let iconA = primaryGrid.buttons["file-icon-select-a.txt"]
    let iconC = primaryGrid.buttons["file-icon-select-c.txt"]
    XCTAssertTrue(iconA.waitForExistence(timeout: 5))
    XCTAssertTrue(iconC.waitForExistence(timeout: 5))

    iconA.click()
    XCUIElement.perform(withKeyModifiers: .command) {
      iconC.click()
    }
    app.typeKey("c", modifierFlags: .command)

    let secondaryGrid = window.descendants(matching: .any)["provider-browser-icon-grid-secondary"]
    XCTAssertTrue(secondaryGrid.waitForExistence(timeout: 5))
    // 既知のアイコン(Documents)をクリックしてセカンダリペインを操作対象へ切り替える。
    let secondaryDocumentsIcon = secondaryGrid.buttons["file-icon-Documents"]
    XCTAssertTrue(secondaryDocumentsIcon.waitForExistence(timeout: 5))
    secondaryDocumentsIcon.click()
    app.typeKey("v", modifierFlags: .command)

    XCTAssertTrue(
      secondaryGrid.buttons["file-icon-select-a.txt"].waitForExistence(timeout: 5),
      "Command+クリックで選択した1件目がコピーされているはず")
    XCTAssertTrue(
      secondaryGrid.buttons["file-icon-select-c.txt"].waitForExistence(timeout: 5),
      "Command+クリックで選択した2件目がコピーされているはず")
  }

  /// アイコン表示で⌘+を押すとグリッドのセルが拡大されることを検証する
  /// (表示メニュー経由の拡大/縮小、2026-08-16 アイコンサイズ4段階調整機能)。
  func testIconViewCommandPlusIncreasesIconGridCellSize() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    let viewMenu = window.descendants(matching: .any)["provider-browser-view-menu"]
    XCTAssertTrue(viewMenu.waitForExistence(timeout: 3))
    viewMenu.click()
    hittableMenuItem(in: app, title: "アイコン").click()

    let grid = window.descendants(matching: .any)["provider-browser-icon-grid"]
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    let icon = grid.buttons["file-icon-report.txt"]
    XCTAssertTrue(icon.waitForExistence(timeout: 5))
    let originalWidth = icon.frame.width

    app.typeKey("+", modifierFlags: .command)

    XCTAssertTrue(
      waitForWidthIncrease(of: icon, beyond: originalWidth),
      "⌘+でアイコングリッドのセルが拡大されるはず")
  }

  func testRecentLocalLocationReloadsBrowserContents() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let documents = browser.staticTexts["Documents"]
    XCTAssertTrue(documents.waitForExistence(timeout: 5))
    documents.doubleClick()
    XCTAssertTrue(browser.staticTexts["caria"].waitForExistence(timeout: 5))

    let recentLocation = app.buttons["saved-location-PKPaneUITestFixture"]
    XCTAssertTrue(recentLocation.waitForExistence(timeout: 3))
    recentLocation.click()

    XCTAssertTrue(browser.staticTexts["report.txt"].waitForExistence(timeout: 5))
  }

  func testNavigatedLocalFolderIsAddedToRecentLocations() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let documents = browser.staticTexts["Documents"]
    XCTAssertTrue(documents.waitForExistence(timeout: 5))
    documents.doubleClick()

    XCTAssertTrue(browser.staticTexts["caria"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["saved-location-Documents"].waitForExistence(timeout: 3))
  }

  func testActionMenuTogglesCurrentLocalFolderFavorite() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let actionMenu = app.descendants(matching: .any)["provider-browser-action-menu"]
    XCTAssertTrue(actionMenu.waitForExistence(timeout: 6))

    actionMenu.click()
    hittableMenuItem(in: app, title: "お気に入りに追加").click()

    let favorite = app.buttons["saved-location-\(testFolderURL.lastPathComponent)"]
    XCTAssertTrue(favorite.waitForExistence(timeout: 3))
  }

  func testFolderContextMenuAddsLocalFolderToFavorites() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let documents = browser.staticTexts["Documents"]
    XCTAssertTrue(documents.waitForExistence(timeout: 5))

    documents.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    hittableMenuItem(in: app, title: "お気に入りに追加").click()

    XCTAssertTrue(app.buttons["saved-location-Documents"].waitForExistence(timeout: 3))
  }

  func testDraggingLocalFolderToFavoritesRegistersIt() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let documents = browser.staticTexts["Documents"]
    XCTAssertTrue(documents.waitForExistence(timeout: 5))
    let favorites = app.buttons["sidebar-section-favorites"]
    XCTAssertTrue(favorites.waitForExistence(timeout: 3))

    drag(documents, to: favorites)

    XCTAssertTrue(app.buttons["saved-location-Documents"].waitForExistence(timeout: 3))
  }

  func testSidebarLocationsIncludeFinderLocalEntries() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)

    XCTAssertTrue(app.buttons["sidebar-section-locations"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["sidebar-location-home"].exists)
    XCTAssertTrue(app.buttons["sidebar-location-network"].exists)
    XCTAssertTrue(app.buttons["sidebar-location-trash"].exists)
    XCTAssertTrue(
      app.staticTexts["sidebar-volume-capacity-/"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["iCloud"].exists)

    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let documents = browser.staticTexts["Documents"]
    let favorites = app.buttons["sidebar-section-favorites"]
    XCTAssertTrue(documents.waitForExistence(timeout: 5))
    XCTAssertTrue(favorites.exists)
    drag(documents, to: favorites)
    XCTAssertTrue(app.buttons["saved-location-Documents"].waitForExistence(timeout: 3))
  }

  func testSidebarSectionExpansionPersistsAcrossRelaunch() {
    let app = XCUIApplication()
    defer {
      if app.state != .notRunning {
        closeAndTerminate(app)
      }
    }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)

    XCTAssertTrue(app.buttons["sidebar-section-locations"].waitForExistence(timeout: 3))
    let home = app.buttons["sidebar-location-home"]
    XCTAssertTrue(home.exists)
    let locationsSection = app.buttons["sidebar-section-locations"]
    XCTAssertTrue(locationsSection.exists)
    locationsSection.click()
    expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: home)
    waitForExpectations(timeout: 3)
    closeAndTerminate(app)

    let relaunchedApp = XCUIApplication()
    defer { closeAndTerminate(relaunchedApp) }
    relaunchedApp.launchArguments = [
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    relaunchedApp.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(relaunchedApp, createsWindow: false)

    XCTAssertTrue(
      relaunchedApp.buttons["sidebar-section-locations"].waitForExistence(timeout: 3))
    XCTAssertFalse(relaunchedApp.buttons["sidebar-location-home"].exists)
    let restoredLocationsSection = relaunchedApp.buttons["sidebar-section-locations"]
    XCTAssertTrue(restoredLocationsSection.exists)
    restoredLocationsSection.click()

    XCTAssertTrue(
      relaunchedApp.buttons["sidebar-location-home"].waitForExistence(timeout: 3))
  }

  func testRecentLocationCanBeRemoved() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let documents = browser.staticTexts["Documents"]
    XCTAssertTrue(documents.waitForExistence(timeout: 5))
    documents.doubleClick()

    let recentLocation = app.buttons["saved-location-Documents"]
    XCTAssertTrue(recentLocation.waitForExistence(timeout: 3))
    recentLocation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    let removeMenuItem = app.menuItems["remove-recent-location-Documents"]
    XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 3))
    removeMenuItem.click()

    let disappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: recentLocation)
    wait(for: [disappearance], timeout: 3)
  }

  func testFavoriteLocationCanBeRemoved() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-favorite-location",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let favoriteLocation = app.buttons["saved-location-FavoriteFixture"]
    XCTAssertTrue(favoriteLocation.waitForExistence(timeout: 6))
    favoriteLocation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    let removeMenuItem = app.menuItems["remove-favorite-location-FavoriteFixture"]
    XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 3))
    removeMenuItem.click()

    let disappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: favoriteLocation)
    wait(for: [disappearance], timeout: 3)
  }

  func testRecentNASConnectionCanBeRemoved() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-recent-nas-connection",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let recentConnection = app.buttons["nas-recent-ui-test.local/testshare"]
    XCTAssertTrue(recentConnection.waitForExistence(timeout: 6))
    recentConnection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
    let removeMenuItem = app.menuItems["remove-recent-nas-connection-ui-test.local/testshare"]
    XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 3))
    removeMenuItem.click()

    let disappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: recentConnection)
    wait(for: [disappearance], timeout: 3)
  }

  func testRecentNetworkLocationUsesMountedProvider() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-network-saved-location",
      "-ui-test-nas-trash-unavailable",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))

    let recentLocation = app.buttons["saved-location-PKPaneUITestNetwork"]
    XCTAssertTrue(recentLocation.waitForExistence(timeout: 3))
    recentLocation.click()

    let report = browser.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    report.click()
    app.buttons["ゴミ箱へ移動"].firstMatch.click()

    XCTAssertFalse(app.staticTexts["ゴミ箱を利用できません"].waitForExistence(timeout: 1))
    XCTAssertFalse(report.waitForExistence(timeout: 5))
  }

  func testSFTPFirstConnectionPresentsTrustConfirmation() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_SFTP_HOST_KEY"] = "1"

    launch(app)
    let connection = app.buttons["tester@host-key-test.invalid:22"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    connection.click()

    let continueButton = app.buttons["action-button-1"]
    XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
    continueButton.click()

    guard app.buttons["閉じる"].waitForExistence(timeout: 6) else {
      XCTFail("SFTPブラウザが表示されません。\n\(app.debugDescription)")
      return
    }
    let breadcrumbs = app.scrollViews["provider-browser-breadcrumbs"]
    XCTAssertTrue(breadcrumbs.exists)
    XCTAssertEqual(breadcrumbs.label, "現在位置: /srv/projects")
    // 2ペインが既定のため、「1ペイン」ボタン(=現在2ペイン表示中であることを示す)が見える。
    XCTAssertTrue(app.buttons["1ペイン"].exists)
  }

  func testSFTPConnectionPreservesTwoPaneLayout() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_SFTP_HOST_KEY"] = "1"

    launch(app)
    let primaryList = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(primaryList.waitForExistence(timeout: 6))
    // 2ペインが既定のため、この時点で既にセカンダリ一覧が存在する。
    XCTAssertTrue(
      app.descendants(matching: .any)["provider-browser-list-secondary"]
        .waitForExistence(timeout: 3))

    let connection = app.buttons["tester@host-key-test.invalid:22"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 3))
    connection.click()
    XCTAssertTrue(app.buttons["action-button-1"].waitForExistence(timeout: 3))
    app.buttons["action-button-1"].click()

    XCTAssertTrue(primaryList.waitForExistence(timeout: 6))
    XCTAssertTrue(
      app.descendants(matching: .any)["provider-browser-list-secondary"]
        .waitForExistence(timeout: 3))
  }

  func testSFTPDisconnectDismissesActiveBrowser() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_SFTP_HOST_KEY"] = "1"

    launch(app)
    let connection = app.buttons["tester@host-key-test.invalid:22"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    connection.click()
    let continueButton = app.buttons["action-button-1"]
    XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
    continueButton.click()

    let breadcrumbs = app.scrollViews["provider-browser-breadcrumbs"]
    XCTAssertTrue(breadcrumbs.waitForExistence(timeout: 6))
    app.buttons["接続を解除"].firstMatch.click()

    XCTAssertTrue(breadcrumbs.waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["閉じる"].exists)
  }

  func testSFTPCopyToOppositePaneTransfersSelectedFile() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_SFTP_HOST_KEY"] = "1"

    launch(app)
    // 2ペインが既定のため、起動直後からローカルのプライマリ・セカンダリが揃っている。
    let secondaryList = app.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 6))

    // アクティブ(プライマリ)側でSFTP接続を開く。接続クリックはアクティブ側のペインだけを
    // 差し替え、反対側(セカンダリ)はローカルのまま維持される(2ペインファイラー標準の
    // 「アクティブ側のみ切替・反対側は転送元/転送先として保持」という仕様)。
    let connection = app.buttons["tester@host-key-test.invalid:22"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    connection.click()
    XCTAssertTrue(app.buttons["action-button-1"].waitForExistence(timeout: 3))
    app.buttons["action-button-1"].click()

    let primaryList = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(primaryList.waitForExistence(timeout: 6))
    XCTAssertTrue(primaryList.staticTexts["readme.txt"].waitForExistence(timeout: 5))

    // SFTP(プライマリ)からローカル(セカンダリ)へコピーする、実際の異種間転送の動線。
    app.buttons["provider-browser-pane-primary"].click()
    primaryList.staticTexts["readme.txt"].click()
    app.typeKey("c", modifierFlags: .command)
    app.buttons["provider-browser-pane-secondary"].click()
    app.typeKey("v", modifierFlags: .command)

    XCTAssertTrue(secondaryList.staticTexts["readme.txt"].waitForExistence(timeout: 5))
  }

  func testSFTPMultipleCopiesShowAllJobsAndTransferFiles() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_SFTP_HOST_KEY"] = "1"

    launch(app)
    // 2ペインが既定のため、起動直後からローカルのプライマリ・セカンダリが揃っている。
    let secondaryList = app.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 6))

    // アクティブ(プライマリ)側でSFTP接続を開く。反対側(セカンダリ)はローカルのまま。
    let connection = app.buttons["tester@host-key-test.invalid:22"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    connection.click()
    XCTAssertTrue(app.buttons["action-button-1"].waitForExistence(timeout: 3))
    app.buttons["action-button-1"].click()

    let primaryList = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(primaryList.waitForExistence(timeout: 6))
    XCTAssertTrue(primaryList.staticTexts["guide.txt"].waitForExistence(timeout: 5))

    // SFTP(プライマリ)からローカル(セカンダリ)へ、連続で2件コピーする。
    app.buttons["provider-browser-pane-primary"].click()
    primaryList.staticTexts["guide.txt"].click()
    app.typeKey("c", modifierFlags: .command)
    app.buttons["provider-browser-pane-secondary"].click()
    app.typeKey("v", modifierFlags: .command)

    app.buttons["provider-browser-pane-primary"].click()
    primaryList.staticTexts["readme.txt"].click()
    app.typeKey("c", modifierFlags: .command)
    app.buttons["provider-browser-pane-secondary"].click()
    app.typeKey("v", modifierFlags: .command)

    XCTAssertTrue(secondaryList.staticTexts["guide.txt"].waitForExistence(timeout: 5))
    XCTAssertTrue(secondaryList.staticTexts["readme.txt"].waitForExistence(timeout: 5))
  }

  // 2026-08-10解明: かつての失敗原因はペイン切替用の透明a11y要素(24x24、trailing寄せ)が
  // パンくずボタンに重なっており、XCUITestのclick()が下のパンくずを押して親フォルダへ
  // ナビゲートしていたこと。切替操作を一覧の余白クリック(全域切替)に変更して回避する。
  // a11y経由の切替(VoiceOver)が誤ナビゲーションになる実バグ自体は別途修正が必要。
  func testLocalDragAndDropTransfersFileToOppositePane() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let (_, primaryList, secondaryList) = prepareLocalTwoPaneTransferTest(app)

    let sourceRow = primaryList.staticTexts["report.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))

    // NSTableView.pasteboardWriterForRowによるドラッグアウトとFileListViewのacceptDropに
    // よるドロップインが実際のOSドラッグセッションを通じて既存のワークスペース転送経路
    // (FileWorkspaceModel.transferDroppedItems)へ接続されることを確認する(合成ペーストボード
    // 経由のCoordinator単体テストでは検証できない、実際のドラッグ操作そのものの動作)。
    // Option押下時は同一ボリューム内でもコピーを強制する。
    XCUIElement.perform(withKeyModifiers: .option) {
      drag(sourceRow, to: secondaryList)
    }

    XCTAssertTrue(secondaryList.staticTexts["report.txt"].waitForExistence(timeout: 5))
    // コピーなので元の場所にも残っている。
    XCTAssertTrue(primaryList.staticTexts["report.txt"].exists)
  }

  func testLocalDragAndDropMoveRemovesSourceFile() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let (_, primaryList, secondaryList) = prepareLocalTwoPaneTransferTest(app)

    let sourceRow = primaryList.staticTexts["delete-me.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))

    // 同一ボリューム内の素のドラッグは移動になる。
    drag(sourceRow, to: secondaryList)

    XCTAssertTrue(secondaryList.staticTexts["delete-me.txt"].waitForExistence(timeout: 5))
    // 移動なので元の場所からは消える。一覧更新のタイミング差を吸収するため消失を待つ。
    let sourceDisappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: primaryList.staticTexts["delete-me.txt"])
    wait(for: [sourceDisappearance], timeout: 5)
  }

  func testLocalDragAndDropCopiesFileToSidebarFavorite() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-favorite-location",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let sourceRow = browser.staticTexts["report.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
    let favorite = app.buttons["saved-location-FavoriteFixture"]
    XCTAssertTrue(favorite.waitForExistence(timeout: 3))

    XCUIElement.perform(withKeyModifiers: .option) {
      drag(sourceRow, to: favorite)
    }

    let copiedURL = testFolderURL.appending(path: "FavoriteFixture/report.txt")
    XCTAssertTrue(waitForFile(at: copiedURL, timeout: 5))
    favorite.click()
    XCTAssertTrue(browser.staticTexts["report.txt"].waitForExistence(timeout: 5))
  }

  /// 展開中の子項目をドラッグ元にし、未展開のフォルダ行へドロップすると、そのフォルダ内へ
  /// 既存の自動判定(同一ボリュームなので移動)で転送されることを実操作で確認する。
  /// doc/plans/2026-08-16-list-tree-expansion.md Step 3。
  func testListFolderRowDropMovesExpandedChildIntoFolder() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))

    let sourceDisclosure = browser.buttons["file-disclosure-TreeExpand"]
    XCTAssertTrue(sourceDisclosure.waitForExistence(timeout: 3))
    sourceDisclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    let sourceChild = browser.staticTexts["inner-file.txt"]
    XCTAssertTrue(sourceChild.waitForExistence(timeout: 5))

    let destinationFolder = browser.staticTexts["Documents"]
    XCTAssertTrue(destinationFolder.waitForExistence(timeout: 3))
    drag(sourceChild, to: destinationFolder)

    let sourceDisappearance = expectation(
      for: NSPredicate(format: "exists == false"), evaluatedWith: sourceChild)
    wait(for: [sourceDisappearance], timeout: 5)

    let destinationDisclosure = browser.buttons["file-disclosure-Documents"]
    XCTAssertTrue(destinationDisclosure.waitForExistence(timeout: 3))
    destinationDisclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(browser.staticTexts["inner-file.txt"].waitForExistence(timeout: 5))
  }

  /// カラム行をドラッグ元にし、別カラムのフォルダ行と背景を転送先にできることを確認する。
  /// 素のドラッグは同一ボリューム内なので移動となる。
  func testColumnDragAndDropMovesFileIntoFolderAndColumnBackground() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    let singlePaneButton = window.buttons["1ペイン"]
    XCTAssertTrue(singlePaneButton.waitForExistence(timeout: 3))
    singlePaneButton.click()
    app.typeKey("3", modifierFlags: .command)

    let browser = app.descendants(matching: .any)["provider-browser-column"]
    XCTAssertTrue(browser.waitForExistence(timeout: 5))
    var currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    var sourceFile = currentColumn.staticTexts["report.txt"]
    XCTAssertTrue(sourceFile.waitForExistence(timeout: 3))
    sourceFile.click()

    currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    sourceFile = currentColumn.staticTexts["report.txt"]
    let destinationFolder = currentColumn.staticTexts["Documents"]
    XCTAssertTrue(destinationFolder.waitForExistence(timeout: 3))
    drag(sourceFile, to: destinationFolder)

    let rootSourceURL = testFolderURL.appending(path: "report.txt")
    let childSourceURL = testFolderURL.appending(path: "Documents/report.txt")
    XCTAssertTrue(waitForFile(at: childSourceURL, sourceRemovedAt: rootSourceURL, timeout: 10))
    let sourceDisappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: browser.descendants(matching: .any)["file-browser-column-current"]
        .staticTexts["report.txt"])
    wait(for: [sourceDisappearance], timeout: 10)

    currentColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    let refreshedDestinationFolder = currentColumn.staticTexts["Documents"]
    XCTAssertTrue(refreshedDestinationFolder.waitForExistence(timeout: 3))
    refreshedDestinationFolder.click()
    var childColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    sourceFile = childColumn.staticTexts["report.txt"]
    XCTAssertTrue(sourceFile.waitForExistence(timeout: 5))
    sourceFile.click()

    // 現在カラムと直前の親を表す安定識別子を使い、選択後に座標も取り直す。
    childColumn = browser.descendants(matching: .any)["file-browser-column-current"]
    sourceFile = childColumn.staticTexts["report.txt"]
    let rootColumn = browser.descendants(matching: .any)["file-browser-column-parent"]
    XCTAssertTrue(rootColumn.waitForExistence(timeout: 3))
    let movedSourceCoordinate = sourceFile.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let rootBackgroundCoordinate = rootColumn.coordinate(
      withNormalizedOffset: CGVector(dx: 0.95, dy: 0.92))
    movedSourceCoordinate.press(forDuration: 0.4, thenDragTo: rootBackgroundCoordinate)

    XCTAssertTrue(waitForFile(at: rootSourceURL, sourceRemovedAt: childSourceURL, timeout: 10))
    let childFileDisappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: browser.descendants(matching: .any)["file-browser-column-current"]
        .staticTexts["report.txt"])
    wait(for: [childFileDisappearance], timeout: 10)
    XCTAssertTrue(rootColumn.staticTexts["report.txt"].waitForExistence(timeout: 5))
  }

  func testContextMenuCopyPasteTransfersFile() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    let primaryList = window.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(primaryList.waitForExistence(timeout: 6))
    let secondaryList = window.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 3))

    let primaryPane = window.buttons["provider-browser-pane-primary"]
    let secondaryPane = window.buttons["provider-browser-pane-secondary"]

    // セカンダリ側だけDocumentsへ移動し、プライマリ(ルート)と異なる場所にする
    // (同じ場所同士のコピーはエラーになるため)。
    activatePaneByClickingList(secondaryList)
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    secondaryList.staticTexts["Documents"].doubleClick()
    XCTAssertTrue(secondaryList.staticTexts["caria"].waitForExistence(timeout: 5))

    activatePaneByClickingList(primaryList)
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))
    let sourceRow = primaryList.staticTexts["report.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
    sourceRow.rightClick()
    hittableMenuItem(in: app, title: "コピー \"report.txt\"").click()

    activatePaneByClickingList(secondaryList)
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    // 項目の外(余白)を右クリックして背景メニューの「ペースト」を使う。
    secondaryList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
    hittableMenuItem(in: app, title: "ペースト").click()

    XCTAssertTrue(secondaryList.staticTexts["report.txt"].waitForExistence(timeout: 5))
    // コピーなので元の場所にも残っている。
    XCTAssertTrue(primaryList.staticTexts["report.txt"].exists)
  }

  func testContextMenuCutPasteMovesFile() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    let primaryList = window.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(primaryList.waitForExistence(timeout: 6))
    let secondaryList = window.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 3))

    let primaryPane = window.buttons["provider-browser-pane-primary"]
    let secondaryPane = window.buttons["provider-browser-pane-secondary"]

    activatePaneByClickingList(secondaryList)
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    secondaryList.staticTexts["Documents"].doubleClick()
    XCTAssertTrue(secondaryList.staticTexts["caria"].waitForExistence(timeout: 5))

    activatePaneByClickingList(primaryList)
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))
    let sourceRow = primaryList.staticTexts["delete-me.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
    sourceRow.rightClick()
    hittableMenuItem(in: app, title: "カット").click()

    activatePaneByClickingList(secondaryList)
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    secondaryList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
    hittableMenuItem(in: app, title: "ペースト").click()

    XCTAssertTrue(secondaryList.staticTexts["delete-me.txt"].waitForExistence(timeout: 5))
    // カット(移動)なので元の場所からは消えている。移動元・移動先の一覧更新は別々の
    // タイミングで起きるため、即時のexistsチェックではなく消失を待つ。
    let sourceDisappearance = expectation(
      for: NSPredicate(format: "exists == false"),
      evaluatedWith: primaryList.staticTexts["delete-me.txt"])
    wait(for: [sourceDisappearance], timeout: 5)
  }

  func testTransferDestinationSheetCopiesToOppositePane() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let (window, primaryList, secondaryList) = prepareLocalTwoPaneTransferTest(app)

    let primaryPane = window.buttons["provider-browser-pane-primary"]
    let secondaryPane = window.buttons["provider-browser-pane-secondary"]

    // セカンダリだけDocumentsへ移動し、宛先が現在地と別の場所になるようにする
    // (同一場所の宛先は理由付きで無効化されボタンにならないため)。
    XCTAssertTrue(secondaryList.staticTexts["caria"].waitForExistence(timeout: 5))

    activatePaneByClickingList(primaryList)
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))
    let sourceRow = primaryList.staticTexts["report.txt"]
    XCTAssertTrue(sourceRow.waitForExistence(timeout: 3))
    sourceRow.click()

    window.descendants(matching: .any)["provider-browser-action-menu"].click()
    hittableMenuItem(in: app, title: "コピー先を選択...").click()

    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 3))
    // 操作種別が文字で明示されていること(FR-010受け入れ条件)。
    XCTAssertTrue(sheet.staticTexts["コピー先を選択"].exists)
    XCTAssertTrue(
      sheet.buttons["provider-transfer-destination-other-folder"].waitForExistence(timeout: 3))
    // tabsセクションはカタログの先頭固定のため、タブ宛先の先頭が反対側ペイン。
    let destinationButton = sheet.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "provider-transfer-destination-tab-")
    ).firstMatch
    XCTAssertTrue(destinationButton.waitForExistence(timeout: 3))
    destinationButton.click()

    XCTAssertTrue(secondaryList.staticTexts["report.txt"].waitForExistence(timeout: 5))
    // コピーなので元の場所にも残る。
    XCTAssertTrue(primaryList.staticTexts["report.txt"].exists)
  }

  func testSFTPRenameChangesFileNameViaContextMenu() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_SFTP_HOST_KEY"] = "1"

    launch(app)
    let connection = app.buttons["tester@host-key-test.invalid:22"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    connection.click()
    XCTAssertTrue(app.buttons["action-button-1"].waitForExistence(timeout: 3))
    app.buttons["action-button-1"].click()

    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let readme = browser.staticTexts["readme.txt"]
    XCTAssertTrue(readme.waitForExistence(timeout: 5))
    readme.rightClick()
    app.menuItems["名前を変更"].click()
    let nameField = app.textFields["名前"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 3))

    // ベース名(拡張子を除く部分)の事前選択を検証する。RenameTextField(NSTextField.
    // becomeFirstResponder()自体をオーバーライドしフィールドエディタの選択確定経路に
    // 割り込む新方式)はTask 4時点の通知購読方式と異なり、実際にOSレベルで選択されている
    // 文字列をCmd+C経由でクリップボードへ読み取って検証する。
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    app.typeKey("c", modifierFlags: .command)
    XCTAssertEqual(pasteboard.string(forType: .string), "readme")

    app.typeKey("a", modifierFlags: .command)
    nameField.typeText("guide.txt")
    // app.buttons["変更"]はTouchBarのミラーボタンとウィンドウ内の実ボタンの両方に一致し
    // 曖昧になるため、ウィンドウ配下に絞って実ボタンだけを対象にする。
    app.windows.buttons["変更"].click()

    XCTAssertTrue(browser.staticTexts["guide.txt"].waitForExistence(timeout: 5))
  }

  func testClickToRenameEditsFileNameInline() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let reportRow = browser.staticTexts["report.txt"]
    XCTAssertTrue(reportRow.waitForExistence(timeout: 5))

    // 1回目のクリックで選択させる。ダブルクリック判定されない間隔を空けてから
    // 同じ行の名前を再クリックすると、標準的な遅延編集パターンでインライン編集が始まる。
    reportRow.click()
    pause(seconds: 1)
    reportRow.click()

    let nameField = app.descendants(matching: .any)["file-name-inline-edit"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 3))

    // ベース名(拡張子を除く部分)だけが事前選択されているため、そのままタイプすると
    // 拡張子は保持されたまま置き換わる。
    app.typeText("renamed-report")
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(browser.staticTexts["renamed-report.txt"].waitForExistence(timeout: 5))
    XCTAssertFalse(browser.staticTexts["report.txt"].exists)
  }

  func testInactivePaneRowClickDoesNotStartInlineRename() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 3))

    let primaryPane = window.buttons["provider-browser-pane-primary"]
    let secondaryPane = window.buttons["provider-browser-pane-secondary"]
    XCTAssertTrue(primaryPane.waitForExistence(timeout: 3))
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))

    let secondaryList = window.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 3))
    let secondaryDocuments = secondaryList.staticTexts["Documents"]
    XCTAssertTrue(secondaryDocuments.waitForExistence(timeout: 3))

    // クリックして選択+アクティブ化させる(選択が変化するクリックなのでリネーム候補にはならない)。
    secondaryDocuments.click()
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    pause(seconds: 1)

    // プライマリへ戻す。セカンダリの選択状態(Documents)はそのまま保持される。
    primaryPane.click()
    XCTAssertTrue(waitForLabel(of: primaryPane, toBecome: "左ペイン、操作対象"))
    pause(seconds: 1)

    // 非アクティブなセカンダリで、既に選択済みの行を再クリックする(切替のためのクリック)。
    // ペインは操作対象へ切り替わるが、インライン編集は始まってはならない。
    secondaryDocuments.click()
    XCTAssertTrue(waitForLabel(of: secondaryPane, toBecome: "右ペイン、操作対象"))
    pause(seconds: 1)

    XCTAssertFalse(app.descendants(matching: .any)["file-name-inline-edit"].exists)
  }

  func testSFTPExternalEditCreatesWorkingCopy() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-sftp-profile",
      "-ui-test-suppress-external-editor",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"
    app.launchEnvironment["PKPANE_UI_TEST_SFTP_HOST_KEY"] = "1"

    launch(app)
    let connection = app.buttons["tester@host-key-test.invalid:22"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    connection.click()
    XCTAssertTrue(app.buttons["action-button-1"].waitForExistence(timeout: 3))
    app.buttons["action-button-1"].click()

    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let readme = browser.staticTexts["readme.txt"]
    XCTAssertTrue(readme.waitForExistence(timeout: 5))
    readme.rightClick()
    app.menuItems["外部アプリで編集"].click()

    XCTAssertTrue(app.staticTexts["外部編集中: 1件"].waitForExistence(timeout: 5))
  }

  func testLocalZIPCompressionFromContextMenu() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let report = browser.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    report.rightClick()
    app.menuItems["ZIPに圧縮 \"report.txt\""].click()

    let archive = browser.staticTexts["report.txt.zip"]
    XCTAssertTrue(archive.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["ZIP処理をキャンセル"].waitForExistence(timeout: 3))
  }

  func testLocalZIPExtractionFromContextMenu() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-zip-fixture",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let archive = browser.staticTexts["archive.zip"]
    XCTAssertTrue(archive.waitForExistence(timeout: 5))
    archive.rightClick()
    app.menuItems["\"archive.zip\"を同名フォルダへ展開"].click()

    XCTAssertTrue(browser.staticTexts["archive"].waitForExistence(timeout: 5))
  }

  func testContextMenuExposesOpenWithAndCopyPathSubmenus() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let report = browser.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    report.rightClick()

    let openWithMenuItem = app.menuItems["このアプリケーションで開く"]
    XCTAssertTrue(openWithMenuItem.waitForExistence(timeout: 3))
    let copyPathMenuItem = app.menuItems["パスをコピー"]
    XCTAssertTrue(copyPathMenuItem.waitForExistence(timeout: 3))

    copyPathMenuItem.hover()
    let pathMenuItem = app.menuItems["パス"]
    XCTAssertTrue(pathMenuItem.waitForExistence(timeout: 3))

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pathMenuItem.click()

    let expectedPath = testFolderURL.appendingPathComponent("report.txt").path
    XCTAssertEqual(pasteboard.string(forType: .string), expectedPath)
  }

  func testContextMenuChooseCopyDestinationOpensDestinationSheet() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let report = browser.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    report.rightClick()

    // メニューバーのコマンドメニューにも同名項目があるため、右クリックメニューで
    // 実際にヒットテスト可能な方をhittableMenuItemで絞り込む。
    hittableMenuItem(in: app, title: "コピー先を選択…").click()

    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 3))
    XCTAssertTrue(sheet.staticTexts["コピー先を選択"].exists)
    XCTAssertTrue(
      sheet.buttons["provider-transfer-destination-other-folder"].waitForExistence(timeout: 3))
  }

  func testLocalHiddenFoldersCanBeShown() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    app.typeKey("j", modifierFlags: .command)
    let hiddenFilesToggle = app.checkBoxes["隠しファイルを表示"]
    XCTAssertTrue(hiddenFilesToggle.waitForExistence(timeout: 3))
    hiddenFilesToggle.click()
    app.buttons["閉じる"].click()

    XCTAssertTrue(browser.staticTexts[".hidden-folder"].waitForExistence(timeout: 5))
  }

  func testSelectedItemInfoIsAvailableFromKeyboard() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let report = browser.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    report.click()
    app.typeKey("i", modifierFlags: .command)

    XCTAssertTrue(app.staticTexts["情報を見る"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["名前"].exists)
    XCTAssertTrue(app.staticTexts["種類"].exists)
    XCTAssertTrue(app.staticTexts["サイズ"].exists)
    XCTAssertTrue(app.staticTexts["作成日"].exists)
    XCTAssertTrue(app.staticTexts["変更日"].exists)
    XCTAssertTrue(app.staticTexts["場所"].exists)
    XCTAssertTrue(app.staticTexts["タグ"].exists)
    XCTAssertTrue(app.staticTexts["権限"].exists)
    XCTAssertTrue(app.staticTexts["report.txt"].exists)
  }

  /// 2026-08-15 要望: 情報を見るダイアログの単一選択にプレビューサムネイル+名前ヘッダを
  /// 追加。サムネイル領域(内容自体は検証しない)と名前ヘッダの存在まで確認する。
  func testFileInfoDialogShowsThumbnailAndNameHeaderForSingleSelection() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let report = browser.staticTexts["report.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    report.click()
    app.typeKey("i", modifierFlags: .command)

    XCTAssertTrue(app.staticTexts["情報を見る"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.images["file-info-thumbnail"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["report.txt"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["書類"].waitForExistence(timeout: 3))
  }

  /// 2026-08-15 要望: 複数選択時に件数+判明分の合計サイズを表示する。
  func testFileInfoDialogShowsItemCountAndTotalSizeForMultipleSelection() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    let browser = enterMultiSelectFixtureFolder(app)

    browser.staticTexts["select-a.txt"].click()
    XCUIElement.perform(withKeyModifiers: .shift) {
      browser.staticTexts["select-c.txt"].click()
    }
    app.typeKey("i", modifierFlags: .command)

    XCTAssertTrue(app.staticTexts["3項目の情報"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["3項目"].waitForExistence(timeout: 3))
    // SwiftUIのプレーンなTextはAX上でlabelではなくvalueとして公開されるため、valueで絞り込む。
    let totalSizeText = app.staticTexts.matching(
      NSPredicate(format: "value BEGINSWITH %@", "合計サイズ"))
    XCTAssertTrue(totalSizeText.firstMatch.waitForExistence(timeout: 3))
  }

  /// 恒久UI要件: リストでファイルを1クリックすると、別ペインの詳細が同じ選択へ追従する。
  /// 繰り返し指摘された要件の防護テストなので、ユーザー承認なしに削除・スキップ化しない。
  func testDetailsInspectorFollowsSelectionAfterOpeningWithShortcut() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let report = browser.staticTexts["report.txt"]
    let deleteMe = browser.staticTexts["delete-me.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    XCTAssertTrue(deleteMe.waitForExistence(timeout: 5))

    app.typeKey("p", modifierFlags: [.command, .shift])
    let inspector = app.descendants(matching: .any)["details-inspector-pane"]
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    let detailsMenu = app.descendants(matching: .any)["provider-browser-details-inspector-toggle"]
    XCTAssertEqual(detailsMenu.value as? String, "オン")

    report.click()
    XCTAssertTrue(inspector.staticTexts["report.txt"].waitForExistence(timeout: 3))

    deleteMe.click()
    XCTAssertTrue(inspector.staticTexts["delete-me.txt"].waitForExistence(timeout: 3))
    XCTAssertFalse(inspector.staticTexts["report.txt"].exists)
  }

  /// 2026-08-16 要望: 詳細ペインは⌘⇧Pの再入力で閉じる((c)相当)。
  func testDetailsInspectorClosesWithKeyboardShortcut() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))

    app.typeKey("p", modifierFlags: [.command, .shift])
    let inspector = app.descendants(matching: .any)["details-inspector-pane"]
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))

    app.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertFalse(inspector.waitForExistence(timeout: 2))
  }

  /// 詳細ペインをツールバー・表示メニュー・⌘⇧Pから開閉できることを確認する。
  func testDetailsDisplayModeChangesFromToolbarMenu() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let toggle = app.descendants(matching: .any)["provider-browser-details-inspector-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 3))
    XCTAssertEqual(toggle.label, "詳細を表示")
    XCTAssertEqual(toggle.value as? String, "オフ")

    app.menuBars.menuBarItems["表示"].click()
    hittableMenuItem(in: app, title: "詳細を表示").click()
    let inspector = app.descendants(matching: .any)["details-inspector-pane"]
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    XCTAssertEqual(toggle.value as? String, "オン")

    app.menuBars.menuBarItems["表示"].click()
    hittableMenuItem(in: app, title: "詳細を表示").click()
    XCTAssertFalse(inspector.waitForExistence(timeout: 2))
    XCTAssertEqual(toggle.value as? String, "オフ")

    app.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    XCTAssertEqual(toggle.value as? String, "オン")

    app.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertFalse(inspector.waitForExistence(timeout: 2))
    XCTAssertEqual(toggle.value as? String, "オフ")

    toggle.click()
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    XCTAssertEqual(toggle.value as? String, "オン")
  }

  func testNASWithoutTrashUsesCancelAsPermanentDeleteDefault() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-nas-trash-unavailable",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    browser.staticTexts["report.txt"].click()
    let trashButton = app.buttons["ゴミ箱へ移動"].firstMatch
    XCTAssertTrue(trashButton.waitForExistence(timeout: 3))
    trashButton.click()
    XCTAssertTrue(app.staticTexts["ゴミ箱を利用できません"].waitForExistence(timeout: 3))

    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(browser.staticTexts["report.txt"].waitForExistence(timeout: 3))
  }

  func testNASContextMenuDeletesAllSelectedItems() {
    let app = XCUIApplication()
    defer { closeAndTerminate(app) }
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
      "-ui-test-nas-trash-unavailable",
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let report = browser.staticTexts["report.txt"]
    let deleteMe = browser.staticTexts["delete-me.txt"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    XCTAssertTrue(deleteMe.exists)

    report.click()
    app.typeKey("a", modifierFlags: .command)
    report.rightClick()
    // メニューバーのファイルメニューにも「ゴミ箱へ移動」があるため、単純なタイトル一致は
    // 曖昧になる。開いているコンテキストメニュー側(hittable)へ絞る。
    hittableMenuItem(in: app, title: "ゴミ箱へ移動").click()
    XCTAssertTrue(app.staticTexts["ゴミ箱を利用できません"].waitForExistence(timeout: 3))
    app.buttons["action-button-1"].click()

    XCTAssertFalse(report.waitForExistence(timeout: 5))
    XCTAssertFalse(deleteMe.waitForExistence(timeout: 5))
  }

  /// 複数選択テスト用に、名前順が決め打ちできる専用フォルダ(MultiSelect)まで移動し、
  /// プライマリ一覧(provider-browser-list)を返す。
  private func enterMultiSelectFixtureFolder(_ app: XCUIApplication) -> XCUIElement {
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let browser = app.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(browser.waitForExistence(timeout: 6))
    let multiSelectFolder = browser.staticTexts["MultiSelect"]
    XCTAssertTrue(multiSelectFolder.waitForExistence(timeout: 5))
    multiSelectFolder.doubleClick()
    XCTAssertTrue(browser.staticTexts["select-a.txt"].waitForExistence(timeout: 5))
    return browser
  }

  /// 行のisSelectedを検証するため、テーブル行要素を対象の静的テキストで絞り込む
  /// (testRestoredLocalFolderUsesCommonWorkspace等で使われている手法と同じ)。
  private func tableRow(in list: XCUIElement, staticText name: String) -> XCUIElement {
    list.descendants(matching: .tableRow).containing(.staticText, identifier: name).firstMatch
  }

  /// 要素のframe.widthが指定値より大きくなるまで待つ(アイコングリッドのセル拡大確認用)。
  private func waitForWidthIncrease(
    of element: XCUIElement, beyond originalWidth: CGFloat, timeout: TimeInterval = 3
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.frame.width > originalWidth { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return element.frame.width > originalWidth
  }

  /// カラム幅は左右どちらにも変更できるため、元の値から10pt以上変わるまで待つ。
  private func waitForWidthChange(
    of element: XCUIElement, from originalWidth: CGFloat, timeout: TimeInterval = 3
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if abs(element.frame.width - originalWidth) >= 10 { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return abs(element.frame.width - originalWidth) >= 10
  }

  /// D&Dの実行完了とアクセシビリティツリーの更新を分けて診断できるよう、まず実ファイルの
  /// 移動を待つ。画面反映は呼び出し元が続けて別途検証する。
  private func waitForFile(
    at destination: URL, sourceRemovedAt source: URL, timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: destination.path),
        !FileManager.default.fileExists(atPath: source.path)
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return FileManager.default.fileExists(atPath: destination.path)
      && !FileManager.default.fileExists(atPath: source.path)
  }

  private func waitForFile(at destination: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: destination.path) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return FileManager.default.fileExists(atPath: destination.path)
  }

  private func waitForLabel(of element: XCUIElement, toBecome label: String) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if element.label == label { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return element.label == label
  }

  /// テストフォルダにはDocuments(フォルダ)・caria-link(シンボリックリンク)も含まれ、
  /// これらのサイズはnil扱いのため昇順ソートで最小値扱いとなりa-size-small.txtより
  /// 手前に来る。そのため行インデックスをboundBy:0で決め打ちせず、注目する2項目間の
  /// 相対的な上下関係(frameのY座標)だけを確認する。
  private func waitForRowOrder(
    _ browser: XCUIElement, expectingBefore beforeName: String, after afterName: String,
    timeout: TimeInterval = 3
  ) -> Bool {
    let before = browser.staticTexts[beforeName]
    let after = browser.staticTexts[afterName]
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if before.exists, after.exists, before.frame.minY < after.frame.minY {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return before.exists && after.exists && before.frame.minY < after.frame.minY
  }

  /// クリック・トゥ・リネームの標準的な遅延編集パターン(NSEvent.doubleClickInterval分の
  /// 遅延)を検証するため、テスト駆動でも実時間を空ける必要がある箇所で使う。
  private func pause(seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  /// 指定したX座標で、周囲より暗い画素がツールバー高の何割連続しているかを返す。
  /// SplitView追従セパレータは細い縦線としてほぼ全高に現れるため、アイコンや文字の
  /// 局所的な画素とは比率で区別できる。
  private func verticalEdgeRatio(
    in screenshot: XCUIScreenshot,
    windowFrame: CGRect,
    screenX: CGFloat,
    toolbarBottomY: CGFloat
  ) throws -> Double {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
    let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height
    let localX = screenX - windowFrame.minX
    let toolbarHeight = toolbarBottomY - windowFrame.minY
    let firstPixelY = max(2, Int(4 * scaleY))
    let lastPixelY = min(bitmap.pixelsHigh - 3, Int((toolbarHeight - 4) * scaleY))
    guard lastPixelY > firstPixelY else {
      XCTFail("ツールバーの画素範囲を特定できませんでした")
      return 1
    }

    let centerPixelX = Int(localX * scaleX)
    let neighborDistance = max(4, Int(3 * scaleX))
    let scanRadius = max(2, Int(2 * scaleX))
    var maximumEdgeCount = 0
    let sampleCount = lastPixelY - firstPixelY + 1

    for offset in -scanRadius...scanRadius {
      let pixelX = centerPixelX + offset
      guard pixelX - neighborDistance >= 0,
        pixelX + neighborDistance < bitmap.pixelsWide
      else { continue }
      var edgeCount = 0
      for topOriginY in firstPixelY...lastPixelY {
        let pixelY = topOriginY
        let center = try luminance(in: bitmap, x: pixelX, y: pixelY)
        let left = try luminance(in: bitmap, x: pixelX - neighborDistance, y: pixelY)
        let right = try luminance(in: bitmap, x: pixelX + neighborDistance, y: pixelY)
        if ((left + right) / 2) - center > 0.035 {
          edgeCount += 1
        }
      }
      maximumEdgeCount = max(maximumEdgeCount, edgeCount)
    }
    return Double(maximumEdgeCount) / Double(sampleCount)
  }

  /// ツールバー下端付近で、周囲より暗い画素が横方向へ連続する割合を返す。
  private func horizontalEdgeRatio(
    in screenshot: XCUIScreenshot,
    windowFrame: CGRect,
    screenMinX: CGFloat,
    screenMaxX: CGFloat,
    toolbarBottomY: CGFloat
  ) throws -> Double {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
    let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height
    let firstPixelX = Int((screenMinX - windowFrame.minX + 12) * scaleX)
    let lastPixelX = Int((screenMaxX - windowFrame.minX - 12) * scaleX)
    let toolbarHeight = toolbarBottomY - windowFrame.minY
    // アクティブペインを示す青線はパンくずの上端にある。そこを避け、
    // 2pt上のツールバー境界だけを検査する。
    let centerPixelY = Int((toolbarHeight - 2) * scaleY)
    let neighborDistance = max(2, Int(scaleY))
    let scanRadius = 1
    guard lastPixelX > firstPixelX,
      centerPixelY - neighborDistance - scanRadius >= 0,
      centerPixelY + neighborDistance + scanRadius < bitmap.pixelsHigh
    else {
      XCTFail(
        "ツールバー下端の画素範囲を特定できませんでした: "
          + "window=\(windowFrame)、screenX=\(screenMinX)...\(screenMaxX)、"
          + "toolbarBottomY=\(toolbarBottomY)、pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)、"
          + "pixelX=\(firstPixelX)...\(lastPixelX)、pixelY=\(centerPixelY)")
      return 1
    }

    var maximumEdgeCount = 0
    let sampleCount = lastPixelX - firstPixelX + 1
    for offset in -scanRadius...scanRadius {
      let topOriginY = centerPixelY + offset
      let pixelY = topOriginY
      var edgeCount = 0
      for pixelX in firstPixelX...lastPixelX {
        let center = try luminance(in: bitmap, x: pixelX, y: pixelY)
        let above = try luminance(
          in: bitmap,
          x: pixelX,
          y: topOriginY - neighborDistance)
        let below = try luminance(
          in: bitmap,
          x: pixelX,
          y: topOriginY + neighborDistance)
        if ((above + below) / 2) - center > 0.035 {
          edgeCount += 1
        }
      }
      maximumEdgeCount = max(maximumEdgeCount, edgeCount)
    }
    return Double(maximumEdgeCount) / Double(sampleCount)
  }

  private func luminance(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> Double {
    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    return 0.2126 * color.redComponent
      + 0.7152 * color.greenComponent
      + 0.0722 * color.blueComponent
  }

  private func pixelColorDistance(
    in screenshot: XCUIScreenshot,
    windowFrame: CGRect,
    firstScreenPoint: CGPoint,
    secondScreenPoint: CGPoint
  ) throws -> Double {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
    let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height
    func color(at point: CGPoint) throws -> NSColor {
      let pixelX = Int((point.x - windowFrame.minX) * scaleX)
      let pixelY = Int((point.y - windowFrame.minY) * scaleY)
      return try XCTUnwrap(
        bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB))
    }

    let first = try color(at: firstScreenPoint)
    let second = try color(at: secondScreenPoint)
    let redDifference = first.redComponent - second.redComponent
    let greenDifference = first.greenComponent - second.greenComponent
    let blueDifference = first.blueComponent - second.blueComponent
    return sqrt(
      redDifference * redDifference
        + greenDifference * greenDifference
        + blueDifference * blueDifference)
  }

  /// 文字やアイコンの画素を背景色と誤認しないよう、横方向の複数点を比較して
  /// 背景同士になったサンプルを表す下位20%点の色距離を返す。
  private func backgroundColorDistance(
    in screenshot: XCUIScreenshot,
    windowFrame: CGRect,
    screenMinX: CGFloat,
    screenMaxX: CGFloat,
    firstScreenY: CGFloat,
    secondScreenY: CGFloat
  ) throws -> Double {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
    let scaleX = CGFloat(bitmap.pixelsWide) / windowFrame.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / windowFrame.height
    let firstPixelX = Int((screenMinX - windowFrame.minX + 12) * scaleX)
    let lastPixelX = Int((screenMaxX - windowFrame.minX - 12) * scaleX)
    let firstPixelY = Int((firstScreenY - windowFrame.minY) * scaleY)
    let secondPixelY = Int((secondScreenY - windowFrame.minY) * scaleY)
    let sampleStride = max(2, Int(4 * scaleX))
    guard firstPixelX < lastPixelX,
      (0..<bitmap.pixelsHigh).contains(firstPixelY),
      (0..<bitmap.pixelsHigh).contains(secondPixelY)
    else {
      XCTFail("背景色の画素範囲を特定できませんでした")
      return 1
    }

    var distances: [Double] = []
    for pixelX in stride(from: firstPixelX, through: lastPixelX, by: sampleStride) {
      guard
        let first = bitmap.colorAt(x: pixelX, y: firstPixelY)?.usingColorSpace(.deviceRGB),
        let second = bitmap.colorAt(x: pixelX, y: secondPixelY)?.usingColorSpace(.deviceRGB)
      else { continue }
      let redDifference = first.redComponent - second.redComponent
      let greenDifference = first.greenComponent - second.greenComponent
      let blueDifference = first.blueComponent - second.blueComponent
      distances.append(
        sqrt(
          redDifference * redDifference
            + greenDifference * greenDifference
            + blueDifference * blueDifference))
    }
    let sortedDistances = distances.sorted()
    return try XCTUnwrap(sortedDistances.dropFirst(sortedDistances.count / 5).first)
  }

  private func prepareLocalTwoPaneTransferTest(
    _ app: XCUIApplication
  ) -> (window: XCUIElement, primaryList: XCUIElement, secondaryList: XCUIElement) {
    app.launchArguments = [
      "-reset-folder-bookmark",
      "-ui-test-folder-path",
      testFolderURL.path,
    ]
    app.launchEnvironment["PKPANE_UI_TESTING"] = "1"

    launch(app)
    let window = app.windows.firstMatch
    let primaryList = window.descendants(matching: .any)["provider-browser-list"]
    XCTAssertTrue(primaryList.waitForExistence(timeout: 6))

    let secondaryList = window.descendants(matching: .any)["provider-browser-list-secondary"]
    XCTAssertTrue(secondaryList.waitForExistence(timeout: 3))

    let secondaryPaneButton = window.buttons["provider-browser-pane-secondary"]
    activatePaneByClickingList(secondaryList)
    // ペイン切替直後は一覧の再構築(アクセシビリティツリーの再構成)と競合しうるため、
    // 実際に操作対象へ切り替わったことを確認してから一覧を操作する。
    XCTAssertTrue(waitForLabel(of: secondaryPaneButton, toBecome: "右ペイン、操作対象"))
    let secondaryDocuments = secondaryList.staticTexts["Documents"]
    XCTAssertTrue(secondaryDocuments.waitForExistence(timeout: 3))
    // 空フォルダ(caria)まで移動すると一覧が0行になりNSTableViewがヒットテスト不可になるため、
    // 1階層(Documents、caria1件を含む)にとどめてドロップ先のテーブルに常に当たり判定を残す。
    secondaryDocuments.doubleClick()
    XCTAssertTrue(
      window.scrollViews["provider-browser-breadcrumbs-secondary"]
        .waitForExistence(timeout: 3))

    return (window, primaryList, secondaryList)
  }

  /// secondaryList自体を要素としてドラッグ先に指定すると当たり判定チェックで
  /// "Not hittable"となり失敗する(NSTableViewのクリップビュー階層に起因すると見られる、
  /// XCUITestの既知の弱点)。座標同士のドラッグ(XCUICoordinate.press)は当たり判定チェックを
  /// 経由しないため回避できる。
  private func drag(_ sourceRow: XCUIElement, to destinationList: XCUIElement) {
    let sourceCoordinate = sourceRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let destinationCoordinate = destinationList.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    sourceCoordinate.press(forDuration: 0.4, thenDragTo: destinationCoordinate)
  }

  /// ペイン切替は一覧の余白クリック(全域切替)で行う。ペイン切替用の透明a11y要素は
  /// パンくずボタンに重なっており、XCUITestのclick()がその座標にある下のパンくずを
  /// 押して親フォルダへナビゲートしてしまうため、a11y要素経由の切替は使わない。
  private func activatePaneByClickingList(_ list: XCUIElement) {
    list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).click()
  }

  /// 「コピー」「カット」「ペースト」等はメインメニューバーの標準編集メニューにも同名の
  /// 項目が存在するため、app.menuItems[title]は複数一致で失敗する。右クリックで開いた
  /// コンテキストメニューの項目だけが実際に画面上でヒットテスト可能(isHittable)なため、
  /// それで絞り込む。
  private func hittableMenuItem(
    in app: XCUIApplication, title: String, timeout: TimeInterval = 3
  ) -> XCUIElement {
    let matches = app.menuItems.matching(identifier: title)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      for index in 0..<matches.count {
        let candidate = matches.element(boundBy: index)
        if candidate.exists, candidate.isHittable {
          return candidate
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return app.menuItems[title]
  }

  private func waitForWindowCount(of app: XCUIApplication, toExceed count: Int) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if app.windows.count > count { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return app.windows.count > count
  }

  private func launch(_ app: XCUIApplication, createsWindow: Bool = true) {
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES",
      "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    app.launch()
    app.activate()
    if createsWindow {
      app.typeKey("n", modifierFlags: .command)
    }
  }

  private func closeAndTerminate(_ app: XCUIApplication) {
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
  }

}
