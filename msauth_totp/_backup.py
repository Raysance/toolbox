"""Read-only Authenticator Android MSA backup protocol, APK 6.2611.7348."""
from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass, field
import hashlib
import hmac
import json
import re
import struct
import uuid

import requests
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.keywrap import aes_key_unwrap, InvalidUnwrap

from ._errors import (
    AuthenticationError, BackupFormatError, BackupNotFoundError, IntegrityError,
    NetworkError, UnsupportedBackupError,
)

AFS_SCOPE = "scope=UserSettings.ReadWrite.CreatedByApp"
AFS_POLICY = "TOKEN_BROKER"
AFS_URL = "https://activity.windows.com/v2/feeds/me/activities/"
_HEADER = b'{"alg":"A128KW","enc":"A128CBC-HS256"}'
_MAX_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class TotpKey:
    """A stored TOTP secret; ``secret`` is the original Authenticator string."""
    account_name: str
    username: str
    secret: str = field(repr=False)
    account_type: str = "third_party"
    enabled: bool = True
    hidden: bool = False


def backup_id(cid: str) -> str:
    # BackupRestoreUseCase.deriveBackupUuidFromCid repeats the CID nibbles.
    if not isinstance(cid, str) or not re.fullmatch(r"[0-9a-fA-F]{1,16}", cid):
        raise BackupFormatError("Invalid Microsoft account CID.")
    return str(uuid.UUID(hex=(cid * (32 // len(cid) + 1))[:32]))


def _b64url(value: str) -> bytes:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]*={0,2}", value):
        raise BackupFormatError("Invalid base64url backup data.")
    try:
        return base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
    except (ValueError, binascii.Error):
        raise BackupFormatError("Invalid base64url backup data.") from None


def _json(value):
    try:
        return json.loads(value)
    except (ValueError, UnicodeError, TypeError):
        raise BackupFormatError("Invalid backup JSON.") from None


def read_cloud_backup(http: requests.Session, cid: str, ticket: str, timeout: float) -> dict:
    """Only GET is used: reading never rewrites/restores/deletes a cloud backup."""
    if not ticket or any(c in ticket for c in "\r\n"):
        raise AuthenticationError("Missing or invalid backup access token.")
    try:
        with http.get(
            AFS_URL + backup_id(cid), headers={"Authorization": "Bearer " + ticket},
            timeout=timeout, allow_redirects=False, stream=True,
        ) as response:
            if response.status_code == 404:
                raise BackupNotFoundError("No Android MSA cloud backup was found for this recovery account.")
            if response.status_code in (401, 403):
                raise AuthenticationError("Microsoft rejected the backup access token.")
            if response.status_code != 200:
                raise NetworkError("Backup request failed (HTTP %d)." % response.status_code)
            data = bytearray()
            for chunk in response.iter_content(65536):
                data.extend(chunk)
                if len(data) > _MAX_BYTES:
                    raise BackupFormatError("Backup response exceeds the supported size.")
    except requests.RequestException:
        raise NetworkError("Could not read the Authenticator cloud backup.") from None
    obj = _json(data)
    activities = obj.get("activities") if isinstance(obj, dict) else obj
    if not isinstance(activities, list) or len(activities) > 1:
        raise BackupFormatError("Unexpected activity feed response.")
    if not activities:
        raise BackupNotFoundError("The recovery account has no Authenticator backup.")
    activity = activities[0]
    if not isinstance(activity, dict):
        raise BackupFormatError("Malformed activity feed entry.")
    if type(activity.get("status")) is not int or activity["status"] not in (0, 1):
        raise BackupNotFoundError("The Authenticator backup is not active.")
    payload = activity.get("payload")
    if not isinstance(payload, str) or not payload:
        raise BackupNotFoundError("The Authenticator backup has no payload.")
    backup = _json(_b64url(payload))
    if not isinstance(backup, dict):
        raise BackupFormatError("Malformed Authenticator backup envelope.")
    # Gson's default constructor uses MSA if the legacy field is absent.
    if backup.get("backupType", "MSA") != "MSA":
        raise UnsupportedBackupError("Only Authenticator Android MSA cloud backups are supported.")
    for key in ("msaKeyId", "encryptedBackup"):
        if not isinstance(backup.get(key), str) or not backup[key]:
            raise BackupFormatError("The backup is missing required encryption metadata.")
    return backup


def decrypt_backup(jwe: str, key_base64: str) -> dict:
    """A128KW + A128CBC-HS256 with authenticated decryption before JSON parsing."""
    if not isinstance(jwe, str) or len(jwe) > _MAX_BYTES:
        raise BackupFormatError("Invalid encrypted backup.")
    parts = jwe.split(".")
    if len(parts) != 5 or not all(parts):
        raise BackupFormatError("Invalid JWE serialization.")
    header, wrapped, iv, ciphertext, tag = map(_b64url, parts)
    if header != _HEADER:
        raise UnsupportedBackupError("Unsupported Authenticator backup encryption header.")
    if len(iv) != 16 or len(tag) != 16 or not ciphertext or len(ciphertext) % 16:
        raise IntegrityError("Invalid encrypted backup lengths.")
    try:
        kek = base64.b64decode(key_base64, validate=True)
        # Android AESWrap uses the supplied AES key length independently of
        # the fixed A128 header (the content-encryption key is still 32 bytes).
        if len(kek) not in (16, 24, 32):
            raise ValueError()
        cek = aes_key_unwrap(kek, wrapped)
        if len(cek) != 32:
            raise ValueError()
        # Android re-encodes the canonical header without '=' for its AAD.
        aad = base64.urlsafe_b64encode(_HEADER).rstrip(b"=")
        material = aad + iv + ciphertext + struct.pack(">Q", len(aad) * 8)
        expected = hmac.new(cek[:16], material, hashlib.sha256).digest()[:16]
        if not hmac.compare_digest(expected, tag):
            raise ValueError()
        decryptor = Cipher(algorithms.AES(cek[16:]), modes.CBC(iv)).decryptor()
        padded = decryptor.update(ciphertext) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        plaintext = unpadder.update(padded) + unpadder.finalize()
    except (ValueError, TypeError, binascii.Error, InvalidUnwrap):
        raise IntegrityError("Authenticator backup integrity verification failed.") from None
    backup = _json(plaintext)
    if not isinstance(backup, dict) or not isinstance(backup.get("BackupAccounts"), list):
        raise BackupFormatError("Decrypted backup has no account list.")
    return backup


def extract_totp_keys(backup: dict) -> tuple[TotpKey, ...]:
    records = []
    for account in backup["BackupAccounts"]:
        if not isinstance(account, dict):
            raise BackupFormatError("Malformed account entry.")
        key = account.get("AccountOathSecretKey")
        if key is None:
            continue
        if not isinstance(key, dict):
            raise BackupFormatError("Malformed account secret entry.")
        secret = key.get("OathSecretKeyValue")
        if not secret:
            # Work/school accounts intentionally back up an empty secret.
            continue
        if not isinstance(secret, str):
            raise BackupFormatError("Malformed account secret value.")
        kind = account.get("AccountType", 0)
        if type(kind) is not int:
            raise BackupFormatError("Invalid account type.")
        kind_name = "work_school" if kind & 1 else "microsoft" if kind & 8 else "third_party" if kind & 2 else "unknown"
        name = account.get("AccountName") or account.get("AccountDisplayName") or ""
        username = account.get("AccountUsername") or ""
        if not isinstance(name, str) or not isinstance(username, str):
            raise BackupFormatError("Invalid account identity fields.")
        records.append(TotpKey(name, username, secret, kind_name,
                               bool(key.get("OathSecretKeyIsEnabled", False)),
                               bool(key.get("OathSecretKeyIsHidden", True))))
    return tuple(records)
