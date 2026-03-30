import Foundation
import UIKit
import WebKit

/// Result returned by web_view (navigate) and web_view_snapshot tools.
struct WebViewSnapshotResult: Codable {
    let url: String
    let finalUrl: String
    let title: String?
    /// Each entry is a human-readable line: "[N] role \"label\" extra"
    let elements: [String]
    let count: Int
    let message: String
}

/// Result returned by web_view_read (markdown extraction).
struct WebViewReadResult: Codable {
    let url: String
    let finalUrl: String
    let title: String?
    let markdown: String
    let length: Int
    let message: String
}

/// Result returned by action tools: click, type, scroll, select, navigate, close.
struct WebViewActionResult: Codable {
    let ok: Bool
    let message: String
    let url: String?
    let title: String?
}

/// Ref metadata tracked from the latest snapshot, inspired by agent-browser RefMap.
struct WebViewRefEntry: Codable {
    let ref: String
    let role: String
    let name: String
    let nth: Int?
    let selector: String?
}

enum WebViewError: LocalizedError {
    case invalidURL
    case unsupportedScheme
    case localFileNotFound(String)
    case noActiveWindowScene
    case extractionInProgress
    case loadFailed(String)
    case scriptEvaluationFailed(String)
    case extractionFailed
    case timeout
    case cancelledByUser
    /// web_view panel is not open; agent must call web_view first.
    case noOpenWebView
    /// The ref number was not found; agent should call web_view_snapshot to refresh.
    case elementNotFound(String)
    /// An interaction script failed at runtime.
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .unsupportedScheme:
            return "Only http, https, and local file URLs are supported"
        case let .localFileNotFound(path):
            return "Local file not found: \(path)"
        case .noActiveWindowScene:
            return "No active window scene available"
        case .extractionInProgress:
            return "web_view is busy with another request"
        case let .loadFailed(reason):
            return "Web view load failed: \(reason)"
        case let .scriptEvaluationFailed(reason):
            return "Web page script evaluation failed: \(reason)"
        case .extractionFailed:
            return "Failed to extract content from the web page"
        case .timeout:
            return "Web page load timed out"
        case .cancelledByUser:
            return "Web view was closed by user"
        case .noOpenWebView:
            return "web_view is not open. Call web_view first."
        case let .elementNotFound(ref):
            return "Element [\(ref)] not found. Run web_view_snapshot to refresh refs."
        case let .actionFailed(reason):
            return "Action failed: \(reason)"
        }
    }
}

@MainActor
final class WebViewService {
    static let shared = WebViewService()
    private static let defaultSessionID = "default"

    /// Keep one floating web view state per tool invocation session.
    private final class SessionState {
        var overlayWindow: PassthroughWindow?
        weak var overlayController: FloatingWebViewController?
        var isExtracting = false
        var refMap: [String: WebViewRefEntry] = [:]
    }

    private var sessionStates: [String: SessionState] = [:]

    private init() {}

    // MARK: - Navigation

    /// Navigate to a URL and return an interactive element snapshot.
    func openAndSnapshot(url: URL, sessionID: String = WebViewService.defaultSessionID, timeoutSeconds: TimeInterval = 30) async throws -> WebViewSnapshotResult {
        guard Self.isSupportedNavigableURL(url) else {
            if url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WebViewError.invalidURL
            }
            throw WebViewError.unsupportedScheme
        }

        if url.isFileURL, !Self.localPathExists(url) {
            throw WebViewError.localFileNotFound(url.path)
        }

        let resolvedSessionID = Self.normalizedSessionID(sessionID)
        let state = sessionState(for: resolvedSessionID)

        guard !state.isExtracting else {
            throw WebViewError.extractionInProgress
        }

        let controller = try ensureOverlayController(for: resolvedSessionID)
        state.isExtracting = true
        defer { state.isExtracting = false }

