"""PPCRL transport reconstructed from Authenticator 6.2611.7348.

Only registration/authentication of this SDK's own device identity, token exchange,
and reading backup encryption keys are implemented. No credentials are logged.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets
import struct
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Mapping
from urllib.parse import quote
from xml.dom import Node, minidom

import requests
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from lxml import etree

from ._errors import AuthenticationError, IntegrityError, NetworkError, ProtocolError

NS = {
    "s": "http://www.w3.org/2003/05/soap-envelope",
    "ps": "http://schemas.microsoft.com/Passport/SoapServices/PPCRL",
    "wsse": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd",
    "saml": "urn:oasis:names:tc:SAML:1.0:assertion",
    "wsp": "http://schemas.xmlsoap.org/ws/2004/09/policy",
    "wsu": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd",
    "wsa": "http://www.w3.org/2005/08/addressing",
    "wssc": "http://schemas.xmlsoap.org/ws/2005/02/sc",
    "wst": "http://schemas.xmlsoap.org/ws/2005/02/trust",
}
DS = "http://www.w3.org/2000/09/xmldsig#"
ENC = "http://www.w3.org/2001/04/xmlenc#"
APP_GUID = "{F501FD64-9070-46AB-993C-6F7B71D8D883}"
DA_SCOPE = "http://Passport.NET/tb"
STS_URL = "https://login.live.com/RST2.srf"
DEVICE_URL = "https://login.live.com/ppsecure/deviceaddcredential.srf"
KEY_URL = "https://login.live.com/ppsecure/GetUserKeyData.srf"
_MAX_XML = 8 * 1024 * 1024
_STS_LABEL = b"WS-SecureConversationWS-SecureConversation"


@dataclass(frozen=True)
class DAToken:
    token_xml: str = field(repr=False)
    session_key: bytes = field(repr=False)
    expires_at: float | None = None

    def __post_init__(self):
        if not self.token_xml or not self.session_key:
            raise ProtocolError("A DA token and its session key are required")


@dataclass(frozen=True)
class DeviceIdentity:
    username: str = field(repr=False)
    password: str = field(repr=False)
    puid: str = field(repr=False)
    da: DAToken = field(repr=False)


@dataclass(frozen=True)
class TicketResult:
    ticket: str | None = field(default=None, repr=False)
    refreshed_user_da: DAToken | None = field(default=None, repr=False)
    expires_at: float | None = None
    cid: str | None = field(default=None, repr=False)
    puid: str | None = field(default=None, repr=False)
    interactive_url: str | None = field(default=None, repr=False)
    error_code: str | None = None


class StsAuthenticationError(AuthenticationError):
    def __init__(self, message: str, code: str | None = None):
        self.code = _safe_code(code)
        super().__init__(message + (f" ({self.code})" if self.code else ""))


def _safe_code(code):
    if isinstance(code, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", code):
        return code
    return None


def _code_is(code: str | None, *values: int) -> bool:
    if not code:
        return False
    try:
        number = int(code, 10) if code.startswith("-") else int(code, 16)
    except ValueError:
        return False
    return (number & 0xffffffff) in {v & 0xffffffff for v in values}


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _unb64(text: str) -> bytes:
    try:
        return base64.b64decode("".join(text.split()), validate=True)
    except (ValueError, TypeError):
        raise ProtocolError("Invalid base64 in authentication response") from None


def derive_key(session_key: bytes, nonce: bytes, *, label: bytes = _STS_LABEL, length: int = 32) -> bytes:
    """SP800-108 counter-mode HMAC-SHA256 used by PPCRL (big-endian fields)."""
    out = bytearray()
    for counter in range(1, (length + 31) // 32 + 1):
        data = struct.pack(">I", counter) + label + b"\0" + nonce + struct.pack(">I", length * 8)
        out.extend(hmac.new(session_key, data, hashlib.sha256).digest())
    return bytes(out[:length])


def one_time_credential(da: DAToken, appid: str = APP_GUID, extras: Mapping[str, str] | None = None,
                        *, now: float | None = None, nonce: bytes | None = None) -> str:
    """Equivalent to OneTimeCredentialSigner; Android Uri.encode uses %20, not +."""
    nonce = secrets.token_bytes(32) if nonce is None else nonce
    pairs = [("ct", str(int(time.time() if now is None else now))), ("hashalg", "SHA256"),
             ("bver", "11"), ("appid", appid), ("da", da.token_xml), ("nonce", _b64(nonce))]
    if extras:
        if set(extras) & ({k for k, _ in pairs} | {"hash"}):
            raise ValueError("Reserved one-time credential parameter")
        pairs.extend(extras.items())
    enc = lambda s: quote(str(s), safe="_-!.~'()*")
    query = "&".join(enc(k) + "=" + enc(v) for k, v in pairs)
    key = derive_key(da.session_key, nonce, label=b"WS-SecureConversation")
    signature = _b64(hmac.new(key, query.encode("utf-8"), hashlib.sha256).digest())
    return query + "&hash=" + enc(signature)


def _q(name):
    if ":" in name:
        prefix, local = name.split(":", 1)
        return "{" + NS[prefix] + "}" + local
    return name


def _element(parent, name, text=None, **attrs):
    el = etree.SubElement(parent, _q(name))
    for key, value in attrs.items():
        el.set(_q(key), value)
    if text is not None:
        el.text = str(text)
    return el


def _parse(data: bytes | str):
    if isinstance(data, str):
        data = data.encode("utf-8")
    if len(data) > _MAX_XML or re.search(br"<!\s*(DOCTYPE|ENTITY)", data, re.I):
        raise ProtocolError("Unsafe or oversized authentication XML")
    try:
        return etree.fromstring(data, etree.XMLParser(resolve_entities=False, no_network=True,
                                remove_blank_text=False, huge_tree=False))
    except (etree.XMLSyntaxError, ValueError):
        raise ProtocolError("Invalid authentication XML") from None


def _nodes(node, name):
    return node.xpath(".//*[local-name()=$name]", name=name)


def _first(node, name):
    result = _nodes(node, name)
    return result[0] if result else None


def _text(node, name, default=None):
    item = _first(node, name)
    return item.text if item is not None and item.text is not None else default


def _error_code(root):
    # MSA prefers the detailed HRESULT to the outer error class.
    for name in ("ErrorSubcode", "code", "value"):
        value = _safe_code(_text(root, name))
        if value:
            return value
    error = _first(root, "Error")
    return _safe_code(error.get("Code")) if error is not None else None


def _epoch(value: str | None) -> float | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp()
    except (ValueError, TypeError, OverflowError):
        raise ProtocolError("Invalid expiration time in authentication response") from None


def _c14n(node):
    return etree.tostring(node, method="c14n", exclusive=True, with_comments=False)


def _serialize_request(root) -> bytes:
    wire = _c14n(root)
    # Retain bindings for QName-valued attributes (for example
    # ValueType="ps:LoginProofToken"), which exclusive C14N cannot detect.
    if etree.QName(root).localname == "Envelope":
        end = wire.index(b">")
        opening = wire[:end]
        for prefix, namespace in NS.items():
            declaration = f' xmlns:{prefix}="{namespace}"'.encode("ascii")
            if declaration not in opening:
                opening += declaration
        wire = opening + wire[end:]
    return wire


def _parse_token(node) -> tuple[DAToken | None, str | None, float | None, str | None]:
    token_type = _text(node, "TokenType")
    expires = _epoch(_text(node, "Expires"))
    token = _first(node, "RequestedSecurityToken")
    if token is None:
        return None, None, expires, _text(node, "Address")
    encrypted = _first(token, "EncryptedData")
    binary = _first(token, "BinarySecurityToken")
    value = etree.tostring(encrypted, encoding="unicode", with_tail=False) if encrypted is not None else (
        binary.text if binary is not None else None)
    if token_type == "urn:passport:legacy":
        key = _text(node, "BinarySecret")
        if not key or not value:
            raise ProtocolError("DA response omitted token or proof key")
        return DAToken(value, _unb64(key), expires), None, expires, _text(node, "Address")
    accepted = {"urn:passport:compact", "urn:passport:loginprooftoken", "urn:liveid:refreshtoken",
                "urn:passport:transfertoken", "urn:passport:delegationcompact"}
    if token_type in accepted and value:
        return None, value, expires, _text(node, "Address")
    return None, None, expires, _text(node, "Address")


def _raw_android(node) -> str:
    """BasePullParser.readRawOuterXml (expanded empty tags, declared namespaces first)."""
    if node.nodeType in (Node.TEXT_NODE, Node.CDATA_SECTION_NODE):
        return node.data
    if node.nodeType != Node.ELEMENT_NODE:
        return ""
    attrs = list(node.attributes.values())
    attrs = [a for a in attrs if a.name == "xmlns" or a.name.startswith("xmlns:")] + [
        a for a in attrs if a.name != "xmlns" and not a.name.startswith("xmlns:")]
    return "<" + node.tagName + "".join(' ' + a.name + '="' + a.value + '"' for a in attrs) + ">" + \
        "".join(_raw_android(c) for c in node.childNodes) + "</" + node.tagName + ">"


def _verify_response_signature(xml: bytes, tree, session_key: bytes) -> set[str]:
    signatures = tree.findall(".//{" + DS + "}Signature")
    if len(signatures) != 1:
        raise IntegrityError("Authentication response signature is missing or ambiguous")
    sig = signatures[0]
    info = sig.find("{" + DS + "}SignedInfo")
    if info is None:
        raise IntegrityError("Authentication response has no signed info")
    method = info.find("{" + DS + "}SignatureMethod")
    if method is None or method.get("Algorithm") != "http://www.w3.org/2001/04/xmldsig-more#hmac-sha256":
        raise IntegrityError("Unexpected authentication signature algorithm")
    sign_nonce = None
    for el in _nodes(tree, "DerivedKeyToken"):
        if el.get(_q("wsu:Id")) == "SignKey":
            sign_nonce = _unb64(_text(el, "Nonce", ""))
    if not sign_nonce:
        raise IntegrityError("Authentication signature nonce is missing")
    # DOM preserves original attribute order and declarations for APK-compatible signatures.
    try:
        dom = minidom.parseString(xml)
    except Exception:
        raise ProtocolError("Invalid signed authentication response") from None
    dom_infos = dom.getElementsByTagNameNS(DS, "SignedInfo")
    if len(dom_infos) != 1:
        raise IntegrityError("Ambiguous signed info")
    raw_info = _raw_android(dom_infos[0]).replace("<SignedInfo>", '<SignedInfo xmlns="' + DS + '">', 1)
    actual = _unb64(_text(sig, "SignatureValue", ""))
    key = derive_key(session_key, sign_nonce)
    if not any(hmac.compare_digest(actual, hmac.new(key, candidate, hashlib.sha256).digest())
               for candidate in (raw_info.encode("utf-8"), _c14n(info))):
        raise IntegrityError("Authentication response signature check failed")
    id_map = {}
    dom_id_map = {}
    for el in tree.iter():
        for ident in (el.get("Id"), el.get(_q("wsu:Id"))):
            if ident:
                if ident in id_map and id_map[ident] is not el:
                    raise IntegrityError("Duplicate signed element identifier")
                id_map[ident] = el
    for el in dom.getElementsByTagName("*"):
        ident = el.getAttribute("Id") or el.getAttributeNS(NS["wsu"], "Id")
        if ident:
            dom_id_map[ident] = el
    checked = set()
    for ref in info.findall("{" + DS + "}Reference"):
        uri = ref.get("URI", "")
        if not uri.startswith("#") or uri[1:] not in id_map or uri[1:] in checked:
            raise IntegrityError("Invalid authentication signature reference")
        ident = uri[1:]
        digest_method = ref.find("{" + DS + "}DigestMethod")
        if digest_method is None or digest_method.get("Algorithm") != ENC + "sha256":
            raise IntegrityError("Unexpected authentication digest algorithm")
        expected = _unb64(_text(ref, "DigestValue", ""))
        candidates = [_c14n(id_map[ident])]
        if ident in dom_id_map:
            candidates.append(_raw_android(dom_id_map[ident]).encode("utf-8"))
        if not any(hmac.compare_digest(expected, hashlib.sha256(c).digest()) for c in candidates):
            raise IntegrityError("Authentication response digest check failed")
        checked.add(ident)
    if not checked:
        raise IntegrityError("Empty authentication signature")
    return checked


def _decrypt(ciphertext: str, key: bytes):
    blob = _unb64(ciphertext)
    if len(blob) < 32 or len(blob) % 16:
        raise ProtocolError("Malformed encrypted authentication response")
    try:
        decryptor = Cipher(algorithms.AES(key), modes.CBC(blob[:16])).decryptor()
        padded = decryptor.update(blob[16:]) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        return unpadder.update(padded) + unpadder.finalize()
    except ValueError:
        raise IntegrityError("Authentication response decryption failed") from None


class SoapClient:
    def __init__(self, session: requests.Session | None = None, *, timeout: float = 30,
                 sdk_version: str = "2.1.0524.0520"):
        self.session = session if session is not None else requests.Session()
        self.timeout = timeout
        self.sdk_version = sdk_version
        self.clock_skew = 0.0

    def server_time(self):
        return time.time() + self.clock_skew

    def _post(self, url, root):
        # PPCRL checks the serialized signed fragments, including explicit
        # namespace declarations and expanded empty elements.
        data = _serialize_request(root)
        try:
            response = self.session.post(url, data=data, headers={"Content-Type": "application/soap+xml; charset=utf-8",
                    "User-Agent": "com.azure.authenticator/6.2611.7348; MsaAndroidSdk/" + self.sdk_version},
                                         timeout=self.timeout, allow_redirects=False, verify=True)
        except requests.RequestException:
            raise NetworkError("Authentication service could not be reached") from None
        if 300 <= response.status_code < 400:
            raise ProtocolError("Unexpected redirect from authentication service")
        if response.status_code == 429:
            raise NetworkError("Authentication service rate limit reached")
        if response.status_code >= 500 and not response.content.lstrip().startswith(b"<"):
            raise NetworkError(f"Authentication service returned HTTP {response.status_code}")
        date = response.headers.get("Date")
        if date:
            try:
                self.clock_skew = parsedate_to_datetime(date).timestamp() - time.time()
            except (ValueError, TypeError, OverflowError):
                pass
        return response.content, _parse(response.content)

    def _envelope(self, url, *, token_request=False, service=False, client_app_uri=None, flow_token=None):
        root = etree.Element(_q("s:Envelope"), nsmap=NS)
        header = _element(root, "s:Header")
        _element(header, "wsa:Action", "http://schemas.xmlsoap.org/ws/2005/02/trust/RST/Issue",
                 **{"s:mustUnderstand": "1"})
        _element(header, "wsa:To", url, **{"s:mustUnderstand": "1"})
        _element(header, "wsa:MessageID", str(int(self.server_time() * 1000)))
        auth = _element(header, "ps:AuthInfo", Id="PPAuthInfo")
        _element(auth, "ps:BinaryVersion", "11")
        _element(auth, "ps:DeviceType", "Android")
        if token_request:
            _element(auth, "ps:HostingApp", APP_GUID)
        if service:
            for key, value in [("InlineUX", "Android"), ("ConsentFlags", "1"), ("IsConnected", "1")]:
                _element(auth, "ps:" + key, value)
            if flow_token is not None:
                _element(auth, "ps:InlineFT", flow_token)
            _element(auth, "ps:ClientAppURI", client_app_uri)
        security = _element(header, "wsse:Security")
        body = _element(root, "s:Body")
        return root, auth, security, body

    def _timestamp(self, security):
        node = _element(security, "wsu:Timestamp", **{"wsu:Id": "Timestamp"})
        now = self.server_time()
        for name, ts in [("Created", now), ("Expires", now + 300)]:
            _element(node, "wsu:" + name, datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        return node

    @staticmethod
    def _token_request(parent, scope, policy, index):
        req = _element(parent, "wst:RequestSecurityToken", Id=f"RST{index}")
        _element(req, "wst:RequestType", "http://schemas.xmlsoap.org/ws/2005/02/trust/Issue")
        applies = _element(req, "wsp:AppliesTo")
        end = _element(applies, "wsa:EndpointReference")
        _element(end, "wsa:Address", scope)
        if policy:
            _element(req, "wsp:PolicyReference", URI=policy)
        return req

    @staticmethod
    def _derived_key(security, nonce):
        node = _element(security, "wssc:DerivedKeyToken", Algorithm="urn:liveid:SP800-108CTR-HMAC-SHA256",
                        **{"wsu:Id": "SignKey"})
        ref = _element(node, "wsse:RequestedTokenReference")
        _element(ref, "wsse:KeyIdentifier", ValueType="http://docs.oasis-open.org/wss/2004/XX/oasis-2004XX-wss-saml-token-profile-1.0#SAMLAssertionID")
        _element(ref, "wsse:Reference", URI="#DeviceDAToken")
        _element(node, "wssc:Nonce", _b64(nonce))

    @staticmethod
    def _sign(security, nodes, session_key, nonce):
        sig = etree.SubElement(security, "{" + DS + "}Signature", nsmap={None: DS})
        info = etree.SubElement(sig, "{" + DS + "}SignedInfo")
        etree.SubElement(info, "{" + DS + "}CanonicalizationMethod", Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#")
        etree.SubElement(info, "{" + DS + "}SignatureMethod", Algorithm="http://www.w3.org/2001/04/xmldsig-more#hmac-sha256")
        for node in nodes:
            ident = node.get("Id") or node.get(_q("wsu:Id"))
            ref = etree.SubElement(info, "{" + DS + "}Reference", URI="#" + ident)
            transforms = etree.SubElement(ref, "{" + DS + "}Transforms")
            etree.SubElement(transforms, "{" + DS + "}Transform", Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#")
            etree.SubElement(ref, "{" + DS + "}DigestMethod", Algorithm=ENC + "sha256")
            etree.SubElement(ref, "{" + DS + "}DigestValue").text = _b64(hashlib.sha256(_c14n(node)).digest())
        etree.SubElement(sig, "{" + DS + "}SignatureValue").text = _b64(
            hmac.new(derive_key(session_key, nonce), _c14n(info), hashlib.sha256).digest())
        key_info = etree.SubElement(sig, "{" + DS + "}KeyInfo")
        ref = _element(key_info, "wsse:SecurityTokenReference")
        _element(ref, "wsse:Reference", URI="#SignKey")

    def _check_expiry(self, root, *, required=False):
        timestamps = _nodes(root, "Timestamp")
        if required and not timestamps:
            raise ProtocolError("Authentication response timestamp is missing")
        for ts in timestamps:
            expires = _epoch(_text(ts, "Expires"))
            if required and expires is None:
                raise ProtocolError("Authentication response expiry is missing")
            if expires is not None and expires < self.server_time():
                raise AuthenticationError("Authentication response has expired")

    def provision_device(self) -> DeviceIdentity:
        alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}/?;:'\",.<>`~"
        for attempt in range(3):
            username = "02" + "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(18))
            password = "".join(secrets.choice(alphabet) for _ in range(16))
            root = etree.Element("DeviceAddRequest")
            etree.SubElement(root, "ClientInfo", name="MsaAndroidSdk/" + self.sdk_version, version="1.0")
            auth = etree.SubElement(root, "Authentication")
            etree.SubElement(auth, "Membername").text = username
            etree.SubElement(auth, "Password").text = password
            _, response = self._post(DEVICE_URL, root)
            if response.get("Success", "").lower() == "true":
                puid = _text(response, "puid") or _text(response, "PUID")
                if not puid:
                    raise ProtocolError("Device registration response omitted PUID")
                return DeviceIdentity(username, password, puid, self.authenticate_device(username, password))
            code = _error_code(response)
            # Only the credential collision/invalid-credential cases in the APK are retried.
            if attempt == 2 or not _code_is(code, -805307370, -2147186655):
                raise StsAuthenticationError("Device registration was rejected", code)
        raise AuthenticationError("Device registration exhausted its retry limit")

    def authenticate_device(self, username: str, password: str) -> DAToken:
        root, _, security, body = self._envelope(STS_URL, token_request=True)
        token = _element(security, "wsse:UsernameToken", **{"wsu:Id": "devicesoftware"})
        _element(token, "wsse:Username", username)
        _element(token, "wsse:Password", password)
        self._timestamp(security)
        self._token_request(body, DA_SCOPE, None, 0)
        _, response = self._post(STS_URL, root)
        self._check_expiry(response)
        for node in _nodes(response, "RequestSecurityTokenResponse"):
            da, _, _, _ = _parse_token(node)
            if da:
                self._check_expiry(response, required=True)
                return da
        raise StsAuthenticationError("Device authentication was rejected", _error_code(response))

    def refresh_device(self, device: DeviceIdentity) -> DeviceIdentity:
        try:
            return DeviceIdentity(device.username, device.password, device.puid,
                                  self.authenticate_device(device.username, device.password))
        except StsAuthenticationError as exc:
            if _code_is(exc.code, -805307371, -2147186655, -2147217390):
                return self.provision_device()
            raise

    def request_ticket(self, user_da: DAToken, device: DeviceIdentity, scope: str, policy: str | None,
                       client_app_uri: str, *, flow_token: str | None = None) -> TicketResult:
        root, auth, security, body = self._envelope(STS_URL, token_request=True, service=True,
                                                   client_app_uri=client_app_uri, flow_token=flow_token)
        security.append(_parse(user_da.token_xml))
        _element(security, "wsse:BinarySecurityToken",
                 one_time_credential(device.da, now=self.server_time()), ValueType="urn:liveid:sha1device", Id="DeviceDAToken")
        nonce = secrets.token_bytes(32)
        self._derived_key(security, nonce)
        timestamp = self._timestamp(security)
        collection = _element(body, "ps:RequestMultipleSecurityTokens", Id="RSTS")
        self._token_request(collection, DA_SCOPE, None, 0)
        self._token_request(collection, scope, policy, 1)
        self._sign(security, [auth, timestamp, collection], user_da.session_key, nonce)
        xml, response = self._post(STS_URL, root)
        return self.parse_service_response(xml, user_da.session_key, scope)

    def parse_service_response(self, xml: bytes, session_key: bytes, scope: str) -> TicketResult:
        response = _parse(xml)
        self._check_expiry(response)
        enc_nonce = None
        for node in _nodes(response, "DerivedKeyToken"):
            if node.get(_q("wsu:Id")) == "EncKey":
                enc_nonce = _unb64(_text(node, "Nonce", ""))
        if not enc_nonce:
            # Error responses may be unsigned; none of their identity/token data is accepted.
            raise StsAuthenticationError("Microsoft rejected the token request", _error_code(response) or _text(response, "reqstatus"))
        self._check_expiry(response, required=True)
        checked = _verify_response_signature(xml, response, session_key)
        for timestamp in _nodes(response, "Timestamp"):
            if (timestamp.get("Id") or timestamp.get(_q("wsu:Id"))) not in checked:
                raise IntegrityError("Authentication response timestamp is not signed")
        key = derive_key(session_key, enc_nonce)
        clear = []
        for node in _nodes(response, "EncryptedData"):
            cipher = _text(node, "CipherValue")
            if not cipher:
                raise ProtocolError("Encrypted authentication response omitted ciphertext")
            ancestor = node
            covered = False
            while ancestor is not None:
                if (ancestor.get("Id") or ancestor.get(_q("wsu:Id"))) in checked:
                    covered = True
                    break
                ancestor = ancestor.getparent()
            if not covered:
                raise IntegrityError("Encrypted authentication data is not signed")
            clear.append(_parse(_decrypt(cipher, key)))
        ticket = None
        refreshed_da = None
        expires = None
        interactive_url = None
        error_code = None
        cid = None
        puid = None
        for part in clear:
            interactive_url = _text(part, "inlineauthurl") or interactive_url
            puid = _text(part, "PUID") or puid
            for item in part.iter():
                if item.get("Name") == "CID":
                    cid = item.text
            status = _text(part, "reqstatus")
            if status and status.lower().removeprefix("0x").strip("0"):
                error_code = _safe_code(status)
            tokens = ([part] if etree.QName(part).localname == "RequestSecurityTokenResponse" else []) + _nodes(part, "RequestSecurityTokenResponse")
            for node in tokens:
                da, value, expiry, target = _parse_token(node)
                if da:
                    refreshed_da = da
                if value:
                    if target != scope:
                        raise ProtocolError("Authentication ticket target does not match requested scope")
                    ticket, expires = value, expiry
                interactive_url = _text(node, "inlineauthurl") or interactive_url
                status = _text(node, "reqstatus")
                if status and status.lower().removeprefix("0x").strip("0"):
                    error_code = _safe_code(status)
        if not ticket and not interactive_url:
            raise StsAuthenticationError("Microsoft did not issue the requested ticket", error_code)
        return TicketResult(ticket, refreshed_da, expires, cid, puid, interactive_url, error_code)

    def get_user_keys(self, device: DeviceIdentity, login_proof_token: str) -> dict[str, str]:
        root, auth, security, body = self._envelope(KEY_URL)
        _element(security, "wsse:BinarySecurityToken", login_proof_token, ValueType="ps:LoginProofToken", Id="LoginProofToken")
        ref = _element(security, "wsse:SecurityTokenReference")
        embedded = _element(ref, "wsse:Embedded", **{"wsu:Id": "DeviceDAToken"})
        binary = _element(embedded, "wsse:BinarySecurityToken", ValueType="urn:liveid:device", Id="DeviceDAToken")
        binary.append(_parse(device.da.token_xml))
        nonce = secrets.token_bytes(32)
        self._derived_key(security, nonce)
        timestamp = self._timestamp(security)
        req = _element(body, "ps:GetKeyDataRequest", version="1.0", Id="GKDR")
        purposes = _element(req, "ps:KeyPurposes")
        _element(purposes, "ps:KeyPurpose", "StrongCredentialKey")
        self._sign(security, [auth, timestamp, req], device.da.session_key, nonce)
        _, response = self._post(KEY_URL, root)
        data = _first(response, "GetKeyDataResponse")
        if data is None or data.get("Success", "").lower() != "true":
            err = _first(response, "Error")
            raise StsAuthenticationError("Microsoft did not release the backup encryption key", _error_code(response))
        keys = {}
        for purpose in _nodes(data, "KeyPurpose"):
            if purpose.get("name") != "StrongCredentialKey":
                continue
            for item in _nodes(purpose, "KeyData"):
                props = {p.get("name", "").lower(): p.text for p in _nodes(item, "Property")}
                stamp, material = props.get("timestamp"), props.get("keymaterial")
                if not stamp or not material:
                    raise ProtocolError("Backup encryption key response is incomplete")
                if stamp in keys:
                    raise ProtocolError("Duplicate backup encryption key identifier")
                _unb64(material)
                keys[stamp] = material
        if not keys:
            raise ProtocolError("No StrongCredentialKey was present in the response")
        return keys
