import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    
    let audioChannel = FlutterMethodChannel(
      name: "cloud_centryvox.ios.audio",
      binaryMessenger: controller.binaryMessenger
    )
    
    audioChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "isSpeakerOn":
        let isSpeakerOn = self?.checkSpeakerMode() ?? false
        result(isSpeakerOn)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func checkSpeakerMode() -> Bool {
    let audioSession = AVAudioSession.sharedInstance()
    let currentRoute = audioSession.currentRoute
    
    for output in currentRoute.outputs {
      switch output.portType {
      case .builtInSpeaker:
        return true
      case .builtInReceiver, .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
        return false
      default:
        continue
      }
    }
    
    return false
  }
}
