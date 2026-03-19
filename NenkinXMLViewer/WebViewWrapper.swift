import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

// MARK: - ドラッグ&ドロップを受け付ける透明オーバーレイ
// WKWebView は内部ビュー階層がドラッグイベントを横取りするため、
// WKWebView の上に透明な NSView を重ねてドロップを受け取る
class DropOverlayView: NSView {
    var onFileDrop: ((URL) -> Void)?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 通常のマウスイベント（クリック、スクロール）はWKWebViewに透過させるが、
    // ドラッグ中は自身を返してドロップを受け付ける
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isDragging {
            return self
        }
        return nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if hasXMLFile(in: sender) {
            isDragging = true
            return .copy
        }
        return []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDragging = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragging = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDragging = false

        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else {
            return false
        }

        if let xmlURL = items.first(where: { $0.pathExtension.lowercased() == "xml" }) {
            onFileDrop?(xmlURL)
            return true
        }
        return false
    }

    private func hasXMLFile(in info: NSDraggingInfo) -> Bool {
        guard let items = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else {
            return false
        }
        return items.contains { $0.pathExtension.lowercased() == "xml" }
    }
}

// MARK: - WKWebView を SwiftUI で使うためのラッパー
// NSViewRepresentable: AppKit の NSView を SwiftUI に埋め込む仕組み
// WKWebView + 透明オーバーレイを含むコンテナビューを返す
struct WebViewWrapper: NSViewRepresentable {
    let coordinator: WebViewCoordinator

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        // WKWebView をコンテナに追加
        let webView = coordinator.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        // WKWebViewのドラッグ登録を解除して、オーバーレイがドロップを受け取るようにする
        webView.unregisterDraggedTypes()
        container.addSubview(webView)

        // 透明オーバーレイをWKWebViewの上に追加
        let overlay = DropOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onFileDrop = { [weak coordinator] url in
            coordinator?.onFileDropped?(url)
        }
        container.addSubview(overlay)

        // 両方ともコンテナいっぱいに広げる
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI側からの更新は不要（coordinatorが管理する）
    }
}

