import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var originalBrightness: CGFloat?
  private weak var brightenedScreen: UIScreen?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(raiseBrightness(_:)),
      name: UIApplication.didBecomeActiveNotification,
      object: application
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(restoreBrightness(_:)),
      name: UIApplication.willResignActiveNotification,
      object: application
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func raiseBrightness(_ notification: Notification) {
    guard originalBrightness == nil else { return }
    let screen = window?.windowScene?.screen ?? UIScreen.main
    originalBrightness = screen.brightness
    brightenedScreen = screen
    screen.brightness = 1
  }

  @objc private func restoreBrightness(_ notification: Notification) {
    if let originalBrightness {
      brightenedScreen?.brightness = originalBrightness
    }
    originalBrightness = nil
    brightenedScreen = nil
  }
}