        let output = try await controller.loadAndSnapshot(url: url, timeoutSeconds: timeoutSeconds)
        state.refMap = Self.makeRefMap(from: output.refEntries)
        return Self.makeSnapshotResult(from: output, requestedURL: url)
    }

    // MARK: - Snapshot

    /// Return an interactive element snapshot for the currently open page.
    func snapshot(sessionID: String = WebViewService.defaultSessionID) async throws -> WebViewSnapshotResult {
        let resolvedSessionID = Self.normalizedSessionID(sessionID)
        guard let controller = sessionState(for: resolvedSessionID).overlayController else {
            throw WebViewError.noOpenWebView
        }
        let output = try await controller.evaluateSnapshot()
        sessionState(for: resolvedSessionID).refMap = Self.makeRefMap(from: output.refEntries)
        let fallbackURL = controller.currentURL ?? ""
        return Self.makeSnapshotResult(from: output, requestedURL: URL(string: fallbackURL))
    }

    // MARK: - Read

    /// Extract page content as markdown (legacy read-only mode).
    func readMarkdown(sessionID: String = WebViewService.defaultSessionID, maxLength: Int = 120_000) async throws -> WebViewReadResult {
        let resolvedSessionID = Self.normalizedSessionID(sessionID)
        guard let controller = sessionState(for: resolvedSessionID).overlayController else {
            throw WebViewError.noOpenWebView
        }
        let output = try await controller.evaluateExtraction()
        let markdown = Self.trimMarkdown(output.markdown, maxLength: maxLength)
        let resolvedTitle = Self.nonEmpty(output.title)
        let host = URL(string: output.finalURL)?.host ?? "unknown"
        let message = resolvedTitle.map { "Extracted markdown from \"\($0)\" on \(host)." }
            ?? "Extracted markdown from \(host)."
        return WebViewReadResult(
            url: output.finalURL,
            finalUrl: output.finalURL,
            title: resolvedTitle,
            markdown: markdown,
            length: markdown.count,
            message: message
        )
    }

    // MARK: - Interactions

    /// Click an element identified by its snapshot ref number.
    func click(sessionID: String = WebViewService.defaultSessionID, ref: String) async throws -> WebViewActionResult {
        let resolvedSessionID = Self.normalizedSessionID(sessionID)
        let controller = try requireOpenController(for: resolvedSessionID)
        let (refID, entry) = resolveRef(ref, sessionID: resolvedSessionID)
        return try await controller.runElementAction(
            action: "click",
            refID: refID,
            entry: entry,
            text: nil,
            value: nil,
            submit: false
        )
    }

    /// Fill an input or textarea identified by ref. Optionally submit the form.
    func type(sessionID: String = WebViewService.defaultSessionID, ref: String, text: String, submit: Bool = false) async throws -> WebViewActionResult {
        let resolvedSessionID = Self.normalizedSessionID(sessionID)
        let controller = try requireOpenController(for: resolvedSessionID)
        let (refID, entry) = resolveRef(ref, sessionID: resolvedSessionID)
        return try await controller.runElementAction(
            action: "type",
            refID: refID,
            entry: entry,
            text: text,
            value: nil,
            submit: submit
        )
    }

    /// Scroll the page. direction: "up" | "down" | "left" | "right". amount in points (default 300).
    func scroll(sessionID: String = WebViewService.defaultSessionID, direction: String, amount: Int = 300) async throws -> WebViewActionResult {
        let controller = try requireOpenController(for: Self.normalizedSessionID(sessionID))
        let dx: Int
        let dy: Int
        switch direction.lowercased() {
        case "up": dx = 0; dy = -amount
        case "down": dx = 0; dy = amount
        case "left": dx = -amount; dy = 0
        case "right": dx = amount; dy = 0
        default:
            throw WebViewError.actionFailed("Invalid direction '\(direction)'. Use up, down, left, or right.")
        }
        let js = "window.scrollBy(\(dx), \(dy)); JSON.stringify({ ok: true, message: 'Scrolled \(direction) \(amount)px' });"
        return try await controller.runInteraction(js: js, ref: nil)
    }

    /// Select a dropdown option by value for a <select> element identified by ref.
    func selectOption(sessionID: String = WebViewService.defaultSessionID, ref: String, value: String) async throws -> WebViewActionResult {
        let resolvedSessionID = Self.normalizedSessionID(sessionID)
        let controller = try requireOpenController(for: resolvedSessionID)
        let (refID, entry) = resolveRef(ref, sessionID: resolvedSessionID)
        return try await controller.runElementAction(
            action: "select",
            refID: refID,
            entry: entry,
            text: nil,
            value: value,
            submit: false
        )
    }

    /// Navigate the browser: direction is "back" | "forward" | "reload".
    func navigate(sessionID: String = WebViewService.defaultSessionID, direction: String) async throws -> WebViewActionResult {
        let controller = try requireOpenController(for: Self.normalizedSessionID(sessionID))
        switch direction.lowercased() {
        case "back":
            controller.goBack()
        case "forward":
            controller.goForward()
        case "reload":
            controller.reload()
        default:
            throw WebViewError.actionFailed("Invalid direction '\(direction)'. Use back, forward, or reload.")
        }
        let url = controller.currentURL ?? ""
        return WebViewActionResult(ok: true, message: "Navigation: \(direction)", url: url, title: nil)
    }

    /// Close and dismiss the floating web view overlay.
    func close(sessionID: String = WebViewService.defaultSessionID) {
        dismissOverlayWindow(for: Self.normalizedSessionID(sessionID))
    }

    // MARK: - Helpers

    private func requireOpenController(for sessionID: String) throws -> FloatingWebViewController {
        guard let controller = sessionState(for: sessionID).overlayController else {
            throw WebViewError.noOpenWebView
        }
        return controller
    }

    private static func makeSnapshotResult(from output: FloatingWebViewController.SnapshotOutput, requestedURL: URL?) -> WebViewSnapshotResult {
        let resolvedTitle = Self.nonEmpty(output.title)
        let host = URL(string: output.finalURL)?.host ?? requestedURL?.host ?? "unknown"
        let message: String
        if output.elements.isEmpty {
            message = "Loaded \(host). No interactive elements found. Use web_view_read to read content."
        } else {
            let noun = output.elements.count == 1 ? "element" : "elements"
            message = resolvedTitle.map { "Loaded \"\($0)\" on \(host). Found \(output.elements.count) interactive \(noun)." }
                ?? "Loaded \(host). Found \(output.elements.count) interactive \(noun)."
        }
        return WebViewSnapshotResult(
            url: requestedURL?.absoluteString ?? output.finalURL,
            finalUrl: output.finalURL,
            title: resolvedTitle,
            elements: output.elements,
            count: output.elements.count,
            message: message
        )
    }

    private func ensureOverlayController(for sessionID: String) throws -> FloatingWebViewController {
        let state = sessionState(for: sessionID)
        if let overlayController = state.overlayController {
            overlayController.bringPanelToFront()
            return overlayController
        }

        guard let scene = Self.activeWindowScene() else {
            throw WebViewError.noActiveWindowScene
        }

        let window = PassthroughWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .clear
        window.windowLevel = .alert + 1

        let controller = FloatingWebViewController()
        controller.onCloseRequested = { [weak self] in
            Task { @MainActor in
                self?.dismissOverlayWindow(for: sessionID)
            }
        }

        window.rootViewController = controller
        window.isHidden = false

        state.overlayWindow = window
        state.overlayController = controller
        return controller
    }

    private func dismissOverlayWindow(for sessionID: String) {
        guard let state = sessionStates[sessionID] else {
            return
        }
        state.overlayController?.cancelPendingExtractionIfNeeded()
        state.overlayWindow?.isHidden = true
        state.overlayWindow?.rootViewController = nil
        sessionStates.removeValue(forKey: sessionID)
    }

    /// Accepts "@e3", "e3", or "3" and normalizes to "e3".
    private static func canonicalRefID(_ rawRef: String) -> String {
        var value = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        if value.hasPrefix("e") || value.hasPrefix("E") {
            let digits = String(value.dropFirst())
            if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) {
                return "e\(digits)"
            }
            return value.lowercased()
        }
        if value.allSatisfy({ $0.isNumber }) {
            return "e\(value)"
        }
        return value.lowercased()
    }

    private func resolveRef(_ rawRef: String, sessionID: String) -> (String, WebViewRefEntry?) {
        let canonical = Self.canonicalRefID(rawRef)
        return (canonical, sessionState(for: sessionID).refMap[canonical])
    }

    private static func makeRefMap(from entries: [WebViewRefEntry]) -> [String: WebViewRefEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.ref, $0) })
    }

    private func sessionState(for sessionID: String) -> SessionState {
        if let state = sessionStates[sessionID] {
            return state
        }
        let state = SessionState()
        sessionStates[sessionID] = state
        return state
    }

    private static func normalizedSessionID(_ sessionID: String?) -> String {
        let trimmed = (sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultSessionID : trimmed
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
    }

    private static func isSupportedNavigableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private static func localPathExists(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimMarkdown(_ value: String, maxLength: Int = 120_000) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<index])
    }
}

