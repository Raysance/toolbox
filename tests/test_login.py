"""Exercise login transport and bridge without opening a window or an account."""
import base64
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import traceback

import pytest

from msauth_totp import _login


def properties():
    return {
        "DAToken": "<test-token/>", "DASessionKey": base64.b64encode(b"key").decode(),
        "CID": "0123456789abcdef", "PUID": "123", "SigninName": "example@example.test",
        "Password": "MUST_NOT_RETURN", "SmsCode": "123456",
    }


@pytest.mark.parametrize("url", [
    "http://login.live.com/", "https://login.live.com.evil.test/", "https://evil.test/",
    "https://user:secret@login.live.com/", "https://login.live.com:444/",
    "https://login.live.com:bad/", "https://[bad/",
])
def test_rejects_untrusted_or_malformed_bridge_origin(url):
    with pytest.raises(_login.LoginError):
        _login._validate_url(url)


def test_result_filters_password_and_requires_complete_session():
    result = _login._finish_properties(properties(), False)
    assert "Password" not in result
    assert "SmsCode" not in result
    assert result["CID"] == "0123456789abcdef"
    values = properties()
    del values["DASessionKey"]
    with pytest.raises(_login.LoginError):
        _login._finish_properties(values, False)
    assert _login._finish_properties({"STSInlineFlowToken": "flow"}, True) == {
        "STSInlineFlowToken": "flow"}


@pytest.mark.parametrize("code,expected", [
    ("0x80048842", "0x80048842"), ("80048842", "80048842"),
    ("-2147187134", "-2147187134"), ("SECRET_LOGIN_TOKEN", "unknown"),
    ("0x1234?token=secret", "unknown"), ("12345678901234567890", "unknown"),
])
def test_server_error_code_is_strictly_sanitized(code, expected):
    with pytest.raises(_login.LoginError) as caught:
        _login._finish_properties({"ErrorCode": code}, False)
    assert str(caught.value) == f"Microsoft sign-in failed (code {expected})."


def test_cancel_and_invalid_key():
    with pytest.raises(_login.LoginCancelled):
        _login._finish_properties({"ErrorCode": "1", "ExtendedErrorString": "80048842"}, False)
    values = properties()
    values["DASessionKey"] = "SENSITIVE_INVALID_KEY%%%"
    with pytest.raises(_login.LoginError) as caught:
        _login._finish_properties(values, False)
    assert caught.value.__cause__ is None
    assert caught.value.__suppress_context__
    assert "SENSITIVE_INVALID_KEY" not in "".join(traceback.format_exception(caught.value))


