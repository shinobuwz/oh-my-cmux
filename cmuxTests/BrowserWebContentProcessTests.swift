import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserWebContentProcessTests {
    private let recoveryURL = URL(string: "data:text/html,cmux-recovery")!

    @Test
    func browserPanelsShareDefaultWebsiteDataStore() {
        let first = BrowserPanel(workspaceId: UUID())
        let second = BrowserPanel(workspaceId: UUID())
        defer {
            first.close()
            second.close()
        }

        #expect(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
    }

    @Test
    func configureWebViewConfigurationAppliesWebsiteDataStore() {
        let configuration = WKWebViewConfiguration()
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: websiteDataStore
        )

        #expect(configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func configuredBrowserPageInstallsWebAuthnBridge() async throws {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent()
        )
        let webAuthnScript = try #require(
            configuration.userContentController.userScripts.first {
                $0.source == BrowserWebAuthnBridgeContract.scriptSource
            }
        )
        let webAuthnRelayScript = try #require(
            configuration.userContentController.userScripts.first {
                $0.source == BrowserWebAuthnBridgeContract.relayScriptSource
            }
        )
        #expect(webAuthnScript.injectionTime == .atDocumentStart)
        #expect(webAuthnScript.isForMainFrameOnly)
        #expect(webAuthnRelayScript.injectionTime == .atDocumentStart)
        #expect(webAuthnRelayScript.isForMainFrameOnly)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey bridge probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let installed = try await webView.evaluateJavaScript(
            "window.__cmuxWebAuthnBridgeInstalled === true"
        ) as? Bool
        #expect(installed == true)
    }

    @Test
    func browserPanelInstallsWebAuthnBridgeWithoutExposingNativeHandler() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let webView = panel.webView
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey native handler probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let result = try await webView.evaluateJavaScript(
            """
            ({
              bridge: window.__cmuxWebAuthnBridgeInstalled === true,
              handler: !!(
                window.webkit &&
                window.webkit.messageHandlers &&
                window.webkit.messageHandlers.cmuxWebAuthn &&
                typeof window.webkit.messageHandlers.cmuxWebAuthn.postMessage === "function"
              )
            })
            """
        ) as? [String: Bool]
        #expect(result?["bridge"] == true)
        #expect(result?["handler"] == false)
    }

    @Test
    func webAuthnPageBridgeRelaysCredentialGetThroughContentWorldHandler() async throws {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent()
        )
        let probe = BrowserWebAuthnReplyProbe()
        configuration.userContentController.addScriptMessageHandler(
            probe,
            contentWorld: BrowserWebAuthnBridgeContract.contentWorld,
            name: BrowserWebAuthnBridgeContract.handlerName
        )
        defer {
            configuration.userContentController.removeScriptMessageHandler(
                forName: BrowserWebAuthnBridgeContract.handlerName,
                contentWorld: BrowserWebAuthnBridgeContract.contentWorld
            )
        }
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey relay probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let result = try await webView.evaluateJavaScript(
            """
            (async () => {
              const handlerVisible = !!(
                window.webkit &&
                window.webkit.messageHandlers &&
                window.webkit.messageHandlers.cmuxWebAuthn &&
                typeof window.webkit.messageHandlers.cmuxWebAuthn.postMessage === "function"
              );
              const credential = await navigator.credentials.get({
                publicKey: {
                  challenge: new Uint8Array([1, 2, 3, 4]).buffer,
                  rpId: "example.com",
                  userVerification: "preferred"
                }
              });
              return {
                handlerVisible,
                credentialId: credential && credential.id,
                rawIDLength: credential && credential.rawId && credential.rawId.byteLength,
                signatureLength:
                  credential &&
                  credential.response &&
                  credential.response.signature &&
                  credential.response.signature.byteLength
              };
            })()
            """
        ) as? [String: Any]

        #expect(result?["handlerVisible"] as? Bool == false)
        #expect(result?["credentialId"] as? String == "AQID")
        #expect((result?["rawIDLength"] as? NSNumber)?.intValue == 3)
        #expect((result?["signatureLength"] as? NSNumber)?.intValue == 2)
        #expect(probe.receivedKinds == ["getCredential"])
    }

    @Test
    func webAuthnNativeBridgeScopesParentDomainRelyingPartyIDs() throws {
        let googleOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://accounts.google.com")!)
        )
        #expect(googleOrigin.isWithinRelyingPartyScope("google.com"))
        #expect(googleOrigin.permits(relyingPartyIdentifier: "google.com"))

        let exampleOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://login.example.com")!)
        )
        #expect(exampleOrigin.isWithinRelyingPartyScope("example.com"))
        #expect(!exampleOrigin.permits(relyingPartyIdentifier: "example.com"))
        #expect(!exampleOrigin.permits(relyingPartyIdentifier: "com"))

        let githubPagesOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://tenant.github.io")!)
        )
        #expect(githubPagesOrigin.isWithinRelyingPartyScope("github.io"))
        #expect(githubPagesOrigin.permits(relyingPartyIdentifier: "tenant.github.io"))
        #expect(!githubPagesOrigin.permits(relyingPartyIdentifier: "github.io"))

        let appspotOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://foo.appspot.com")!)
        )
        #expect(appspotOrigin.isWithinRelyingPartyScope("appspot.com"))
        #expect(appspotOrigin.permits(relyingPartyIdentifier: "foo.appspot.com"))
        #expect(!appspotOrigin.permits(relyingPartyIdentifier: "appspot.com"))
    }

    @Test
    func webAuthnSecurityOriginSerializesIPv6LoopbackOrigins() throws {
        let origin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "http://[::1]:3000")!)
        )

        #expect(origin.serializedString == "http://[::1]:3000")
        #expect(origin.isPotentiallyTrustworthyWebAuthnOrigin)
    }

    @Test
    func webViewReplacementAfterProcessTerminationUpdatesInstanceIdentity() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let viewportHost = panel.viewportHostView
        let oldInstanceID = panel.webViewInstanceID

        #expect(oldWebView.superview == nil)
        #expect(oldWebView.cmuxBrowserViewportHostView === viewportHost)

        panel.debugSimulateWebContentProcessTermination()

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webViewInstanceID != oldInstanceID)
        // First non-empty termination auto-recovers (replace + reload); no recovery overlay.
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.webView.navigationDelegate != nil)
        #expect(panel.webView.uiDelegate != nil)
        #expect(panel.webView.superview == nil)
        #expect(panel.webView.cmuxBrowserViewportHostView === viewportHost)
        #expect(oldWebView.cmuxBrowserViewportHostView == nil)
    }

    @Test
    func webViewReplacementPreservesActiveEmulatedViewportHost() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 610))
        container.addSubview(oldWebView)
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        _ = try panel.setAutomationViewport(viewport).get()

        #expect(oldWebView.superview === panel.viewportHostView)

        panel.debugSimulateWebContentProcessTermination()

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webView.superview === panel.viewportHostView)
        #expect(panel.webView.cmuxBrowserViewportPresentationView === panel.viewportHostView)
        #expect(panel.webView.cmuxBrowserViewportHostView === panel.viewportHostView)
        #expect(oldWebView.cmuxBrowserViewportHostView == nil)
    }

    @Test
    func remoteWorkspaceWebsiteDataStoreSurvivesWebViewReplacement() {
        let storeIdentifier = UUID()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: storeIdentifier
        )
        defer { panel.close() }
        let originalStore = panel.webView.configuration.websiteDataStore

        panel.debugSimulateWebContentProcessTermination()

        #expect(panel.webView.configuration.websiteDataStore === originalStore)
    }

    @Test
    func reloadRecoversTerminatedWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        // First non-empty termination auto-recovers (replace + reload); no overlay.
        panel.debugSimulateWebContentProcessTermination()
        #expect(!panel.hasRecoverableWebContentTermination)

        // A second consecutive termination before commit opens the render circuit.
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
        let circuitOpenWebView = panel.webView

        panel.reload()

        // Retry closes the circuit, builds a fresh WKWebView, and resets the
        // consecutive-termination budget for the new recovery attempt.
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldRenderWebView)
        #expect(!(panel.webView === circuitOpenWebView))
        let retriedWebView = panel.webView

        // The first pre-commit termination after a manual retry auto-recovers.
        panel.debugSimulateWebContentProcessTermination()
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldRenderWebView)
        #expect(!(panel.webView === retriedWebView))

        // Only the second consecutive termination reopens the circuit.
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
    }

    @Test
    func workspaceContextResetClearsTerminatedWebViewRecovery() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        // Two consecutive terminations open the render circuit.
        panel.debugSimulateWebContentProcessTermination()
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        panel.resetForWorkspaceContextChange(reason: "test")

        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.preferredURLStringForOmnibar() == nil)
    }

    @Test
    func profileSwitchClearsTerminatedWebViewRecovery() throws {
        let profile = try #require(
            BrowserProfileStore.shared.createProfile(
                named: "WebContent Recovery \(UUID().uuidString)"
            )
        )
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            initialURL: recoveryURL
        )
        defer { panel.close() }

        // Two consecutive terminations open the render circuit.
        panel.debugSimulateWebContentProcessTermination()
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        #expect(panel.switchToProfile(profile.id))

        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test
    func webViewReplacementPreservesEmptyNewTabRenderState() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        #expect(!panel.shouldRenderWebView)

        panel.debugSimulateWebContentProcessTermination()

        #expect(!panel.shouldRenderWebView)
        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test
    func secondConsecutiveTerminationOpensCircuitWithoutReplacement() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        let originalWebView = panel.webView
        let originalInstanceID = panel.webViewInstanceID

        // First non-empty termination: auto-replace + reload, no recovery overlay.
        panel.debugSimulateWebContentProcessTermination()
        #expect(!(panel.webView === originalWebView))
        #expect(panel.webViewInstanceID != originalInstanceID)
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldRenderWebView)

        let replacedWebView = panel.webView
        let replacedInstanceID = panel.webViewInstanceID

        // Second consecutive termination before commit opens the render circuit
        // without constructing another replacement: identity is preserved.
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.webView === replacedWebView)
        #expect(panel.webViewInstanceID == replacedInstanceID)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)

        // A repeated (third) termination callback is a no-op while the circuit is open.
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.webView === replacedWebView)
        #expect(panel.webViewInstanceID == replacedInstanceID)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
    }

    @Test
    func nonblankCommitResetsConsecutiveTerminationBudget() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        // First termination: auto-replace + reload (budget 0 -> 1).
        panel.debugSimulateWebContentProcessTermination()
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldRenderWebView)
        let firstReplacedWebView = panel.webView

        // Simulate WebKit firing didCommit for a non-about:blank main frame on
        // the current webview. This resets the consecutive-termination budget to 0.
        panel.navigationDelegate?.didCommit?(panel.webView, nil)

        // After the reset, the next termination behaves as a fresh "first":
        // auto-replace + reload, no circuit. Identity changes again.
        panel.debugSimulateWebContentProcessTermination()
        #expect(!(panel.webView === firstReplacedWebView))
        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldRenderWebView)

        let secondReplacedWebView = panel.webView

        // Without an intervening commit, the next consecutive termination opens
        // the circuit without replacing. Identity is preserved.
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.webView === secondReplacedWebView)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
    }

    @Test
    func ordinaryNavigationRefusesWhileTerminationCircuitIsOpen() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        // Open the render circuit with two consecutive terminations.
        panel.debugSimulateWebContentProcessTermination()
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)

        let circuitOpenWebView = panel.webView
        let otherURL = URL(string: "https://example.org/circuit-refusal")!

        // Ordinary typed navigation must refuse while the circuit is open: no
        // re-render, no identity change, circuit stays open for explicit Retry.
        _ = panel.navigate(to: otherURL)

        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.webView === circuitOpenWebView)
    }

    @Test
    func pendingRemoteNavigationRefusesWhileTerminationCircuitIsOpen() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: UUID()
        )
        defer { panel.close() }

        // Open the render circuit with two consecutive terminations.
        panel.debugSimulateWebContentProcessTermination()
        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)

        let circuitOpenWebView = panel.webView
        let otherURL = URL(string: "https://example.org/remote-circuit-refusal")!

        // Pending-remote navigation must refuse while the circuit is open: the
        // pending-remote queue is not re-armed over a non-rendering pane.
        _ = panel.navigate(to: otherURL)

        #expect(panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.webView === circuitOpenWebView)
    }

    @Test
    func floatingPopupInheritsOpenerWebsiteDataStore() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        #expect(popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
    }

    @Test
    func floatingPopupInheritsRemoteWorkspaceWebsiteDataStore() throws {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        #expect(popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
        #expect(!(popupWebView.configuration.websiteDataStore === WKWebsiteDataStore.default()))
    }

    @Test
    func floatingPopupClosesWhenWebContentProcessTerminates() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        let popupWindow = try #require(popupWebView.window)

        popupWebView.navigationDelegate?.webViewWebContentProcessDidTerminate?(popupWebView)

        #expect(popupWebView.navigationDelegate == nil)
        #expect(popupWebView.uiDelegate == nil)
        #expect(popupWebView.window == nil)
        #expect(!popupWindow.isVisible)
    }
}

private final class BrowserWebContentProcessLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = continuation
        self.continuation = nil
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class BrowserWebAuthnReplyProbe: NSObject, WKScriptMessageHandlerWithReply {
    private(set) var receivedKinds: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else {
            replyHandler(
                [
                    "ok": false,
                    "error": [
                        "name": "TypeError",
                        "message": "Malformed browser passkey request.",
                    ],
                ],
                nil
            )
            return
        }

        receivedKinds.append(kind)
        switch kind {
        case "getCredential":
            replyHandler(
                [
                    "ok": true,
                    "credential": [
                        "type": "public-key",
                        "id": "AQID",
                        "rawId": "AQID",
                        "authenticatorAttachment": "platform",
                        "responseKind": "assertion",
                        "response": [
                            "clientDataJSON": "BAU",
                            "authenticatorData": "Bgc",
                            "signature": "CAk",
                            "userHandle": "Cg",
                        ],
                        "clientExtensionResults": [:],
                    ],
                ],
                nil
            )
        default:
            replyHandler(
                [
                    "ok": false,
                    "error": [
                        "name": "NotSupportedError",
                        "message": "Native passkey support is unavailable.",
                    ],
                ],
                nil
            )
        }
    }
}
