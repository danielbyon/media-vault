import Foundation

/// Rendered fixture pages.
///
/// Every interactive control is a real rendered-page element with an exact
/// accessible label, so the UI tests can drive the same user actions a person
/// would perform instead of calling app-internal entry points.
enum SpikeFixtureHTML {
    /// Shared document shell with large, tappable controls.
    static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        body { font: 16px -apple-system, system-ui, sans-serif; margin: 20px; color: #111; }
        h1 { font-size: 20px; }
        h2 { font-size: 17px; margin-top: 26px; }
        a.control { display: block; margin: 10px 0; padding: 14px; border-radius: 10px;
                    background: #0a84ff; color: #fff; text-decoration: none;
                    text-align: center; font-weight: 600; }
        a.secondary { display: block; margin: 10px 0; padding: 12px; border-radius: 10px;
                      background: #e9e9ef; color: #111; text-decoration: none;
                      text-align: center; font-weight: 600; }
        button.control { display: block; width: 100%; margin: 10px 0; padding: 14px;
                         border: 0; border-radius: 10px; background: #0a84ff; color: #fff;
                         font-size: 16px; font-weight: 600; }
        input { display: block; width: 100%; margin: 8px 0; padding: 10px; font-size: 16px; }
        p { line-height: 1.4; }
        code { background: #f2f2f7; padding: 2px 4px; border-radius: 4px; }
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        \(body)
        </body>
        </html>
        """
    }

    /// Blue tappable control that navigates to a fixture path on this origin.
    static func controlLink(label: String, path: String) -> String {
        "<a class=\"control\" href=\"\(path)\">\(label)</a>"
    }

    /// Blue tappable control that navigates to an absolute fixture URL.
    static func controlLink(label: String, absoluteURL: String) -> String {
        "<a class=\"control\" href=\"\(absoluteURL)\">\(label)</a>"
    }

    /// Muted control used for flow navigation rather than a measured case.
    static func secondaryLink(label: String, path: String) -> String {
        "<a class=\"secondary\" href=\"\(path)\">\(label)</a>"
    }

    /// Rendered fixture menu listing every measured case.
    static func menu() -> String {
        var body = "<p>The ready marker appears when this page has loaded: "
        body += "<code>\(SpikeAnchor.fixtureMenuReady)</code></p>"
        body += "<h2>Direct resources</h2>"
        for fixtureCase in SpikeFixtureCase.all where fixtureCase.controlPath != nil || fixtureCase.transferPath != nil {
            body += "<h2>\(fixtureCase.title)</h2>"
            if let label = fixtureCase.controlLabel, let path = fixtureCase.controlPath {
                body += controlLink(label: label, path: path)
            }
            if let label = fixtureCase.transferLabel, let path = fixtureCase.transferPath {
                body += controlLink(label: label, path: path)
            }
        }
        body += "<h2>Flows that need their own page</h2>"
        body += secondaryLink(label: "open login flow", path: SpikeContract.Path.login)
        body += secondaryLink(label: "open vault flow", path: SpikeContract.Path.vaultGuard)
        body += secondaryLink(label: "open cookie scope flow", path: SpikeContract.Path.scopeSetup)
        body += secondaryLink(label: "open referer flow", path: SpikeContract.Path.refererGuard)
        body += secondaryLink(label: "open origin flow", path: SpikeContract.Path.originGuard)
        body += secondaryLink(label: "open user agent flow", path: SpikeContract.Path.userAgentGuard)
        body += secondaryLink(label: "open post flow", path: SpikeContract.Path.postForm)
        body += secondaryLink(label: "open signed url flow", path: SpikeContract.Path.signedMint)
        body += secondaryLink(label: "open blob flow", path: SpikeContract.Path.blobGuard)
        body += secondaryLink(label: "open authentication flow", path: SpikeContract.Path.authGuard)
        body += secondaryLink(label: "open lifecycle flow", path: SpikeContract.Path.lifecycleGuard)
        body += "<p id=\"fixture-menu-ready\">\(SpikeAnchor.fixtureMenuReady)</p>"
        return page(title: "Spike fixture menu", body: body)
    }

    /// Login form that sets the synthetic browser session cookie.
    static func login() -> String {
        let form = """
        <form method="post" action="\(SpikeContract.Path.loginSubmit)">
        <input name="user" value="spike-user" autocomplete="off">
        <input name="password" type="password" value="spike-password" autocomplete="off">
        <button class="control" type="submit">\(SpikeAnchor.loginSubmitButton)</button>
        </form>
        """
        return page(title: "Sign in to the fixture", body: form)
    }

    /// Post-login page offering the protected resource through both paths.
    static func loginResult(authenticated: Bool) -> String {
        var body = "<p>Session cookie accepted: <code>\(authenticated)</code></p>"
        body += controlLink(label: SpikeAnchor.loginControlLink, path: SpikeContract.Path.vaultControl)
        body += controlLink(label: SpikeAnchor.loginTransferLink, path: SpikeContract.Path.vaultTransfer)
        body += secondaryLink(label: "back to fixture menu", path: SpikeContract.Path.menu)
        return page(title: "Signed in", body: body)
    }

    /// Cookie scope setup page.
    static func scopeSetup() -> String {
        var body = "<p>Scope markers were set by this response.</p>"
        body += controlLink(label: SpikeAnchor.scopeProbeControlLink, path: SpikeContract.Path.scopeProbeControl)
        body += controlLink(label: SpikeAnchor.scopeProbeTransferLink, path: SpikeContract.Path.scopeProbeTransfer)
        let otherHostURL = SpikeContract.baseURLString(host: SpikeContract.secondaryHost)
            + SpikeContract.Path.scopeSetupOtherHost
        body += controlLink(label: SpikeAnchor.scopeOtherHostLink, absoluteURL: otherHostURL)
        body += secondaryLink(label: "back to fixture menu", path: SpikeContract.Path.menu)
        return page(title: "Cookie scope setup", body: body)
    }

    /// Secondary-origin page that sets the other-host marker cookie.
    static func scopeSetupOtherHost() -> String {
        var body = "<p>The other-host marker was set for \(SpikeContract.secondaryHost).</p>"
        let menuURL = SpikeContract.baseURLString(host: SpikeContract.primaryHost) + SpikeContract.Path.menu
        body += controlLink(label: "back to primary fixture menu", absoluteURL: menuURL)
        return page(title: "Other-host marker", body: body)
    }

    /// Guard page that offers a control and a transfer link for one case.
    static func guardPage(
        title: String,
        controlLabel: String?,
        controlPath: String?,
        transferLabel: String?,
        transferPath: String?,
        notes: String? = nil
    ) -> String {
        var body = notes.map { "<p>\($0)</p>" } ?? ""
        if let controlLabel, let controlPath {
            body += controlLink(label: controlLabel, path: controlPath)
        }
        if let transferLabel, let transferPath {
            body += controlLink(label: transferLabel, path: transferPath)
        }
        body += secondaryLink(label: "back to fixture menu", path: SpikeContract.Path.menu)
        return page(title: title, body: body)
    }

    /// Form page with a browser-native submit and an intercepted submit.
    static func postForm() -> String {
        let controlForm = """
        <form method="post" action="\(SpikeContract.Path.postControl)">
        <input name="note" value="control-body">
        <button class="control" type="submit">\(SpikeAnchor.postControlButton)</button>
        </form>
        """
        let transferForm = """
        <form method="post" action="\(SpikeContract.Path.postTransfer)">
        <input name="note" value="space &amp; amp=plus + snowman ☃">
        <button class="control" type="submit">\(SpikeAnchor.postTransferButton)</button>
        </form>
        """
        var body = "<h2>Browser-native post</h2>" + controlForm
        body += "<h2>Intercepted post</h2>" + transferForm
        body += secondaryLink(label: "back to fixture menu", path: SpikeContract.Path.menu)
        return page(title: "Post fixtures", body: body)
    }

    /// Page that mints two independent single-use tokens.
    static func signedMint(preRequestToken: String, responseTriggeredToken: String) -> String {
        var body = "<p>Two independent single-use tokens were minted.</p>"
        body += controlLink(
            label: SpikeAnchor.signedPreRequestLink,
            path: SpikeContract.Path.signedPreRequest + "?token=" + preRequestToken
        )
        body += controlLink(
            label: SpikeAnchor.signedResponseTriggeredLink,
            path: SpikeContract.Path.signedResponseTriggered + "?token=" + responseTriggeredToken
        )
        body += secondaryLink(label: "back to fixture menu", path: SpikeContract.Path.menu)
        return page(title: "Signed URL fixtures", body: body)
    }

    /// Page that generates a page-bound blob download.
    static func blobGuard() -> String {
        let script = """
        <script>
        function spikeBlobDownload() {
          const bytes = new Uint8Array(2048);
          for (let index = 0; index < bytes.length; index += 1) {
            bytes[index] = (index * 17) % 251;
          }
          const blob = new Blob([bytes], { type: 'application/octet-stream' });
          const url = URL.createObjectURL(blob);
          const anchor = document.createElement('a');
          anchor.href = url;
          anchor.download = 'blob.bin';
          anchor.textContent = 'blob download';
          document.body.appendChild(anchor);
          anchor.click();
        }
        </script>
        """
        var body = "<p>This control creates a <code>blob:</code> URL in the page process.</p>"
        body += "<button class=\"control\" onclick=\"spikeBlobDownload()\">"
        body += SpikeAnchor.blobTriggerButton + "</button>"
        body += secondaryLink(label: "back to fixture menu", path: SpikeContract.Path.menu)
        body += script
        return page(title: "Blob fixture", body: body)
    }

    /// Plain text page used for echo and probe responses.
    static func echoText(_ text: String) -> SpikeFixtureResponse {
        SpikeFixtureResponse.text(body: text + "\n")
    }
}
