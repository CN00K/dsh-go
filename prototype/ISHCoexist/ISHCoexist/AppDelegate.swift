//  AppDelegate.swift
//  ISHCoexist — Stage 1 coexistence prototype
//
//  Classic (non-scene) UIKit lifecycle: no SceneDelegate, no UIScene
//  manifest in Info.plist. The window's root is the test table.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: ViewController())
        window.makeKeyAndVisible()
        self.window = window
        NSLog("ISHCoexist: launched (stage 1 prototype)")
        return true
    }
}
