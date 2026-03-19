import Cocoa
import Combine

// MARK: - ファイル状態の管理
// ObservableObject: 値が変わるとSwiftUIのUIが自動更新される仕組み
class FileState: ObservableObject {
    @Published var currentFileURL: URL? = nil
}

// MARK: - AppDelegate
// macOSで「このアプリで開く」やドラッグ&ドロップでファイルを受け取るために必要
class AppDelegate: NSObject, NSApplicationDelegate {
    let fileState = FileState()

    // アプリが起動済み、または起動時にファイルを開いた時に呼ばれる
    func application(_ application: NSApplication, open urls: [URL]) {
        if let xmlURL = urls.first(where: { $0.pathExtension.lowercased() == "xml" }) {
            fileState.currentFileURL = xmlURL

            // ウィンドウが表示されていない場合（コールドスタート時）にアクティベート
            DispatchQueue.main.async {
                if NSApp.windows.filter({ $0.isVisible }).isEmpty {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 新しいウィンドウが生成されるたびにタブ設定を適用
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        configureWindowTabs()
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        configureWindowTabs()
    }

    /// 全ウィンドウにタブモードを設定（同じtabbingIdentifierを持つウィンドウが自動的にタブグループ化される）
    private func configureWindowTabs() {
        for window in NSApp.windows {
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "NenkinXMLViewer"
        }
    }

    // 全ウィンドウを閉じたらアプリを終了
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
