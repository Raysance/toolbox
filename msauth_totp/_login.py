"""Microsoft's InlineConnect JavaScript bridge hosted in macOS WebKit.

The bridge contract is from the supplied APK's JavaScriptBridge, PropertyBag,
AddAccountActivity and WebFlowActivity. A short-lived helper process owns the
Cocoa main thread; neither credentials nor cookies are saved to disk.
"""
from __future__ import annotations

import base64
from functools import lru_cache
import json
import math
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlencode, urlsplit


class LoginError(RuntimeError):
    """An interactive Microsoft sign-in could not complete."""


class LoginCancelled(LoginError):
    """The user closed or cancelled the sign-in window."""


_BRIDGE_HOSTS = frozenset({
    "login.live.com", "account.live.com", "signup.live.com",
    "login.microsoftonline.com",
})
_PROPERTY_KEYS = frozenset({
    "CID", "DAToken", "DASessionKey", "DAExpires", "ErrorCode", "ErrorString",
    "ExtendedErrorString", "ErrorURL", "Password", "PUID", "STSInlineFlowToken",
    "Username", "PfUsernames", "PfFirstName", "PfLastName", "PfDeviceEmail",
    "PfPhone", "PfCountryCode", "SmsCode", "IsSignUp", "SigninName",
    "TelemetryAppVersion", "TelemetryDeviceYearClass", "TelemetryIsRequestorMaster",
    "TelemetryNetworkType", "TelemetryPrecaching", "TelemetryResourceBundleHits",
    "TelemetryResourceBundleMisses", "TelemetryResourceBundleVersion",
})
_MESSAGE_HANDLERS = ("msauth", "Property", "FinalNext", "FinalBack", "ReportTelemetry")

_RESULT_KEYS = frozenset({
    "CID", "PUID", "DAToken", "DASessionKey", "DAExpires", "SigninName",
    "PfFirstName", "PfLastName", "STSInlineFlowToken",
})


def _validate_url(url: str) -> str:
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except (ValueError, TypeError):
        raise LoginError("The sign-in URL is invalid.") from None
    if (parsed.scheme != "https" or parsed.hostname not in _BRIDGE_HOSTS
            or parsed.username or parsed.password or port not in (None, 443)):
        raise LoginError("The sign-in URL is not a supported Microsoft HTTPS endpoint.")
    return url


def _clean_properties(properties: dict | None) -> dict[str, str]:
    if properties is None:
        return {}
    if not isinstance(properties, dict):
        raise LoginError("The Microsoft login property bag is invalid.")
    return {str(k): str(v) for k, v in properties.items()
            if k in _PROPERTY_KEYS and v is not None}


def _finish_properties(properties: dict, interrupt: bool) -> dict[str, str]:
    values = _clean_properties(properties)
    if values.get("ErrorCode"):
        if "80048842" in values.get("ExtendedErrorString", "").lower():
            raise LoginCancelled("Microsoft sign-in was cancelled.")
        # Server error text and URLs can contain credentials; expose only the code.
        raw_code = values["ErrorCode"]
        code = raw_code if re.fullmatch(r"(?:-?\d{1,12}|(?:0[xX])?[0-9A-Fa-f]{1,8})", raw_code) else "unknown"
        raise LoginError("Microsoft sign-in failed (code " + code + ").")
    required = ("STSInlineFlowToken",) if interrupt else (
        "DAToken", "DASessionKey", "SigninName", "CID", "PUID")
    if any(not values.get(key) for key in required):
        raise LoginError("Microsoft sign-in did not return the required session fields.")
    if bool(values.get("DAToken")) != bool(values.get("DASessionKey")):
        raise LoginError("Microsoft returned an incomplete DA token.")
    if values.get("DASessionKey"):
        try:
            key = base64.b64decode(values["DASessionKey"], validate=True)
        except (ValueError, TypeError):
            raise LoginError("Microsoft returned an invalid DA session key.") from None
        if not key:
            raise LoginError("Microsoft returned an empty DA session key.")
    return {key: value for key, value in values.items() if key in _RESULT_KEYS}


