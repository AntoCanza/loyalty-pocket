import CoreFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var originalBrightness: CGFloat?
  private weak var brightenedScreen: UIScreen?
  private var bluetoothSync: LoyaltyBluetoothSync?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      bluetoothSync = LoyaltyBluetoothSync(
        messenger: controller.binaryMessenger, launchOptions: launchOptions
      )
      let channel = FlutterMethodChannel(
        name: "loyalty_pocket/screen_brightness",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "setBarcodeVisible" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let visible = call.arguments as? NSNumber,
              CFGetTypeID(visible) == CFBooleanGetTypeID() else {
          result(FlutterError(code: "invalid_argument", message: "Expected a boolean.", details: nil))
          return
        }
        self?.setBarcodeVisible(visible.boolValue)
        result(nil)
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(restoreBrightnessOnResign(_:)),
      name: UIApplication.willResignActiveNotification,
      object: application
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func setBarcodeVisible(_ visible: Bool) {
    guard visible else {
      restoreBrightness()
      return
    }
    guard originalBrightness == nil, UIApplication.shared.applicationState == .active else {
      return
    }
    let screen = window?.windowScene?.screen ?? UIScreen.main
    originalBrightness = screen.brightness
    brightenedScreen = screen
    screen.brightness = 1
  }

  @objc private func restoreBrightnessOnResign(_ notification: Notification) {
    restoreBrightness()
  }

  private func restoreBrightness() {
    if let originalBrightness {
      brightenedScreen?.brightness = originalBrightness
    }
    originalBrightness = nil
    brightenedScreen = nil
  }
}