private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if view === rootViewController?.view {
            return nil
        }
        return view
    }
}

@MainActor
private final class FloatingWebViewController: UIViewController, WKNavigationDelegate {
    private enum Layout {
        static let panelInset: CGFloat = 12
        static let frameInsets = UIEdgeInsets(top: 38, left: 0, bottom: 28, right: 0)
        static let viewportCornerRadius: CGFloat = 16
        static let closeButtonSize: CGFloat = 26
        static let statusBadgeHeight: CGFloat = 22
        static let dragHandleHitWidth: CGFloat = 72
        static let dragHandleHitHeight: CGFloat = 20
        static let dragHandleWidth: CGFloat = 32
        static let dragHandleHeight: CGFloat = 4
        static let preferredMaxScale: CGFloat = 0.32
        static let preferredMinScale: CGFloat = 0.18
        // Upper bound when user manually resizes the panel
        static let userMaxScale: CGFloat = 0.55
        static let resizeHandleHitSize: CGFloat = 32
    }

    private struct ExtractionPayload: Decodable {
        let title: String?
        let finalURL: String
        let markdown: String

        enum CodingKeys: String, CodingKey {
            case title
            case finalURL = "finalUrl"
            case markdown
        }
    }

    /// Element entry produced by snapshot JS and used to reconstruct ref map.
    fileprivate struct SnapshotElementPayload: Decodable {
        let ref: String
        let role: String
        let name: String
        let tag: String
        let nth: Int?
        let selector: String?
        let line: String
    }

    /// Output from the snapshot JS (interactive element list + ref metadata).
    fileprivate struct SnapshotPayload: Decodable {
        let title: String?
        let finalURL: String
        let elements: [SnapshotElementPayload]
        let count: Int

        enum CodingKeys: String, CodingKey {
            case title
            case finalURL = "finalUrl"
            case elements
            case count
        }
    }

    fileprivate struct ExtractionOutput {
        let title: String?
        let finalURL: String
        let markdown: String
    }

    /// Output produced after page load — used by the navigate tool.
    fileprivate struct SnapshotOutput {
        let title: String?
        let finalURL: String
        let elements: [String]
        let refEntries: [WebViewRefEntry]
    }

    /// Result produced by inline interaction JS.
    private struct InteractionPayload: Decodable {
        let ok: Bool
        let message: String
    }

    var onCloseRequested: (() -> Void)?

    /// Tracks which JS to run after page load: snapshot (returns element list) or extraction (returns markdown).
    private enum PendingMode { case snapshot, extraction }
    private var pendingMode: PendingMode = .snapshot

    /// Continuation for the legacy extraction path (used by evaluateExtraction).
    private var continuation: CheckedContinuation<ExtractionOutput, Error>?
    // Continuation for the snapshot path (used by loadAndSnapshot).
    private var snapshotContinuation: CheckedContinuation<SnapshotOutput, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var extractionTask: DispatchWorkItem?
    private var panelOrigin = CGPoint.zero
    private var panelSize = CGSize.zero
    private var deviceViewportSize = CGSize.zero
    private var currentScale: CGFloat = 1
    private var requestedURL: URL?
    private var statusFallbackText = "Idle"
    /// Non-nil when the user has manually resized the panel; overrides auto scale
    private var userScale: CGFloat?
    // Scale captured at the start of a resize gesture, used for absolute-delta calculation
    private var scaleAtGestureStart: CGFloat = Layout.preferredMaxScale
    private var hasLaidOutPanel = false
    private var hasCommittedMainFrameNavigation = false
    private var hasFinishedMainFrameNavigation = false