def _bridge_script(properties: dict | None = None) -> str:
    """Synchronous Property reads, with native persistence across page navigation."""
    state = json.dumps(_clean_properties(properties), ensure_ascii=True)
    hosts = json.dumps(sorted(_BRIDGE_HOSTS))
    keys = json.dumps(sorted(_PROPERTY_KEYS))
    return r"""(() => {
      if (window !== window.top || location.protocol !== 'https:' ||
          !HOSTS.includes(location.hostname)) return;
      const bag = Object.assign(Object.create(null), INITIAL);
      const keys = new Set(KEYS);
      const send = (event) => window.webkit.messageHandlers.msauth.postMessage(event);
      const bridge = {
        Property: function(key, value) {
          if (!keys.has(key)) return null;
          if (arguments.length > 1) {
            bag[key] = value == null ? null : String(value);
            send({kind: 'property', key: key, value: bag[key]});
            return;
          }
          return Object.prototype.hasOwnProperty.call(bag, key) ? bag[key] : null;
        },
        FinalNext: function() { send({kind: 'complete', properties: bag}); },
        FinalBack: function() { send({kind: 'cancel'}); },
        ReportTelemetry: function() {}
      };
      Object.defineProperty(window, 'external', {value: bridge, configurable: false});
    })();""".replace("HOSTS", hosts).replace("KEYS", keys).replace("INITIAL", state)


def interactive_login(
    url: str, *, initial_properties: dict | None = None,
    timeout: float = 900, interrupt: bool = False,
    app_properties: dict[str, str] | None = None,
    user_agent_suffix: str = "",
) -> dict[str, str]:
    """Show Microsoft's login/MFA page and return the captured session.

    Normal login returns DAToken, DASessionKey, CID, PUID and SigninName.
    An interrupt returns STSInlineFlowToken and any refreshed DA fields.
    The user enters credentials into Microsoft's own page inside the SDK window.
    """
    _validate_url(url)
    if sys.platform != "darwin":
        raise LoginError("Interactive login requires macOS.")
    if not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout must be a positive finite number")
    request = {"url": url, "properties": _clean_properties(initial_properties),
               "interrupt": bool(interrupt), "app_properties": app_properties or {},
               "user_agent_suffix": user_agent_suffix}
    try:
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--native-window"],
            input=json.dumps(request), capture_output=True, text=True, timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise LoginError("Microsoft sign-in timed out.") from None
    except OSError:
        raise LoginError("Could not start the macOS sign-in window.") from None
    try:
        response = json.loads(completed.stdout)
    except (ValueError, TypeError):
        raise LoginError("The macOS sign-in window exited unexpectedly.") from None
    if not isinstance(response, dict):
        raise LoginError("The macOS sign-in window returned an invalid response.")
    if response.get("cancelled"):
        raise LoginCancelled("Microsoft sign-in was cancelled.")
    if response.get("error"):
        raise LoginError(str(response["error"]))
    if completed.returncode:
        raise LoginError("The macOS sign-in window failed.")
    return _finish_properties(response.get("properties", {}), interrupt)