// MARK: - WebView の操作をすべて管理するクラス
class WebViewCoordinator: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    /// ドロップされたXMLファイルのURLを外部に通知するコールバック
    var onFileDropped: ((URL) -> Void)?

    /// リンクをクリックした時に新しいタブで開くためのコールバック
    var onOpenInNewTab: ((URL) -> Void)?

    /// viewer.html の読み込み完了フラグ
    private var isViewerLoaded = false

    /// viewer読み込み完了時に実行するコールバック（キュー）
    private var pendingAfterViewerLoaded: [() -> Void] = []

    /// 現在アクセス中のディレクトリURL（セキュリティスコープ解放用）
    private var accessedDirectoryURL: URL?

    /// 現在表示中のPDFファイルのURL（保存機能用）
    @Published var currentPDFURL: URL?

    /// viewer.html の読み込み完了後にアクションを実行する
    /// 既に読み込み済みなら即実行、未完了ならキューに追加
    func afterViewerLoaded(_ action: @escaping () -> Void) {
        if isViewerLoaded {
            action()
        } else {
            pendingAfterViewerLoaded.append(action)
        }
    }

    override init() {
        // WKWebViewの設定
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()

        // JavaScript → Swift の通信チャネルを登録
        // JSから window.webkit.messageHandlers.openFile.postMessage(...) で呼べる
        userContent.add(WebViewCoordinator.leakyHandler(), name: "openFile")
        config.userContentController = userContent

        // ローカルファイルへのアクセスを許可
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        // メッセージハンドラに自分を設定
        userContent.removeScriptMessageHandler(forName: "openFile")
        userContent.add(self, name: "openFile")

        // デリゲートを設定（XSL変換後のリンククリックをインターセプト）
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// NSSavePanelでPDFファイルを保存する
    func savePDF() {
        guard let sourceURL = currentPDFURL else { return }

        // macOSのウィンドウ自動タブ化を一時的に無効にする
        // これがないとNSSavePanelがメインウィンドウのタブとして表示されてしまう
        let previousTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = false

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true
        // ダイアログの初期サイズを標準的なサイズに設定
        panel.setContentSize(NSSize(width: 500, height: 400))

        let response = panel.runModal()
        if response == .OK, let destURL = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } catch {
                print("PDF保存エラー: \(error.localizedDescription)")
            }
        }

        // ウィンドウ自動タブ化の設定を復元
        NSWindow.allowsAutomaticWindowTabbing = previousTabbing
    }

    // メモリリーク防止用のラッパー
    // WKUserContentController は handler を強参照するため、
    // 初期化時は一時的なダミーを使い、後で差し替える
    private class LeakyHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ uc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {}
    }
    private static func leakyHandler() -> WKScriptMessageHandler {
        return LeakyHandler()
    }

    // MARK: - 外部URLをWebViewで読み込む
    func loadWebURL(url: URL) {
        currentPDFURL = nil
        webView.load(URLRequest(url: url))
    }

    // MARK: - viewer.html を読み込む
    func loadViewer() {
        // Bundleからviewer.htmlを探す
        guard let htmlURL = Bundle.main.url(forResource: "viewer", withExtension: "html") else {
            print("ERROR: viewer.html が Bundle に見つかりません")
            return
        }
        // ローカルHTMLをロード（同ディレクトリ内のリソースもアクセス可能にする）
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    // MARK: - XMLファイルを読み込んでWebViewに渡す
    func loadXMLFile(url: URL) {
        currentPDFURL = nil
        let directory = url.deletingLastPathComponent()

        // サンドボックス対応: XMLファイルの親ディレクトリへのアクセスを取得
        // これにより同フォルダ内のXSLファイルやCSVファイルも読み込める
        startAccessingDirectory(directory)

        // 1. XMLファイルを読み込む（エンコーディング自動判定）
        guard let xmlContent = readTextFile(url: url) else {
            print("ERROR: XMLファイルを読めませんでした: \(url.path)")
            return
        }

        // 2. XML内のXSL参照を探す → 同フォルダから直接読み込み
        let xslFileName = extractXSLReference(from: xmlContent)
        var xslContent: String? = nil

        if let xslFileName = xslFileName {
            let xslURL = directory.appendingPathComponent(xslFileName)
            xslContent = readTextFile(url: xslURL)
        }

        // 3. JavaScriptに渡す
        sendToJS(xmlContent: xmlContent, xslContent: xslContent, fileName: url.lastPathComponent, dirPath: directory.path)
    }

    /// JavaScriptにXML/XSLデータを送信
    private func sendToJS(xmlContent: String, xslContent: String?, fileName: String, dirPath: String) {
        let xmlBase64 = Data(xmlContent.utf8).base64EncodedString()
        let xslBase64 = xslContent.map { Data($0.utf8).base64EncodedString() } ?? ""

        let js = "receiveFileFromSwift('\(xmlBase64)', '\(xslBase64)', '\(escapeJS(fileName))', '\(escapeJS(dirPath))');"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("JS実行エラー: \(error)")
            }
        }
    }

    // MARK: - XML内の <?xml-stylesheet href="xxx.xsl"?> を抽出
    private func extractXSLReference(from xml: String) -> String? {
        let pattern = #"<\?xml-stylesheet[^?]*href="([^"]+\.xsl)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    // MARK: - エンコーディングを自動判定してテキストファイルを読み込む
    // XML宣言の encoding 属性を参照し、Shift_JIS等にも対応する
    private func readTextFile(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // まずバイト列からXML宣言のencodingを探す（ASCII互換部分で読める）
        let encoding = detectEncoding(from: data)

        if let content = String(data: data, encoding: encoding) {
            return content
        }
        // フォールバック: UTF-8 → Shift_JIS の順で試行
        if encoding != .utf8, let content = String(data: data, encoding: .utf8) {
            return content
        }
        let shiftJIS = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("Shift_JIS" as CFString)
        ))
        return String(data: data, encoding: shiftJIS)
    }

    // バイト列からXML宣言の encoding="..." を検出してSwiftのエンコーディングに変換
    private func detectEncoding(from data: Data) -> String.Encoding {
        // 先頭200バイト程度をASCIIとして読み、encoding宣言を探す
        let headerSize = min(data.count, 200)
        let header = String(data: data.prefix(headerSize), encoding: .ascii) ?? ""

        let pattern = #"encoding=[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else {
            return .utf8
        }

        let encodingName = String(header[range]).lowercased()

        switch encodingName {
        case "shift_jis", "shift-jis", "sjis", "x-sjis":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding("Shift_JIS" as CFString)
            ))
        case "euc-jp":
            return .japaneseEUC
        case "iso-2022-jp":
            return .iso2022JP
        case "utf-16", "utf-16le", "utf-16be":
            return .utf16
        default:
            return .utf8
        }
    }

    // JavaScript文字列のエスケープ
    private func escapeJS(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - サンドボックス対応: ディレクトリへのアクセスを開始
    /// XMLファイルの親ディレクトリへのセキュリティスコープアクセスを取得する
    /// これにより同フォルダ内のXSL/CSVなどの関連ファイルも読み込み可能になる
    private func startAccessingDirectory(_ directory: URL) {
        // 前回アクセスしていたディレクトリがあれば解放
        if let previous = accessedDirectoryURL {
            previous.stopAccessingSecurityScopedResource()
        }
        accessedDirectoryURL = directory
        _ = directory.startAccessingSecurityScopedResource()
    }

    // MARK: - target="_blank" リンクのインターセプト（WKUIDelegate）
    // XSLで生成されるリンクは target="_blank" のため、新しいウィンドウを開こうとする。
    // WKUIDelegate で捕捉し、新しいタブで開く。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let ext = url.pathExtension.lowercased()
            if ext == "xml" || ext == "csv" || ext == "pdf" {
                handleLinkedFile(url: url)
            } else if let scheme = url.scheme, ["http", "https"].contains(scheme) {
                // 外部URLも新しいタブで開く
                onOpenInNewTab?(url)
            } else {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }

    // MARK: - 通常リンクのインターセプト（WKNavigationDelegate）
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 初回ページ読み込み等は通常通り許可
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let ext = url.pathExtension.lowercased()
        if ext == "xml" || ext == "csv" || ext == "pdf" {
            decisionHandler(.cancel)
            handleLinkedFile(url: url)
        } else if let scheme = url.scheme, ["http", "https"].contains(scheme) {
            // 外部URLも新しいタブで開く
            decisionHandler(.cancel)
            onOpenInNewTab?(url)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: - ページ読み込み完了（WKNavigationDelegate）
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isViewerLoaded {
            isViewerLoaded = true
            // 待機中のアクションを実行
            let pending = pendingAfterViewerLoaded
            pendingAfterViewerLoaded.removeAll()
            for action in pending {
                action()
            }
        }
    }

    /// XSL変換後のリンクから取得したURLでファイルを開く
    private func handleLinkedFile(url: URL) {
        // XSL変換後のリンクは相対パスで生成されるため、
        // ファイル名だけを取り出して currentDirPath と組み合わせる必要がある
        // ただしWKWebView内のリンクはfile://ベースのURLになっている場合がある
        let fileName = url.lastPathComponent

        // JS側のcurrentDirPathを取得して組み合わせる
        webView.evaluateJavaScript("currentDirPath") { [weak self] result, error in
            guard let self = self,
                  let dirPath = result as? String, !dirPath.isEmpty else {
                // dirPathが取れない場合はURLをそのまま試す
                self?.openFile(url: url)
                return
            }

            let directory = URL(fileURLWithPath: dirPath)
            let fileURL = directory.appendingPathComponent(fileName)
            self.openFile(url: fileURL)
        }
    }

    /// ファイルの種類に応じて読み込み処理を実行
    private func openFile(url: URL) {
        // 新しいタブで開くコールバックがあればそちらに委譲
        if let onOpenInNewTab = onOpenInNewTab {
            onOpenInNewTab(url)
            return
        }

        loadFileInCurrentView(url: url)
    }

    /// 現在のWebViewにファイルを読み込む（タブから呼ばれる）
    func loadFileInCurrentView(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "xml" {
            loadXMLFile(url: url)
        } else if ext == "csv" {
            loadCSVFile(url: url)
        } else if ext == "pdf" {
            loadPDFFile(url: url)
        }
    }

    // MARK: - JavaScript → Swift の通信を受け取る
    // ビルトイン表示のリンクをクリックした時にここに来る
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "openFile",
              let body = message.body as? [String: String],
              let fileName = body["fileName"],
              let dirPath = body["dirPath"] else { return }

        let directory = URL(fileURLWithPath: dirPath)
        let fileURL = directory.appendingPathComponent(fileName)
        openFile(url: fileURL)
    }

    // MARK: - CSVファイル読み込み
    private func loadCSVFile(url: URL) {
        currentPDFURL = nil
        // サンドボックス対応: CSVの親ディレクトリへのアクセスを取得
        startAccessingDirectory(url.deletingLastPathComponent())

        guard let content = readTextFile(url: url) else {
            print("ERROR: CSVファイルを読めませんでした: \(url.path)")
            return
        }
        sendCSVToJS(content: content, fileName: url.lastPathComponent)
    }

    private func sendCSVToJS(content: String, fileName: String) {
        let base64 = Data(content.utf8).base64EncodedString()
        let js = "receiveCSVFromSwift('\(base64)', '\(escapeJS(fileName))');"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error { print("CSV JS実行エラー: \(error)") }
        }
    }

    // MARK: - PDFファイル読み込み
    private func loadPDFFile(url: URL) {
        let directory = url.deletingLastPathComponent()
        startAccessingDirectory(directory)
        currentPDFURL = url
        // WKWebViewはPDFをネイティブ表示できるので、loadFileURLで直接読み込む
        webView.loadFileURL(url, allowingReadAccessTo: directory)

        // PDFオーバーレイUIの壊れたダウンロードボタンを非表示にするCSSを注入
        hidePDFDownloadButton()
    }

    /// PDFオーバーレイUIのダウンロードボタンを非表示にする
    /// WKWebViewの既知の問題でダウンロードボタンが機能しないため、
    /// 代わりにフローティング保存ボタンを使用する
    private func hidePDFDownloadButton() {
        // PDFオーバーレイUIはWKWebView内部のShadow DOMに存在する可能性があるため、
        // 複数の方法で非表示を試みる
        let js = """
        (function() {
            // 方法1: 通常のCSS注入
            var style = document.createElement('style');
            style.textContent = `
                a[is="pdf-download-button"] { display: none !important; }
                .pdf-download-button { display: none !important; }
                [data-type="download"] { display: none !important; }
            `;
            if (document.head) {
                document.head.appendChild(style);
            } else if (document.documentElement) {
                document.documentElement.appendChild(style);
            }

            // 方法2: ダウンロードボタン要素を直接検索して非表示
            function hideDownloadButtons() {
                // リンク要素でdownload属性を持つもの
                document.querySelectorAll('a[download], a[is="pdf-download-button"]').forEach(function(el) {
                    el.style.display = 'none';
                });
                // Shadow DOM内の要素も探す
                document.querySelectorAll('*').forEach(function(el) {
                    if (el.shadowRoot) {
                        el.shadowRoot.querySelectorAll('a[download], a[is="pdf-download-button"], .pdf-download-button').forEach(function(btn) {
                            btn.style.display = 'none';
                        });
                    }
                });
            }
            hideDownloadButtons();
        })();
        """
        // PDF UIは段階的に読み込まれるため、複数回試行する
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - 印刷機能
    /// macOSの印刷ダイアログを表示する（PDF保存も印刷ダイアログ経由で可能）
    ///
    /// 印刷専用の非表示WKWebViewを作成し、用紙幅に合わせたフレームで
    /// コンテンツを読み込む。これにより表示中のWebViewに影響を与えず、
    /// A4できれいに印刷・PDF化できる。
    ///
    /// - ビルトイン表示: 常に縦向き
    /// - XSL表示: コンテンツ横幅で縦横を自動判定

    /// 印刷用WebViewの強参照（印刷完了まで保持する必要がある）
    private var printWebView: WKWebView?

    func printContent() {
        // 表示モードを取得
        webView.evaluateJavaScript(
            "(typeof currentRenderMode !== 'undefined') ? currentRenderMode : 'unknown'"
        ) { [weak self] modeResult, _ in
            guard let self = self else { return }
            let renderMode = modeResult as? String ?? "unknown"

            // 表示中のHTMLを丸ごと取得
            self.webView.evaluateJavaScript(
                "document.documentElement.outerHTML"
            ) { [weak self] htmlResult, _ in
                guard let self = self,
                      let html = htmlResult as? String else { return }
                self.printWithDedicatedWebView(html: html, renderMode: renderMode)
            }
        }
    }

    /// 印刷専用WebViewを作成して印刷を実行する
    private func printWithDedicatedWebView(html: String, renderMode: String) {
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo

        // ビルトイン表示は常に縦向き、XSL/その他はデフォルト縦向き
        // （ユーザーが印刷ダイアログで横向きに変更可能）
        printInfo.orientation = .portrait

        // A4に適した余白を設定（CSS側の @page margin と連携）
        printInfo.topMargin = 42    // 約15mm
        printInfo.bottomMargin = 42 // 約15mm
        printInfo.leftMargin = 34   // 約12mm
        printInfo.rightMargin = 34  // 約12mm
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false
        printInfo.scalingFactor = 1.0

        // 用紙の印刷可能な横幅を計算
        let paperSize = printInfo.paperSize
        let printableWidth = paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let printableHeight = paperSize.height - printInfo.topMargin - printInfo.bottomMargin

        // 印刷専用の非表示WKWebViewを作成（フレーム幅 = 用紙の印刷可能幅）
        // WKWebViewはフレーム幅を「1ページの幅」として扱うため、
        // これによりコンテンツがA4幅に合わせてリフローされる
        let config = WKWebViewConfiguration()
        let printWV = WKWebView(frame: NSRect(x: 0, y: 0, width: printableWidth, height: printableHeight), configuration: config)
        self.printWebView = printWV  // 印刷完了まで保持

        // HTMLを読み込み、完了後に印刷を実行
        printWV.loadHTMLString(html, baseURL: Bundle.main.bundleURL)

        // ページ読み込み完了を待ってから印刷を実行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            let printOp = printWV.printOperation(with: printInfo)
            printOp.showsPrintPanel = true
            printOp.showsProgressPanel = true

            // 印刷パネルに「用紙の向き」と「拡大縮小」のオプションを表示
            let printPanel = printOp.printPanel
            printPanel.options.insert(.showsOrientation)
            printPanel.options.insert(.showsScaling)
            printPanel.options.insert(.showsPaperSize)
            printPanel.options.insert(.showsPreview)

            // macOSのウィンドウ自動タブ化を一時的に無効にする
            let previousTabbing = NSWindow.allowsAutomaticWindowTabbing
            NSWindow.allowsAutomaticWindowTabbing = false

            if let window = self.webView.window {
                printOp.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                printOp.run()
            }

            NSWindow.allowsAutomaticWindowTabbing = previousTabbing
            self.printWebView = nil  // 印刷完了後に解放
        }
    }

    deinit {
        // セキュリティスコープアクセスの解放
        accessedDirectoryURL?.stopAccessingSecurityScopedResource()
    }
}
