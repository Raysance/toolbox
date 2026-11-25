"""The SDK's two operations: login and read the account's backed-up TOTP keys."""
from __future__ import annotations

import base64
from dataclasses import dataclass, field
import json
import math
import threading
from urllib.parse import urlencode

import requests

from ._backup import AFS_POLICY, AFS_SCOPE, TotpKey, backup_id, read_cloud_backup, decrypt_backup, extract_totp_keys
from ._errors import AuthenticationError, LoginCancelledError, ProtocolError
from ._login import interactive_login, LoginError, LoginCancelled
from ._soap import DAToken, DeviceIdentity, SoapClient, StsAuthenticationError, _epoch, _code_is

_CLIENT_URI = "android-app://com.azure.authenticator.Q2GTRUJN356ZSJWGVNIK2LBJJVJ2P5V5"
_SDK_VERSION = "2.1.0524.0520"
_KEY_SCOPE = "http://Passport.NET/purpose"
_KEY_POLICY = "PURPOSE_GETKEYDATA_ROAMING"
_DEVICE_ERRORS = (-2147186627, -2147188631, -2147217369)


def _positive_timeout(value: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0:
        raise ValueError("timeout must be a positive finite number")
    return float(value)


def _da_from_properties(properties: dict) -> DAToken:
    try:
        return DAToken(properties["DAToken"],
                       base64.b64decode(properties["DASessionKey"], validate=True),
                       _epoch(properties.get("DAExpires")))
    except (KeyError, ValueError, TypeError):
        raise ProtocolError("Microsoft returned an incomplete login session.") from None


def _native_login(url: str, timeout: float, *, interrupt=False, initial_properties=None):
    try:
        return interactive_login(url, timeout=timeout, interrupt=interrupt,
                                 initial_properties=initial_properties,
                                 user_agent_suffix="com.azure.authenticator/6.2611.7348; MsaAndroidSdk/" + _SDK_VERSION)
    except LoginCancelled:
        raise LoginCancelledError("Microsoft sign-in was cancelled.") from None
    except LoginError as exc:
        raise AuthenticationError(str(exc)) from None


@dataclass
class LoginState:
    """Reusable login state. JSON export contains credentials; nothing is saved automatically.

    Public fields identify the recovery account. TOTP keys are not stored here.
    Reuse one state sequentially, or let the SDK serialize concurrent calls.
    """
    cid: str
    username: str
    _puid: str = field(repr=False)
    _user_da: DAToken = field(repr=False)
    _device: DeviceIdentity = field(repr=False)
    _afs_ticket: str | None = field(default=None, repr=False)
    _afs_expires: float | None = field(default=None, repr=False)
    _lock: threading.RLock = field(default_factory=threading.RLock, init=False, repr=False, compare=False)

    def to_json(self) -> str:
        """Export credentials for caller-controlled secure persistence."""
        def da(value):
            return {"token": value.token_xml,
                    "key": base64.b64encode(value.session_key).decode("ascii"),
                    "expires": value.expires_at}
        with self._lock:
            return json.dumps({
                "version": 1, "cid": self.cid, "username": self.username, "puid": self._puid,
                "user_da": da(self._user_da),
                "device": {"username": self._device.username, "password": self._device.password,
                           "puid": self._device.puid, "da": da(self._device.da)},
                "afs_ticket": self._afs_ticket, "afs_expires": self._afs_expires,
            }, separators=(",", ":"), ensure_ascii=True, allow_nan=False)

    @classmethod
    def from_json(cls, value: str) -> LoginState:
        """Import a previous ``to_json`` value; this alone does not validate it online."""
        def string(v):
            if not isinstance(v, str) or not v:
                raise ValueError()
            return v
        def expiry(v):
            if v is not None and (type(v) not in (int, float) or not math.isfinite(v)):
                raise ValueError()
            return v
        def da(v):
            return DAToken(string(v["token"]), base64.b64decode(string(v["key"]), validate=True), expiry(v.get("expires")))
        try:
            if not isinstance(value, str) or len(value) > 2 * 1024 * 1024:
                raise ValueError()
            obj = json.loads(value)
            if obj["version"] != 1:
                raise ValueError()
            cid = string(obj["cid"])
            backup_id(cid)
            device = obj["device"]
            ticket = obj.get("afs_ticket")
            if ticket is not None:
                string(ticket)
            return cls(cid, string(obj["username"]), string(obj["puid"]), da(obj["user_da"]),
                       DeviceIdentity(string(device["username"]), string(device["password"]),
                                      string(device["puid"]), da(device["da"])),
                       ticket, expiry(obj.get("afs_expires")))
        except (ValueError, TypeError, KeyError, AttributeError, ProtocolError):
            raise ProtocolError("Invalid or unsupported serialized login state.") from None


def _update_identity(state: LoginState, result):
    if result.cid and result.cid.lower() != state.cid.lower():
        raise AuthenticationError("The authentication response belongs to another account.")
    if result.puid and result.puid.lower() != state._puid.lower():
        raise AuthenticationError("The authentication response belongs to another account.")
    if result.refreshed_user_da:
        state._user_da = result.refreshed_user_da


def _ticket(soap: SoapClient, state: LoginState, scope: str, policy: str, interactive_timeout: float):
    if state._device.da.expires_at is None or state._device.da.expires_at <= soap.server_time() + 60:
        state._device = soap.refresh_device(state._device)
    flow_token = None
    retried_device = False
    for _ in range(5):
        try:
            result = soap.request_ticket(state._user_da, state._device, scope, policy,
                                         _CLIENT_URI, flow_token=flow_token)
        except StsAuthenticationError as exc:
            if not retried_device and _code_is(exc.code, *_DEVICE_ERRORS):
                retried_device = True
                state._device = soap.refresh_device(state._device)
                continue
            raise
        _update_identity(state, result)
        if result.ticket:
            return result
        if not result.interactive_url:
            raise AuthenticationError("Microsoft did not return a usable authentication ticket.")
        values = _native_login(result.interactive_url, interactive_timeout, interrupt=True)
        if values.get("CID") and values["CID"].lower() != state.cid.lower():
            raise AuthenticationError("Verification was completed with a different account.")
        if values.get("PUID") and values["PUID"].lower() != state._puid.lower():
            raise AuthenticationError("Verification was completed with a different account.")
        if values.get("DAToken"):
            state._user_da = _da_from_properties(values)
        flow_token = values["STSInlineFlowToken"]
    raise AuthenticationError("Microsoft verification did not complete within the supported retry limit.")


def login(username: str | None = None, *, state: LoginState | str | None = None,
          timeout: float = 30, interactive_timeout: float = 900) -> LoginState:
    """Authenticate in the SDK's macOS window and return reusable login state.

    ``username`` is an optional login hint. Microsoft handles passwords and MFA.
    Pass a previous LoginState (or its JSON) as ``state`` to validate/renew it.
    A rejected saved session raises AuthenticationError; call login() to sign in.
    """
    timeout, interactive_timeout = _positive_timeout(timeout), _positive_timeout(interactive_timeout)
    if username is not None and (not isinstance(username, str) or not username):
        raise ValueError("username must be a nonempty string")
    if isinstance(state, str):
        state = LoginState.from_json(state)
    if state is not None and not isinstance(state, LoginState):
        raise TypeError("state must be LoginState or its JSON representation")
    if state is not None and username is not None and username.lower() != state.username.lower():
        raise ValueError("username does not match the saved login state")
    with requests.Session() as http:
        soap = SoapClient(http, timeout=timeout)
        if state is None:
            device = soap.provision_device()
            params = {"id": "80601", "platform": "android" + _SDK_VERSION,
                      "client_id": _CLIENT_URI, "mkt": "en-US"}
            if username:
                params["username"] = username
            values = _native_login("https://login.live.com/ppsecure/InlineConnect.srf?" + urlencode(params),
                                   interactive_timeout)
            backup_id(values["CID"])
            user_da = _da_from_properties(values)
            state = LoginState(values["CID"], values["SigninName"], values["PUID"], user_da, device)
        with state._lock:
            result = _ticket(soap, state, AFS_SCOPE, AFS_POLICY, interactive_timeout)
            state._afs_ticket, state._afs_expires = result.ticket, result.expires_at
        return state


def get_totp_keys(state: LoginState, *, timeout: float = 30,
                  interactive_timeout: float = 900) -> tuple[TotpKey, ...]:
    """Read TOTP secrets present in this recovery account's Android MSA backup.

    Verification requested by Microsoft is handled in the same native window.
    Missing backup, rejected login, and decryption failure raise distinct errors.
    No account is added/deleted and the cloud backup is never changed.
    """
    if not isinstance(state, LoginState):
        raise TypeError("state must be a LoginState returned by login()")
    timeout, interactive_timeout = _positive_timeout(timeout), _positive_timeout(interactive_timeout)
    with state._lock, requests.Session() as http:
        soap = SoapClient(http, timeout=timeout)
        if not state._afs_ticket or state._afs_expires is None or state._afs_expires <= soap.server_time() + 60:
            result = _ticket(soap, state, AFS_SCOPE, AFS_POLICY, interactive_timeout)
            state._afs_ticket, state._afs_expires = result.ticket, result.expires_at
        try:
            cloud = read_cloud_backup(http, state.cid, state._afs_ticket, timeout)
        except AuthenticationError:
            result = _ticket(soap, state, AFS_SCOPE, AFS_POLICY, interactive_timeout)
            state._afs_ticket, state._afs_expires = result.ticket, result.expires_at
            cloud = read_cloud_backup(http, state.cid, state._afs_ticket, timeout)
        proof = _ticket(soap, state, _KEY_SCOPE, _KEY_POLICY, interactive_timeout)
        for attempt in range(2):
            try:
                keys = soap.get_user_keys(state._device, proof.ticket)
                break
            except StsAuthenticationError as exc:
                if attempt:
                    raise
                if _code_is(exc.code, *_DEVICE_ERRORS):
                    state._device = soap.refresh_device(state._device)
                elif _code_is(exc.code, -2147217396):
                    proof = _ticket(soap, state, _KEY_SCOPE, _KEY_POLICY, interactive_timeout)
                else:
                    raise
        material = keys.get(cloud["msaKeyId"])
        if material is None:
            raise AuthenticationError("Microsoft did not return the encryption key required by this backup.")
        return extract_totp_keys(decrypt_backup(cloud["encryptedBackup"], material))
