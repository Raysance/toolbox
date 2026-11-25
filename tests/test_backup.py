import base64
import json
from unittest.mock import Mock

import pytest
from jwcrypto import jwk, jwe

from msauth_totp._backup import backup_id, decrypt_backup, extract_totp_keys, read_cloud_backup
from msauth_totp._errors import (IntegrityError, BackupFormatError, BackupNotFoundError,
                                AuthenticationError, UnsupportedBackupError)


def sample_backup():
    return {"BackupAccounts": [
        {"AccountName": "Example", "AccountUsername": "user@example.test", "AccountType": 2,
         "AccountOathSecretKey": {"OathSecretKeyValue": "JBSWY3DPEHPK3PXP",
                                  "OathSecretKeyIsEnabled": True, "OathSecretKeyIsHidden": False}},
        {"AccountName": "Work", "AccountType": 1,
         "AccountOathSecretKey": {"OathSecretKeyValue": ""}},
        {"AccountName": "Microsoft", "AccountType": 8,
         "AccountOathSecretKey": {"OathSecretKeyValue": "MZXW6YTBOI======",
                                  "OathSecretKeyIsEnabled": True, "OathSecretKeyIsHidden": True}},
    ]}


@pytest.fixture
def encrypted():
    # Independent JWE implementation, including AES key wrapping and CBC-HMAC.
    key = bytes(range(16))
    obj = jwe.JWE(json.dumps(sample_backup()).encode(),
                  protected='{"alg":"A128KW","enc":"A128CBC-HS256"}')
    obj.add_recipient(jwk.JWK(kty="oct", k=base64.urlsafe_b64encode(key).decode().rstrip("=")))
    return obj.serialize(compact=True), base64.b64encode(key).decode()


def test_external_jwe_roundtrip_and_only_existing_secrets(encrypted):
    plain = decrypt_backup(*encrypted)
    assert plain == sample_backup()
    keys = extract_totp_keys(plain)
    assert len(keys) == 2
    assert keys[0].secret == "JBSWY3DPEHPK3PXP"
    assert keys[0].username == "user@example.test"
    assert keys[1].hidden and keys[1].account_type == "microsoft"
    assert "JBSWY3DPEHPK3PXP" not in repr(keys)


@pytest.mark.parametrize("index", range(1, 5))
def test_modified_jwe_rejected(encrypted, index):
    token, key = encrypted
    parts = token.split(".")
    raw = bytearray(base64.urlsafe_b64decode(parts[index] + "=" * (-len(parts[index]) % 4)))
    raw[0] ^= 1
    parts[index] = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    with pytest.raises(IntegrityError):
        decrypt_backup(".".join(parts), key)


def test_wrong_key_rejected(encrypted):
    with pytest.raises(IntegrityError):
        decrypt_backup(encrypted[0], base64.b64encode(b"a" * 16).decode())


def test_other_algorithm_rejected(encrypted):
    parts = encrypted[0].split(".")
    parts[0] = base64.urlsafe_b64encode(b'{"alg":"none"}').decode().rstrip("=")
    with pytest.raises(UnsupportedBackupError):
        decrypt_backup(".".join(parts), encrypted[1])


def test_java_uuid_equivalence():
    assert backup_id("0123456789abcdef") == "01234567-89ab-cdef-0123-456789abcdef"
    assert backup_id("Ab") == "abababab-abab-abab-abab-abababababab"
    for invalid in ("", "https://example.test", "xyz", "a" * 17, None):
        with pytest.raises(BackupFormatError):
            backup_id(invalid)


def fake_http(body=None, code=200):
    response = Mock(status_code=code)
    response.__enter__ = Mock(return_value=response)
    response.__exit__ = Mock(return_value=False)
    response.iter_content.return_value = [json.dumps(body).encode()]
    http = Mock()
    http.get.return_value = response
    return http


def test_activity_feed_envelope(encrypted):
    envelope = {"msaKeyId": "1234", "encryptedBackup": encrypted[0], "backupType": "MSA"}
    payload = base64.urlsafe_b64encode(json.dumps(envelope).encode()).decode()
    for body in ([{"status": 1, "payload": payload}], {"activities": [{"status": 0, "payload": payload}]}):
        http = fake_http(body)
        assert read_cloud_backup(http, "0123456789abcdef", "synthetic-token", 5) == envelope
        kwargs = http.get.call_args.kwargs
        assert kwargs["allow_redirects"] is False
        assert kwargs["headers"]["Authorization"] == "Bearer synthetic-token"


@pytest.mark.parametrize("code,exc", [(404, BackupNotFoundError), (401, AuthenticationError), (403, AuthenticationError)])
def test_distinct_backup_failures(code, exc):
    with pytest.raises(exc):
        read_cloud_backup(fake_http(code=code), "abcd", "synthetic-token", 5)


def test_absent_backup_is_not_empty_success():
    with pytest.raises(BackupNotFoundError):
        read_cloud_backup(fake_http({"activities": []}), "abcd", "synthetic-token", 5)


# Independent Java AESWrap/CBC/HMAC fixtures with the fixed A128 header.
@pytest.mark.parametrize("key_size,token", [(24, 'eyJhbGciOiJBMTI4S1ciLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0.XlAJjVDrLvRvHsldOYe1anPmpV4-pK-s4QeMRyn3JrTcQOLg_B8-7Q.EBESExQVFhcYGRobHB0eHw.aixBbFla8pt6Jh4Zl2AyyEeIfB8dEvogYPawI2-rQ90.YuI0ksGOlbzlDcgQF6LL1w'), (32, 'eyJhbGciOiJBMTI4S1ciLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0.vSonaujHRkx-izlmdKxuDpVYyExgCbP6QTzwameiAII-TXIN8kGfqQ.EBESExQVFhcYGRobHB0eHw.aixBbFla8pt6Jh4Zl2AyyEeIfB8dEvogYPawI2-rQ90.YuI0ksGOlbzlDcgQF6LL1w')])
def test_android_wrap_key_lengths(key_size, token):
    key = base64.b64encode(bytes(range(key_size))).decode()
    assert decrypt_backup(token, key) == {"BackupAccounts": []}
    wrong_key = base64.b64encode(bytes([255]) * key_size).decode()
    with pytest.raises(IntegrityError):
        decrypt_backup(token, wrong_key)
    parts = token.split(".")
    raw = bytearray(base64.urlsafe_b64decode(parts[4] + "=" * (-len(parts[4]) % 4)))
    raw[0] ^= 1
    parts[4] = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    with pytest.raises(IntegrityError):
        decrypt_backup(".".join(parts), key)
