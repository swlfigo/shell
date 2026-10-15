import UIKit
import TermesKit

@main
final class MobileAppDelegate: UIResponder, UIApplicationDelegate {
  private(set) var workspace: MobileWorkspace!

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

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene,
          let app = UIApplication.shared.delegate as? MobileAppDelegate else { return }
    let window = UIWindow(windowScene: scene)
    window.tintColor = .systemTeal
    window.rootViewController = MobileRootController(workspace: app.workspace)
    self.window = window
    window.makeKeyAndVisible()
  }

  func sceneWillResignActive(_ scene: UIScene) { window?.endEditing(true) }
}