@lru_cache(maxsize=1)
def _native_delegate_class():
    """Import/define native delegates without creating windows (also testable)."""
    import objc
    import AppKit
    import Foundation
    import WebKit

    # Use WebKit's complete NSObject selector metadata. Explicitly adopting its
    # formal protocols replaces the navigation callback metadata with a bare
    # @? signature on some PyObjC releases, making its decision block uncallable.
    class MSAInlineLoginDelegate(Foundation.NSObject):
        @objc.python_method
        def initialize(self, app, window, controller, properties, interrupt):
            self.app = app
            self.window = window
            self.controller = controller
            self.properties = _clean_properties(properties)
            self.interrupt = interrupt
            self.result = None
            self.webview = None
            self.popups = []
            self.refresh_script()

        @objc.python_method
        def refresh_script(self):
            script = WebKit.WKUserScript.alloc().initWithSource_injectionTime_forMainFrameOnly_(
                _bridge_script(self.properties), WebKit.WKUserScriptInjectionTimeAtDocumentStart, True)
            self.controller.removeAllUserScripts()
            self.controller.addUserScript_(script)

        @objc.python_method
        def finish(self, result):
            if self.result is not None:
                return
            self.result = result
            if self.webview is not None:
                self.webview.stopLoading()
            for popup, webview in self.popups:
                webview.stopLoading()
                popup.orderOut_(None)
            self.window.orderOut_(None)
            self.app.stop_(None)
            # Wake NSApplication.run even when stop_ originates in a delegate.
            event = AppKit.NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
                AppKit.NSEventTypeApplicationDefined, (0, 0), 0, 0, 0, None, 0, 0, 0)
            self.app.postEvent_atStart_(event, True)

        def userContentController_didReceiveScriptMessage_(self, controller, message):
            try:
                frame = message.frameInfo()
                if not frame.isMainFrame():
                    return
                origin = frame.securityOrigin()
                if (str(origin.protocol()) != "https" or str(origin.host()) not in _BRIDGE_HOSTS
                        or int(origin.port()) not in (0, 443)):
                    return
                raw = message.body()
                name = str(message.name())
                if name == "Property":
                    incoming = json.loads(raw) if isinstance(raw, str) else raw
                    if not hasattr(incoming, "items"):
                        raise LoginError("Microsoft returned an invalid login property message.")
                    for key, value in incoming.items():
                        if key in _PROPERTY_KEYS:
                            if value is None or value is Foundation.NSNull.null():
                                self.properties.pop(key, None)
                            else:
                                self.properties[key] = str(value)
                    self.refresh_script()
                    return
                if name == "FinalNext":
                    event = {"kind": "complete"}
                elif name == "FinalBack":
                    event = {"kind": "cancel"}
                elif name == "ReportTelemetry":
                    return
                else:
                    event = dict(raw) if hasattr(raw, "items") else None
                if event is None:
                    return
                kind = event.get("kind")
                if kind == "property":
                    key = event.get("key")
                    if key in _PROPERTY_KEYS:
                        value = event.get("value")
                        if value is None or value is Foundation.NSNull.null():
                            self.properties.pop(key, None)
                        else:
                            self.properties[key] = str(value)
                        self.refresh_script()
                elif kind == "cancel":
                    self.finish({"cancelled": True})
                elif kind == "complete":
                    incoming = event.get("properties")
                    if hasattr(incoming, "items"):
                        self.properties.update(_clean_properties(dict(incoming)))
                    result = _finish_properties(self.properties, self.interrupt)
                    self.finish({"properties": result})
            except LoginCancelled:
                self.finish({"cancelled": True})
            except LoginError as exc:
                self.finish({"error": str(exc)})
            except Exception:
                self.finish({"error": "Could not process the Microsoft sign-in response."})

        def windowShouldClose_(self, sender):
            if sender == self.window:
                self.finish({"cancelled": True})
            else:
                for popup, webview in self.popups:
                    if popup == sender:
                        webview.stopLoading()
                        popup.orderOut_(None)
                self.window.makeKeyAndOrderFront_(None)
            return True

        def webView_decidePolicyForNavigationAction_decisionHandler_(self, view, action, handler):
            # Restrict transports, while permitting Microsoft's federated login pages.
            url = action.request().URL()
            scheme = str(url.scheme()) if url is not None else ""
            if scheme in ("https", "about"):
                self.refresh_script()
                handler(WebKit.WKNavigationActionPolicyAllow)
            else:
                handler(WebKit.WKNavigationActionPolicyCancel)

        def webView_createWebViewWithConfiguration_forNavigationAction_windowFeatures_(
            self, view, configuration, action, features
        ):
            # Retain WebKit's supplied configuration and opener relationship for
            # Microsoft's out-of-band verification pages.
            target = action.request().URL()
            if target is not None and str(target.scheme()) == "https":
                style = (AppKit.NSWindowStyleMaskTitled | AppKit.NSWindowStyleMaskClosable |
                         AppKit.NSWindowStyleMaskResizable)
                popup = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                    ((0, 0), (520, 730)), style, AppKit.NSBackingStoreBuffered, False)
                popup.setTitle_("Microsoft account verification")
                popup.setReleasedWhenClosed_(False)
                child = WebKit.WKWebView.alloc().initWithFrame_configuration_(
                    popup.contentView().bounds(), configuration)
                child.setAutoresizingMask_(AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
                child.setNavigationDelegate_(self)
                child.setUIDelegate_(self)
                popup.setContentView_(child)
                popup.setDelegate_(self)
                self.popups.append((popup, child))
                popup.center()
                popup.makeKeyAndOrderFront_(None)
                return child
            return None

        def webViewDidClose_(self, view):
            for popup, child in self.popups:
                if child == view:
                    popup.close()
                    self.window.makeKeyAndOrderFront_(None)
                    return

        def webView_didFailProvisionalNavigation_withError_(self, view, navigation, error):
            if int(error.code()) == -999:  # Superseded navigation, not a failed login.
                return
            self.finish({"error": "The Microsoft sign-in page could not be loaded (network/TLS error)."})

        def webView_didFailNavigation_withError_(self, view, navigation, error):
            self.webView_didFailProvisionalNavigation_withError_(view, navigation, error)

        def webViewWebContentProcessDidTerminate_(self, view):
            self.finish({"error": "The Microsoft sign-in web process terminated."})

    return MSAInlineLoginDelegate


def _run_native(request: dict) -> dict:
    import AppKit
    import Foundation
    import WebKit

    _validate_url(request["url"])
    app = AppKit.NSApplication.sharedApplication()
    app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyRegular)
    style = (AppKit.NSWindowStyleMaskTitled | AppKit.NSWindowStyleMaskClosable |
             AppKit.NSWindowStyleMaskMiniaturizable | AppKit.NSWindowStyleMaskResizable)
    window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        ((0, 0), (520, 730)), style, AppKit.NSBackingStoreBuffered, False)
    window.setTitle_("Microsoft account sign-in")
    window.setReleasedWhenClosed_(False)
    window.setMinSize_((420, 540))
    controller = WebKit.WKUserContentController.alloc().init()
    delegate = _native_delegate_class().alloc().init()
    delegate.initialize(app, window, controller, request.get("properties"), bool(request.get("interrupt")))
    for name in _MESSAGE_HANDLERS:
        controller.addScriptMessageHandler_name_(delegate, name)
    configuration = WebKit.WKWebViewConfiguration.alloc().init()
    configuration.setUserContentController_(controller)
    configuration.setWebsiteDataStore_(WebKit.WKWebsiteDataStore.nonPersistentDataStore())
    configuration.preferences().setJavaScriptCanOpenWindowsAutomatically_(True)
    suffix = request.get("user_agent_suffix")
    if suffix:
        configuration.setApplicationNameForUserAgent_(str(suffix))
    webview = WebKit.WKWebView.alloc().initWithFrame_configuration_(
        window.contentView().bounds(), configuration)
    webview.setAutoresizingMask_(AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    webview.setNavigationDelegate_(delegate)
    webview.setUIDelegate_(delegate)
    delegate.webview = webview
    window.setDelegate_(delegate)
    window.setContentView_(webview)
    native_request = Foundation.NSMutableURLRequest.requestWithURL_(
        Foundation.NSURL.URLWithString_(request["url"]))
    app_properties = request.get("app_properties") or {}
    if app_properties:
        native_request.setValue_forHTTPHeaderField_(
            urlencode(sorted(app_properties.items())), "ms-identity-app-properties")
    window.center()
    window.makeKeyAndOrderFront_(None)
    app.activateIgnoringOtherApps_(True)
    webview.loadRequest_(native_request)
    app.run()
    for name in _MESSAGE_HANDLERS:
        controller.removeScriptMessageHandlerForName_(name)
    for popup, child in delegate.popups:
        child.stopLoading()
        popup.close()
    window.close()
    return delegate.result or {"cancelled": True}


def _main() -> None:
    try:
        request = json.loads(sys.stdin.read())
        response = _run_native(request)
    except ImportError:
        response = {"error": "macOS WebKit support is missing; install the SDK's declared PyObjC dependencies."}
    except Exception:
        response = {"error": "Could not initialize the macOS sign-in window."}
    sys.stdout.write(json.dumps(response))
    sys.stdout.flush()


if __name__ == "__main__":
    if sys.argv[1:] == ["--native-window"]:
        _main()
    else:
        raise SystemExit("This module is an internal SDK login helper.")