def test_javascript_bridge_contract_and_untrusted_origin():
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node is not installed")
    bridge = _login._bridge_script({"Username": "KEYS INITIAL HOSTS"})
    harness = """
const vm = require('node:vm');
function run(hostname) {
  const messages = [];
  const window = {webkit:{messageHandlers:{msauth:{postMessage:e=>messages.push(e)}}}};
  window.top = window;
  vm.runInNewContext(BRIDGE, {window, location:{hostname,protocol:'https:'}});
  return {window,messages};
}
const {window,messages} = run('login.live.com');
if(window.external.Property('Username') !== 'KEYS INITIAL HOSTS') throw Error('initial');
window.external.Property('CID','123');
if(window.external.Property('CID') !== '123') throw Error('read');
window.external.Property('UNKNOWN','ignored');
if(window.external.Property('UNKNOWN') !== null) throw Error('unknown key');
window.external.FinalNext();
if(messages[1].properties.CID !== '123') throw Error('complete');
window.external.FinalBack();
if(messages[2].kind !== 'cancel') throw Error('cancel');
if(run('evil.test').window.external) throw Error('untrusted origin');
""".replace("BRIDGE", json.dumps(bridge))
    result = subprocess.run([node, "-e", harness], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr


def test_parent_launches_package_file_and_passes_secrets_only_on_stdin(monkeypatch):
    monkeypatch.setattr(_login.sys, "platform", "darwin")
    captured = {}

    def run(args, **kwargs):
        captured.update(args=args, **kwargs)
        return subprocess.CompletedProcess(args, 0, json.dumps({"properties": properties()}), "")

    monkeypatch.setattr(_login.subprocess, "run", run)
    result = _login.interactive_login("https://login.live.com/", initial_properties={"Username": "private"})
    assert captured["args"] == [sys.executable, str(Path(_login.__file__).resolve()), "--native-window"]
    assert "private" not in str(captured["args"])
    assert json.loads(captured["input"])["properties"]["Username"] == "private"
    assert "Password" not in result


def test_timeout_does_not_expose_captured_native_output(monkeypatch):
    monkeypatch.setattr(_login.sys, "platform", "darwin")

    def run(*args, **kwargs):
        raise subprocess.TimeoutExpired(["SENSITIVE_ARG"], 1, output="SENSITIVE_TOKEN")

    monkeypatch.setattr(_login.subprocess, "run", run)
    with pytest.raises(_login.LoginError) as caught:
        _login.interactive_login("https://login.live.com/", timeout=1)
    assert caught.value.__cause__ is None
    assert caught.value.__suppress_context__
    assert "SENSITIVE_" not in "".join(traceback.format_exception(caught.value))


def test_real_helper_entrypoint_rejects_url_before_creating_application():
    # This executes the helper from its installed package path. The invalid URL
    # is rejected before NSApplication.sharedApplication(), so no UI is opened.
    result = subprocess.run(
        [sys.executable, str(Path(_login.__file__).resolve()), "--native-window"],
        input=json.dumps({"url": "https://invalid.example.test/"}),
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0
    response = json.loads(result.stdout)
    assert response.get("error")
    assert "properties" not in response


@pytest.mark.skipif(sys.platform != "darwin", reason="Cocoa is macOS only")
def test_native_delegate_protocols_import_without_creating_ui():
    if importlib.util.find_spec("objc") is None:
        pytest.skip("PyObjC is not installed")
    native_class = _login._native_delegate_class()
    assert native_class.__name__ == "MSAInlineLoginDelegate"
    assert native_class is _login._native_delegate_class()
    metadata = native_class.webView_decidePolicyForNavigationAction_decisionHandler_.__metadata__()
    block = metadata["arguments"][4]["callable"]
    assert block["retval"]["type"] == b"v"
    assert block["arguments"][1]["type"] == b"q"

@pytest.mark.skipif(sys.platform != "darwin", reason="Cocoa is macOS only")
def test_webkit_named_callbacks_complete_login_without_android_bridge():
    from types import SimpleNamespace
    from unittest.mock import Mock
    native = _login._native_delegate_class().alloc().init()
    native.properties = {}
    native.interrupt = False
    native.refresh_script = Mock()
    native.finish = Mock()
    origin = SimpleNamespace(protocol=lambda: "https", host=lambda: "login.live.com", port=lambda: 443)
    frame = SimpleNamespace(isMainFrame=lambda: True, securityOrigin=lambda: origin)
    def message(name, body):
        return SimpleNamespace(name=lambda: name, body=lambda: body, frameInfo=lambda: frame)
    for key, value in properties().items():
        native.userContentController_didReceiveScriptMessage_(
            None, message("Property", json.dumps({key: value})))
    native.properties["ErrorCode"] = "1"
    native.userContentController_didReceiveScriptMessage_(None, message("Property", '{"ErrorCode":null}'))
    assert "ErrorCode" not in native.properties
    native.userContentController_didReceiveScriptMessage_(None, message("FinalNext", ""))
    result = native.finish.call_args.args[0]["properties"]
    assert result["CID"] == properties()["CID"]
    assert "Password" not in result
    assert "SmsCode" not in result
    native.finish.reset_mock()
    native.userContentController_didReceiveScriptMessage_(None, message("FinalBack", ""))
    native.finish.assert_called_once_with({"cancelled": True})
    native.finish.reset_mock()
    origin.host = lambda: "evil.test"
    native.userContentController_didReceiveScriptMessage_(None, message("FinalNext", ""))
    native.finish.assert_not_called()
