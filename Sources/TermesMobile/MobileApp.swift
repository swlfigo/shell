import UIKit
import TermesKit

@main
final class MobileAppDelegate: UIResponder, UIApplicationDelegate {
  private(set) var workspace: MobileWorkspace!
  private var sceneWorkspaces: [String: MobileWorkspace] = [:]

  func workspace(for session: UISceneSession) -> MobileWorkspace {
    if let existing = sceneWorkspaces[session.persistentIdentifier] { return existing }
    let savedID = (session.userInfo?["workspaceID"] as? String).flatMap(UUID.init(uuidString:))
    let value: MobileWorkspace
    if !sceneWorkspaces.values.contains(where: { $0 === workspace }), savedID == workspace.windowID || savedID == nil && sceneWorkspaces.isEmpty {
      value = workspace
    } else { value = MobileWorkspace(sharing: workspace, windowID: savedID ?? UUID()) }
    session.userInfo = ["workspaceID": value.windowID.uuidString]
    sceneWorkspaces[session.persistentIdentifier] = value
    return value
  }

  func otherWorkspaces(than current: MobileWorkspace) -> [MobileWorkspace] {
    sceneWorkspaces.values.filter { $0 !== current }.sorted { $0.windowID.uuidString < $1.windowID.uuidString }
  }

  func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    for scene in sceneSessions {
      if let value = sceneWorkspaces.removeValue(forKey: scene.persistentIdentifier) { value.discardWindow() }
      else if let id = (scene.userInfo?["workspaceID"] as? String).flatMap(UUID.init(uuidString:)) {
        MobileWorkspace(sharing: workspace, windowID: id).discardWindow()
      }
    }
  }

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    if environment["TERMES_UI_TESTING"] == "1" {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Termes-UITests", isDirectory: true)
      if environment["TERMES_UI_TEST_RESET"] == "1" { try? FileManager.default.removeItem(at: directory) }
      workspace = MobileWorkspace(directory: directory,
        secrets: KeychainSecretStore(service: "com.termes.ui-tests.credentials"))
      return true
    }
    #endif
    workspace = MobileWorkspace()
    return true
  }

  func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Termes", sessionRole: connectingSceneSession.role)
    configuration.delegateClass = MobileSceneDelegate.self
    return configuration
  }
}

final class MobileSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var workspace: MobileWorkspace?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene,
          let app = UIApplication.shared.delegate as? MobileAppDelegate else { return }
    let window = UIWindow(windowScene: scene)
    let workspace = app.workspace(for: session)
    self.workspace = workspace
    window.tintColor = .systemTeal
    window.rootViewController = MobileRootController(workspace: workspace)
    self.window = window
    window.makeKeyAndVisible()
  }

  func sceneWillResignActive(_ scene: UIScene) { window?.endEditing(true) }
  func sceneDidEnterBackground(_ scene: UIScene) {
    workspace?.persistWorkspace()
  }
}