    private let panelView = UIView()
    private let viewportClipView = UIView()
    private let contentScaleView = UIView()
    private let statusEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let dragHandleView = UIView()
    private let dragHandleIndicatorView = UIView()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let resizeHandleView = UIView()
    private let resizeHandleImageView = UIImageView()
    private lazy var dragGestureRecognizer: UIPanGestureRecognizer = .init(target: self, action: #selector(self.handlePanelPan(_:)))

    private lazy var resizeGestureRecognizer: UIPanGestureRecognizer = .init(target: self, action: #selector(self.handleResizePan(_:)))

    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()
        return WKWebView(frame: .zero, configuration: config)
    }()

    private var handleAccentColor: UIColor {
        UIColor.tertiaryLabel.withAlphaComponent(0.55)
    }

    /// The URL currently loaded in the web view (or nil).
    var currentURL: String? {
        webView.url?.absoluteString
    }

    /// Navigate back in history.
    func goBack() {
        if webView.canGoBack {
            _ = webView.goBack()
        }
    }

    /// Navigate forward in history.
    func goForward() {
        if webView.canGoForward {
            _ = webView.goForward()
        }
    }

    /// Reload the current page.
    func reload() {
        webView.reload()
    }

    /// Load URL, wait for page to finish, then run snapshot JS and return element list.
    fileprivate func loadAndSnapshot(url: URL, timeoutSeconds: TimeInterval) async throws -> SnapshotOutput {
        guard continuation == nil else {
            throw WebViewError.extractionInProgress
        }

        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: timeoutSeconds)
        requestedURL = url
        extractionTask?.cancel()
        webView.stopLoading()
        hasCommittedMainFrameNavigation = false
        hasFinishedMainFrameNavigation = false
        updateStatus("Loading...")

        // Reuse the existing continuation mechanism; completeExtraction will fire snapshot JS.
        pendingMode = .snapshot
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SnapshotOutput, Error>) in
            self.snapshotContinuation = cont
            self.startTimeout(seconds: timeoutSeconds)
            if url.isFileURL {
                // Grant read access to the parent directory so relative assets can be loaded.
                let readAccessURL = url.deletingLastPathComponent()
                self.webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
            } else {
                self.webView.load(request)
            }
        }
    }

    /// Run snapshot JS on the already-loaded page and return element list.
    fileprivate func evaluateSnapshot() async throws -> SnapshotOutput {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SnapshotOutput, Error>) in
            self.webView.evaluateJavaScript(Self.snapshotJavaScript) { [weak self] value, error in
                guard let self else { return }
                if let error {
                    cont.resume(throwing: WebViewError.scriptEvaluationFailed(error.localizedDescription))
                    return
                }
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(SnapshotPayload.self, from: data)
                else {
                    cont.resume(throwing: WebViewError.extractionFailed)
                    return
                }
                self.updateStatus("Snapshot (\(payload.count) elements)")
                let refEntries = payload.elements.map {
                    WebViewRefEntry(
                        ref: $0.ref,
                        role: $0.role,
                        name: $0.name,
                        nth: $0.nth,
                        selector: $0.selector
                    )
                }
                cont.resume(returning: SnapshotOutput(
                    title: payload.title,
                    finalURL: payload.finalURL,
                    elements: payload.elements.map(\.line),
                    refEntries: refEntries
                ))
            }
        }
    }

    /// Run markdown extraction JS on the already-loaded page.
    fileprivate func evaluateExtraction() async throws -> ExtractionOutput {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExtractionOutput, Error>) in
            self.webView.evaluateJavaScript(Self.extractionJavaScript) { value, error in
                if let error {
                    cont.resume(throwing: WebViewError.scriptEvaluationFailed(error.localizedDescription))
                    return
                }
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(ExtractionPayload.self, from: data)
                else {
                    cont.resume(throwing: WebViewError.extractionFailed)
                    return
                }
                cont.resume(returning: ExtractionOutput(
                    title: payload.title,
                    finalURL: payload.finalURL,
                    markdown: payload.markdown
                ))
            }
        }
    }

    /// Run an interaction JS snippet and decode the `{ ok, message }` result.
    /// Use this for scripts that do NOT require untrusted user values as arguments.
    fileprivate func runInteraction(js: String, ref: String?) async throws -> WebViewActionResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebViewActionResult, Error>) in
            self.webView.evaluateJavaScript(js) { [weak self] value, error in
                if let error {
                    cont.resume(throwing: WebViewError.actionFailed(error.localizedDescription))
                    return
                }
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(InteractionPayload.self, from: data)
                else {
                    cont.resume(throwing: WebViewError.actionFailed("Unexpected JS result"))
                    return
                }
                if !payload.ok {
                    if let ref, payload.message == "Element not found" {
                        cont.resume(throwing: WebViewError.elementNotFound(ref))
                    } else {
                        cont.resume(throwing: WebViewError.actionFailed(payload.message))
                    }
                    return
                }
                let url = self?.webView.url?.absoluteString
                cont.resume(returning: WebViewActionResult(ok: true, message: payload.message, url: url, title: nil))
            }
        }
    }

    /// Run an async interaction JS snippet with safe argument injection (prevents JS injection).
    /// Use this for scripts that accept user-provided text/values via the `arguments` dict.
    fileprivate func runAsyncInteraction(js: String, arguments: [String: Any]) async throws -> WebViewActionResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebViewActionResult, Error>) in
            self.webView.callAsyncJavaScript(
                js,
                arguments: arguments,
                in: nil,
                in: .page
            ) { [weak self] result in
                switch result {
                case let .success(value):
                    guard let json = value as? String,
                          let data = json.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(InteractionPayload.self, from: data)
                    else {
                        cont.resume(throwing: WebViewError.actionFailed("Unexpected JS result"))
                        return
                    }
                    if !payload.ok {
                        let ref = (arguments["ref"] as? String) ?? (arguments["refId"] as? String) ?? "?"
                        if payload.message == "Element not found" {
                            cont.resume(throwing: WebViewError.elementNotFound(ref))
                        } else {
                            cont.resume(throwing: WebViewError.actionFailed(payload.message))
                        }
                        return
                    }
                    let url = self?.webView.url?.absoluteString
                    cont.resume(returning: WebViewActionResult(ok: true, message: payload.message, url: url, title: nil))
                case let .failure(error):
                    cont.resume(throwing: WebViewError.actionFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Run a standard element action (click/type/select) with ref-aware fallback.
    fileprivate func runElementAction(
        action: String,
        refID: String,
        entry: WebViewRefEntry?,
        text: String?,
        value: String?,
        submit: Bool
    ) async throws -> WebViewActionResult {
        let js = Self.elementActionJavaScript
        var args: [String: Any] = [
            "action": action,
            "refId": refID,
            "ref": refID,
            "submit": submit,
        ]
        if let entry {
            args["refRole"] = entry.role
            args["refName"] = entry.name
            args["refNth"] = entry.nth ?? -1
            args["refSelector"] = entry.selector ?? ""
        }
        if let text {
            args["text"] = text
        }
        if let value {
            args["value"] = value
        }
        return try await runAsyncInteraction(js: js, arguments: args)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupPanelUI()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanelIfNeeded()
    }

    func bringPanelToFront() {
        view.bringSubviewToFront(panelView)
    }

    func cancelPendingExtractionIfNeeded() {
        webView.stopLoading()
        if snapshotContinuation != nil {
            completeSnapshot(.failure(WebViewError.cancelledByUser))
        } else if continuation != nil {
            completeExtraction(.failure(WebViewError.cancelledByUser))
        }
    }

    private func setupPanelUI() {
        panelView.backgroundColor = .clear

        viewportClipView.backgroundColor = .systemBackground
        viewportClipView.layer.cornerRadius = Layout.viewportCornerRadius
        viewportClipView.layer.cornerCurve = .continuous
        viewportClipView.layer.borderWidth = 0.5
        viewportClipView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        viewportClipView.clipsToBounds = true
        viewportClipView.layer.shadowColor = UIColor.black.cgColor
        viewportClipView.layer.shadowOpacity = 0.18
        viewportClipView.layer.shadowRadius = 18
        viewportClipView.layer.shadowOffset = CGSize(width: 0, height: 10)

        contentScaleView.layer.anchorPoint = .zero

        statusEffectView.clipsToBounds = true
        statusEffectView.layer.cornerRadius = Layout.statusBadgeHeight / 2

        dragHandleView.backgroundColor = .clear
        dragHandleView.addGestureRecognizer(dragGestureRecognizer)

        dragHandleIndicatorView.backgroundColor = handleAccentColor
        dragHandleIndicatorView.layer.cornerRadius = Layout.dragHandleHeight / 2
        dragHandleView.addSubview(dragHandleIndicatorView)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .label
        statusLabel.text = "Idle"
        statusLabel.textAlignment = .left
        statusLabel.lineBreakMode = .byTruncatingMiddle

        // Keep the close affordance visually light so it does not dominate the page preview.
        let closeSymbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: closeSymbolConfig), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.backgroundColor = .secondarySystemBackground
        closeButton.layer.cornerRadius = Layout.closeButtonSize / 2
        closeButton.addTarget(self, action: #selector(handleCloseTapped), for: .touchUpInside)

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false

        view.addSubview(panelView)
        panelView.addSubview(viewportClipView)
        viewportClipView.addSubview(contentScaleView)
        contentScaleView.addSubview(webView)
        statusEffectView.contentView.addSubview(statusLabel)
        panelView.addSubview(statusEffectView)
        panelView.addSubview(closeButton)
        panelView.addSubview(dragHandleView)

        // Resize handle — sits at the bottom-right corner of the viewport
        resizeHandleView.backgroundColor = .clear
        resizeHandleView.addGestureRecognizer(resizeGestureRecognizer)
        let resizeSymbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        resizeHandleImageView.image = UIImage(systemName: "arrow.down.right", withConfiguration: resizeSymbolConfig)
        resizeHandleImageView.tintColor = handleAccentColor
        resizeHandleImageView.contentMode = .center
        resizeHandleView.addSubview(resizeHandleImageView)
        panelView.addSubview(resizeHandleView)
    }

    private func layoutPanelIfNeeded() {
        guard !view.bounds.isEmpty else {
            return
        }

        let safeFrame = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: Layout.panelInset, dy: Layout.panelInset)
        guard safeFrame.width > 0, safeFrame.height > 0 else {
            return
        }

        let deviceSize = currentDeviceViewportSize()
        deviceViewportSize = deviceSize
        let scale = userScale ?? preferredViewportScale(for: safeFrame.size, deviceSize: deviceSize)
        currentScale = scale

        let scaledViewportSize = CGSize(width: deviceSize.width * scale, height: deviceSize.height * scale)
        let panelSize = CGSize(
            width: scaledViewportSize.width + Layout.frameInsets.left + Layout.frameInsets.right,
            height: scaledViewportSize.height + Layout.frameInsets.top + Layout.frameInsets.bottom
        )
        self.panelSize = panelSize

        if !hasLaidOutPanel {
            panelOrigin = CGPoint(x: safeFrame.minX, y: safeFrame.minY)
            hasLaidOutPanel = true
        }
        panelOrigin = clampedPanelOrigin(panelOrigin, safeFrame: safeFrame, panelSize: panelSize)

        panelView.frame = CGRect(origin: panelOrigin, size: panelSize)
        viewportClipView.frame = CGRect(
            x: Layout.frameInsets.left,
            y: Layout.frameInsets.top,
            width: scaledViewportSize.width,
            height: scaledViewportSize.height
        )
        contentScaleView.bounds = CGRect(origin: .zero, size: deviceSize)
        contentScaleView.layer.position = .zero
        // Keep the rendered page at device size, then scale the container down visually.
        contentScaleView.transform = CGAffineTransform(scaleX: scale, y: scale)
        webView.frame = CGRect(origin: .zero, size: deviceSize)
        viewportClipView.layer.shadowPath = UIBezierPath(
            roundedRect: viewportClipView.bounds,
            cornerRadius: viewportClipView.layer.cornerRadius
        ).cgPath

        // Keep top controls above the page preview on a dedicated control strip.
        let topControlCenterY = Layout.frameInsets.top / 2

        closeButton.frame = CGRect(
            x: viewportClipView.frame.maxX - Layout.closeButtonSize - 4,
            y: (topControlCenterY - Layout.closeButtonSize / 2).rounded(),
            width: Layout.closeButtonSize,
            height: Layout.closeButtonSize
        )

        let statusHorizontalPadding: CGFloat = 4
        let maxStatusWidth = closeButton.frame.minX - statusHorizontalPadding * 2 - 4
        let statusWidth = max(48, maxStatusWidth)
        statusEffectView.frame = CGRect(
            x: statusHorizontalPadding,
            y: (topControlCenterY - Layout.statusBadgeHeight / 2).rounded(),
            width: statusWidth,
            height: Layout.statusBadgeHeight
        )
        statusLabel.frame = statusEffectView.bounds.insetBy(dx: 8, dy: 4)

        // Keep bottom controls on a shared baseline below the page preview.
        let bottomControlCenterY = viewportClipView.frame.maxY + Layout.frameInsets.bottom / 2

        dragHandleView.frame = CGRect(
            x: (panelSize.width - Layout.dragHandleHitWidth) / 2,
            y: bottomControlCenterY - Layout.dragHandleHitHeight / 2,
            width: Layout.dragHandleHitWidth,
            height: Layout.dragHandleHitHeight
        )
        dragHandleIndicatorView.frame = CGRect(
            x: (Layout.dragHandleHitWidth - Layout.dragHandleWidth) / 2,
            y: (Layout.dragHandleHitHeight - Layout.dragHandleHeight) / 2,
            width: Layout.dragHandleWidth,
            height: Layout.dragHandleHeight
        )

        // Keep the resize affordance outside the page content so it does not cover the preview.
        let resizeHS = Layout.resizeHandleHitSize
        resizeHandleView.frame = CGRect(
            x: viewportClipView.frame.maxX - resizeHS,
            y: bottomControlCenterY - resizeHS / 2,
            width: resizeHS,
            height: resizeHS
        )
        resizeHandleImageView.frame = resizeHandleView.bounds
    }

    private func currentDeviceViewportSize() -> CGSize {
        let size = view.window?.windowScene?.screen.bounds.size ?? view.bounds.size
        return CGSize(width: max(size.width, 320), height: max(size.height, 568))
    }

    private func preferredViewportScale(for availableSize: CGSize, deviceSize: CGSize) -> CGFloat {
        let maxVisibleWidth = min(availableSize.width * 0.34, 148)
        let maxVisibleHeight = min(availableSize.height * 0.32, 240)
        let scale = min(maxVisibleWidth / deviceSize.width, maxVisibleHeight / deviceSize.height)
        return min(max(scale, Layout.preferredMinScale), Layout.preferredMaxScale)
    }

    private func clampedPanelOrigin(_ origin: CGPoint, safeFrame: CGRect, panelSize: CGSize) -> CGPoint {
        let minX = safeFrame.minX
        let minY = safeFrame.minY
        let maxX = max(minX, safeFrame.maxX - panelSize.width)
        let maxY = max(minY, safeFrame.maxY - panelSize.height)
        return CGPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, minY), maxY))
    }

    @objc
    private func handleCloseTapped() {
        cancelPendingExtractionIfNeeded()
        onCloseRequested?()
    }

    @objc
    private func handlePanelPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        if recognizer.state == .changed || recognizer.state == .ended {
            let candidateOrigin = CGPoint(
                x: panelOrigin.x + translation.x,
                y: panelOrigin.y + translation.y
            )
            let safeFrame = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: Layout.panelInset, dy: Layout.panelInset)
            panelOrigin = clampedPanelOrigin(candidateOrigin, safeFrame: safeFrame, panelSize: panelSize)
            panelView.frame.origin = panelOrigin
            recognizer.setTranslation(.zero, in: view)
        }
    }

    @objc
    private func handleResizePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            // Snapshot scale at gesture start; subsequent .changed events use absolute translation
            scaleAtGestureStart = currentScale
        case .changed, .ended:
            let translation = recognizer.translation(in: view)
            // Project the finger movement onto the handle travel axis so the corner tracks the drag.
            let scaleDelta = projectedScaleDelta(for: translation)
            userScale = min(
                max(scaleAtGestureStart + scaleDelta, Layout.preferredMinScale),
                Layout.userMaxScale
            )
            layoutPanelIfNeeded()
        default:
            break
        }
    }

    private func projectedScaleDelta(for translation: CGPoint) -> CGFloat {
        let resizeAxis = CGPoint(x: deviceViewportSize.width, y: deviceViewportSize.height)
        let axisLengthSquared = resizeAxis.x * resizeAxis.x + resizeAxis.y * resizeAxis.y
        guard axisLengthSquared > 0 else {
            return 0
        }

        let projectedDistance = translation.x * resizeAxis.x + translation.y * resizeAxis.y
        return projectedDistance / axisLengthSquared
    }

    private func updateStatus(_ text: String) {
        statusFallbackText = text
        statusLabel.text = currentStatusLabelText()
        layoutPanelIfNeeded()
    }

    private func currentStatusLabelText() -> String {
        if let currentURL = webView.url ?? requestedURL {
            return currentURL.absoluteString
        }
        return statusFallbackText
    }

    private func startTimeout(seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let safeSeconds = max(1, Int(seconds.rounded(.up)))
            try? await Task.sleep(nanoseconds: UInt64(safeSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if self.snapshotContinuation != nil {
                self.completeSnapshot(.failure(WebViewError.timeout))
            } else if self.continuation != nil {
                self.completeExtraction(.failure(WebViewError.timeout))
            }
        }
    }

    /// Resolve the snapshot continuation with a result.
    private func completeSnapshot(_ result: Result<SnapshotOutput, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        extractionTask?.cancel()
        extractionTask = nil

        if case let .success(output) = result {
            updateStatus("Ready (\(output.elements.count) elements)")
        } else {
            updateStatus(hasVisiblePage ? "Open" : "Failed")
        }

        guard let cont = snapshotContinuation else { return }
        snapshotContinuation = nil
        cont.resume(with: result)
    }

    private func completeExtraction(_ result: Result<ExtractionOutput, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        extractionTask?.cancel()
        extractionTask = nil

        if case .success = result {
            updateStatus("Ready")
        } else {
            updateStatus(hasVisiblePage ? "Open" : "Failed")
        }

        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }

    /// Run the appropriate JS after page load — snapshot or extraction depending on pendingMode.
    private func evaluateExtractionScript() {
        switch pendingMode {
        case .snapshot:
            evaluateSnapshotScript()
        case .extraction:
            evaluateExtractionScriptLegacy()
        }
    }

    private func evaluateSnapshotScript() {
        updateStatus("Scanning elements...")
        webView.evaluateJavaScript(Self.snapshotJavaScript) { [weak self] value, error in
            guard let self else { return }
            if let error {
                let err: Error = self.hasVisiblePage
                    ? WebViewError.scriptEvaluationFailed(error.localizedDescription)
                    : WebViewError.loadFailed(error.localizedDescription)
                self.completeSnapshot(.failure(err))
                return
            }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(SnapshotPayload.self, from: data)
            else {
                self.completeSnapshot(.failure(WebViewError.extractionFailed))
                return
            }
            let refEntries = payload.elements.map {
                WebViewRefEntry(
                    ref: $0.ref,
                    role: $0.role,
                    name: $0.name,
                    nth: $0.nth,
                    selector: $0.selector
                )
            }
            self.completeSnapshot(.success(SnapshotOutput(
                title: payload.title,
                finalURL: payload.finalURL,
                elements: payload.elements.map(\.line),
                refEntries: refEntries
            )))
        }
    }

    private func evaluateExtractionScriptLegacy() {
        updateStatus("Extracting...")
        webView.evaluateJavaScript(Self.extractionJavaScript) { [weak self] value, error in
            guard let self else { return }
            if let error {
                let extractionError: Error
                if self.hasVisiblePage {
                    // Keep JavaScript failure details so extraction errors are diagnosable.
                    extractionError = WebViewError.scriptEvaluationFailed(error.localizedDescription)
                } else {
                    extractionError = WebViewError.loadFailed(error.localizedDescription)
                }
                self.completeExtraction(.failure(extractionError))
                return
            }

            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ExtractionPayload.self, from: data)
            else {
                self.completeExtraction(.failure(WebViewError.extractionFailed))
                return
            }

            self.completeExtraction(.success(ExtractionOutput(
                title: payload.title,
                finalURL: payload.finalURL,
                markdown: payload.markdown
            )))
        }
    }

    private func scheduleExtraction(after delay: TimeInterval) {
        extractionTask?.cancel()
        // Only schedule if there's a pending continuation in the current mode.
        let hasPending = pendingMode == .snapshot ? snapshotContinuation != nil : continuation != nil
        guard hasPending else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluateExtractionScript()
        }
        extractionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func handleNavigationFailure(_ error: Error) {
        if Self.isNonFatalNavigationError(error) {
            updateStatus("Loaded with warnings")
            let hasPending = snapshotContinuation != nil || continuation != nil
            if hasPending, webView.url != nil {
                // Some pages emit JavaScript or interrupted-frame errors after content is already usable.
                scheduleExtraction(after: 0.2)
            }
            return
        }

        let failure: Error = hasVisiblePage
            ? WebViewError.extractionFailed
            : WebViewError.loadFailed(error.localizedDescription)

        if pendingMode == .snapshot {
            completeSnapshot(.failure(failure))
        } else {
            completeExtraction(.failure(failure))
        }
    }

    private var hasVisiblePage: Bool {
        hasCommittedMainFrameNavigation || hasFinishedMainFrameNavigation || webView.url != nil
    }

    func webView(_: WKWebView, didCommit _: WKNavigation!) {
        hasCommittedMainFrameNavigation = true
        updateStatus("Opening...")
    }

    private static func isNonFatalNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }

        let failingURLString = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? (nsError.userInfo["NSErrorFailingURLStringKey"] as? String)
        if let failingURLString, failingURLString.lowercased().hasPrefix("javascript:") {
            return true
        }

        if nsError.domain == WKErrorDomain {
            switch nsError.code {
            case WKError.Code.javaScriptExceptionOccurred.rawValue,
                 WKError.Code.javaScriptResultTypeIsUnsupported.rawValue,
                 WKError.Code.javaScriptInvalidFrameTarget.rawValue:
                return true
            default:
                break
            }
        }

        return nsError.localizedDescription.localizedCaseInsensitiveContains("javascript")
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        hasFinishedMainFrameNavigation = true
        updateStatus("Loaded")
        // Delay extraction slightly so JS-heavy pages can settle after didFinish.
        scheduleExtraction(after: 0.35)
    }

    func webView(
        _: WKWebView,
        didFail _: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    private static let extractionJavaScript = FloatingWebViewController.loadExtractionJavaScript()
    private static let snapshotJavaScript = FloatingWebViewController.loadSnapshotJavaScript()
    private static let elementActionJavaScript = FloatingWebViewController.elementActionScript()

    private static func loadExtractionJavaScript() -> String {
        loadBundledScript(named: "WebViewExtraction")
            ?? "(() => JSON.stringify({ title: document.title || null, finalUrl: window.location.href, markdown: document.body ? document.body.innerText : '' }))();"
    }

    private static func loadSnapshotJavaScript() -> String {
        loadBundledScript(named: "WebViewSnapshot")
            ?? "(() => JSON.stringify({ title: document.title || null, finalUrl: window.location.href, elements: [], count: 0 }))();"
    }

    private static func elementActionScript() -> String {
        """
        return (() => {
          const trim = (v) => (typeof v === 'string' ? v : '').trim();
          const normalize = (v) => trim(v).toLowerCase();
          const safeText = (value) => (typeof value === 'string' ? value : '');

          const resolveByRef = (refId) => {
            if (!refId) return null;
            const raw = refId.startsWith('@') ? refId.slice(1) : refId;
            const numeric = raw.startsWith('e') ? raw.slice(1) : raw;
            const selector = '[data-ai-ref-id="' + raw + '"]';
            const direct = document.querySelector(selector);
            if (direct) return direct;
            if (/^\\d+$/.test(numeric)) {
              return document.querySelector('[data-ai-ref="' + numeric + '"]');
            }
            return null;
          };

          const resolveByRoleName = (role, name, nth) => {
            if (!role) return null;
            const roleSelector = '[role="' + role.replace(/"/g, '\\"') + '"]';
            const candidates = Array.from(document.querySelectorAll(roleSelector));
            if (!candidates.length) return null;
            const wantedName = normalize(name);
            const matches = candidates.filter((el) => {
              const label = normalize(el.getAttribute('aria-label') || el.innerText || el.textContent || '');
              return wantedName ? label === wantedName : true;
            });
            if (!matches.length) return null;
            if (typeof nth === 'number' && nth >= 0 && nth < matches.length) {
              return matches[nth];
            }
            return matches[0];
          };

          const resolveBySelector = (sel) => {
            const selector = trim(sel);
            if (!selector) return null;
            try {
              return document.querySelector(selector);
            } catch (_) {
              return null;
            }
          };

          const applyValue = (el, value) => {
            const setterInput = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            const setterText = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
            const setterSelect = Object.getOwnPropertyDescriptor(window.HTMLSelectElement.prototype, 'value');
            const setter = setterInput || setterText || setterSelect;
            if (setter && setter.set) {
              setter.set.call(el, value);
            } else {
              el.value = value;
            }
          };

          const actionHandlers = {
            click: (el) => {
              el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
              el.click();
              return 'Clicked';
            },
            type: (el, payload) => {
              const text = safeText(payload.text);
              el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
              el.focus();
              applyValue(el, text);
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              if (payload.submit) {
                el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
                const form = el.closest('form');
                if (form) form.submit();
              }
              return 'Typed';
            },
            select: (el, payload) => {
              const value = safeText(payload.value);
              if (el.tagName.toLowerCase() !== 'select') {
                return { ok: false, message: 'Element is not a <select>' };
              }
              applyValue(el, value);
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return 'Selected "' + value + '"';
            },
          };

          const payload = {
            action: typeof action === 'string' ? action : 'click',
            refId: typeof refId === 'string' ? refId : '',
            refRole: typeof refRole === 'string' ? refRole : '',
            refName: typeof refName === 'string' ? refName : '',
            refNth: typeof refNth === 'number' ? refNth : -1,
            refSelector: typeof refSelector === 'string' ? refSelector : '',
            text: typeof text === 'string' ? text : '',
            value: typeof value === 'string' ? value : '',
            submit: !!submit,
          };

          let el = resolveByRef(refId);
          if (!el) {
            el = resolveBySelector(refSelector);
          }
          if (!el) {
            el = resolveByRoleName(refRole, refName, refNth);
          }
          if (!el) {
            return JSON.stringify({ ok: false, message: 'Element not found' });
          }

          const handler = actionHandlers[payload.action];
          if (!handler) {
            return JSON.stringify({ ok: false, message: 'Unsupported action' });
          }
          const result = handler(el, payload);
          if (typeof result === 'object' && result && result.ok === false) {
            return JSON.stringify(result);
          }
          return JSON.stringify({ ok: true, message: result });
        })();
        """
    }

    private static func loadBundledScript(named resourceName: String) -> String? {
        let bundles = [Bundle.main, Bundle(for: FloatingWebViewController.self)]
        for bundle in bundles {
            guard let url = bundle.url(forResource: resourceName, withExtension: "js") else {
                continue
            }
            if let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty {
                return source
            }
        }
        assertionFailure("Missing bundled script: \(resourceName).js")
        return nil
    }
}
