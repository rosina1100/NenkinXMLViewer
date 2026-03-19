import SwiftUI

// MARK: - 印刷通知名
extension Notification.Name {
    static let printRequested = Notification.Name("printRequested")
}

// MARK: - アプリのエントリーポイント
// @main: このstructがアプリの起動地点であることを示す
@main
struct NenkinXMLViewerApp: App {
    // AppDelegateを接続（ファイルの「このアプリで開く」を処理するため）
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // AppDelegateが持つfileStateを全画面で共有
                .environmentObject(appDelegate.fileState)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 720)
        .commands {
            CommandGroup(replacing: .printItem) {
                Button("印刷…") {
                    NotificationCenter.default.post(name: .printRequested, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
            }
        }

        // リンクから開くファイル用のウィンドウ（macOSタブとしてグループ化される）
        // handlesExternalEvents(matching: []) で「このアプリで開く」等の外部イベントでは
        // このWindowGroupが選択されないようにする
        WindowGroup("Document", id: "file-viewer", for: URL.self) { $fileURL in
            FileTabContentView(fileURL: $fileURL)
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 720)
    }
}
