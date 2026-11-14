import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "BHE"

    RegisterGeneratedPlugins(registry: flutterViewController)

    let dialogChannel = FlutterMethodChannel(
      name: "bhe/file_dialog",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    dialogChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "preparePanel":
        NSApp.activate(ignoringOtherApps: true)
        self?.makeKeyAndOrderFront(nil)
        result(true)
      case "refocusPanel":
        // file_selector presents an attached sheet; it owns the panel lifetime.
        let panel = (self?.attachedSheet as? NSSavePanel)
          ?? NSApp.windows.compactMap { $0 as? NSSavePanel }.last { $0.isVisible }
        guard let panel else { result(false); return }
        NSApp.activate(ignoringOtherApps: true)
        self?.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
