import SwiftUI

// MARK: - メインのビュー
struct ContentView: View {
    // AppDelegateから渡されるファイル状態を受け取る
    @EnvironmentObject var fileState: FileState

    // WebViewの操作を管理するコーディネーター
    @StateObject private var coordinator = WebViewCoordinator()

    // 新しいウィンドウ（タブ）を開くための環境変数
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // WKWebViewをSwiftUIに埋め込む
        WebViewWrapper(coordinator: coordinator)
            .onAppear {
                // ビューが表示されたらHTMLを読み込む
                coordinator.loadViewer()

                // ドラッグ&ドロップでファイルを受け取った時の処理
                coordinator.onFileDropped = { url in
                    fileState.currentFileURL = url
                }

                // リンクをクリックした時に新しいタブで開く
                coordinator.onOpenInNewTab = { [openWindow] url in
                    openWindow(id: "file-viewer", value: url)
                }
            }
            // fileStateの変化を監視（ドラッグ&ドロップ、2回目以降の「このアプリで開く」、コールドスタート含む）
            // initial: true により、初期値がnilでない場合もクロージャが実行される
            .onChange(of: fileState.currentFileURL, initial: true) { _, newURL in
                if let url = newURL {
                    coordinator.afterViewerLoaded {
                        coordinator.loadXMLFile(url: url)
                    }
                }
            }
            // ウィンドウタイトルにファイル名を表示
            .navigationTitle(windowTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coordinator.printContent()
                    } label: {
                        Label("印刷", systemImage: "printer")
                    }
                    .help("印刷 / PDF保存 (⌘P)")
                    .disabled(fileState.currentFileURL == nil)
                }
            }
            // Cmd+P ショートカット対応：アクティブウィンドウのみ印刷を実行
            .onReceive(NotificationCenter.default.publisher(for: .printRequested)) { _ in
                guard fileState.currentFileURL != nil,
                      coordinator.webView.window?.isKeyWindow == true else { return }
                coordinator.printContent()
            }
    }

    // ウィンドウタイトルの計算
    private var windowTitle: String {
        if let url = fileState.currentFileURL {
            return "年金機構 XML ビューア — \(url.lastPathComponent)"
        }
        return "年金機構 XML ビューア"
    }
}

// MARK: - リンクから開かれたファイルを表示するビュー
/// WindowGroup(for: URL.self) から呼ばれ、新しいタブでファイルを表示する
struct FileTabContentView: View {
    let fileURL: Binding<URL?>
    @StateObject private var coordinator = WebViewCoordinator()
    @Environment(\.openWindow) private var openWindow
    init(fileURL: Binding<URL?>) {
        self.fileURL = fileURL
    }

    var body: some View {
        WebViewWrapper(coordinator: coordinator)
            .onAppear {
                coordinator.loadViewer()

                // このタブ内でさらにリンクをクリックした場合も新タブで開く
                coordinator.onOpenInNewTab = { [openWindow] url in
                    openWindow(id: "file-viewer", value: url)
                }
            }
            .onChange(of: fileURL.wrappedValue, initial: true) { _, newURL in
                if let url = newURL {
                    coordinator.afterViewerLoaded {
                        loadURL(url)
                    }
                }
            }
            .navigationTitle(tabTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coordinator.savePDF()
                    } label: {
                        Label("名前を付けて保存", systemImage: "square.and.arrow.down")
                    }
                    .help("PDFファイルを保存")
                    .disabled(coordinator.currentPDFURL == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coordinator.printContent()
                    } label: {
                        Label("印刷", systemImage: "printer")
                    }
                    .help("印刷 / PDF保存 (⌘P)")
                    .disabled(fileURL.wrappedValue == nil)
                }
            }
            // Cmd+P ショートカット対応：アクティブウィンドウのみ印刷を実行
            .onReceive(NotificationCenter.default.publisher(for: .printRequested)) { _ in
                guard fileURL.wrappedValue != nil,
                      coordinator.webView.window?.isKeyWindow == true else { return }
                coordinator.printContent()
            }
    }

    /// URLの種類に応じてWebViewにコンテンツを読み込む
    private func loadURL(_ url: URL) {
        if let scheme = url.scheme, ["http", "https"].contains(scheme) {
            // 外部URLはWebViewで直接表示
            coordinator.loadWebURL(url: url)
        } else {
            // ローカルファイル（xml/csv/pdf）はviewer.htmlまたはWKWebViewで表示
            coordinator.loadFileInCurrentView(url: url)
        }
    }

    private var tabTitle: String {
        if let url = fileURL.wrappedValue {
            if let scheme = url.scheme, ["http", "https"].contains(scheme) {
                return url.host ?? url.absoluteString
            }
            return url.lastPathComponent
        }
        return "Document"
    }
}


