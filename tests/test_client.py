"""Integration coverage for the two SDK operations, with no live account calls."""
import base64
from collections import deque
from dataclasses import replace
import json
from urllib.parse import parse_qs, urlsplit

from jwcrypto import jwk, jwe
import pytest

from msauth_totp import _client as sdk
from msauth_totp._backup import AFS_POLICY, AFS_SCOPE
from msauth_totp._errors import AuthenticationError, BackupNotFoundError, IntegrityError, ProtocolError
from msauth_totp._soap import DAToken, DeviceIdentity, StsAuthenticationError, TicketResult

NOW = 1_900_000_000.0
CID = '0123456789abcdef'
PUID = 'test-puid'
KEK = bytes(range(16))
SECRET = 'JBSWY3DPEHPK3PXP'


def wrapped_backup():
    value = {'BackupAccounts': [
        {'AccountName': 'Example', 'AccountUsername': 'person@example.test', 'AccountType': 2,
         'AccountOathSecretKey': {'OathSecretKeyValue': SECRET,
                                  'OathSecretKeyIsEnabled': True,
                                  'OathSecretKeyIsHidden': False}},
        {'AccountName': 'Work account', 'AccountType': 1,
         'AccountOathSecretKey': {'OathSecretKeyValue': ''}},
    ]}
    token = jwe.JWE(json.dumps(value).encode(), protected='{"alg":"A128KW","enc":"A128CBC-HS256"}')
    token.add_recipient(jwk.JWK(kty='oct', k=base64.urlsafe_b64encode(KEK).decode().rstrip('=')))
    envelope = {'encryptedBackup': token.serialize(compact=True), 'msaKeyId': 'required-key-id', 'backupType': 'MSA'}
    return {'activities': [{'status': 1, 'payload': base64.urlsafe_b64encode(json.dumps(envelope).encode()).decode()}]}


class Response:
    def __init__(self, body, code=200):
        self.body, self.status_code = body, code
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return False
    def iter_content(self, *args, **kwargs):
        data = json.dumps(self.body).encode()
        # Split across arbitrary chunk boundaries to exercise the actual HTTP reader.
        yield data[:17]
        yield data[17:]


class Harness:
    def __init__(self):
        self.calls = []
        self.body = wrapped_backup()
        self.http_codes = deque()
        self.ticket_handler = None
        self.key_handler = None
        self.mfa_properties = {'STSInlineFlowToken': 'flow-after-verification'}
        self.user_da = DAToken('<EncryptedData/>', b'u' * 32, NOW + 3600)
        self.device = DeviceIdentity('registered-device', 'device-password', 'device-puid',
                                     DAToken('<DeviceData/>', b'd' * 32, NOW + 3600))
        self.keys = {'unrelated-key-id': base64.b64encode(b'x' * 16).decode(),
                     'required-key-id': base64.b64encode(KEK).decode()}
        harness = self

        class Http:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def get(self, url, **kwargs):
                harness.calls.append(('get', url, kwargs))
                status = harness.http_codes.popleft() if harness.http_codes else 200
                return Response(harness.body, status)

        class Soap:
            def __init__(self, http, **kwargs):
                self.http = http
            def server_time(self):
                return NOW
            def provision_device(self):
                harness.calls.append(('provision',))
                return harness.device
            def refresh_device(self, device):
                harness.calls.append(('refresh', device))
                return replace(device, da=replace(device.da, expires_at=NOW + 7200))
            def request_ticket(self, user_da, device, scope, policy, client_app_uri, *, flow_token=None):
                harness.calls.append(('ticket', scope, policy, flow_token, user_da, device))
                if harness.ticket_handler:
                    response = harness.ticket_handler(scope, policy, flow_token)
                    if response is not None:
                        return response
                value = 'afs-access-ticket' if scope == AFS_SCOPE else 'login-proof-ticket'
                return TicketResult(value, harness.user_da, NOW + 3600, CID, PUID)
            def get_user_keys(self, device, proof):
                harness.calls.append(('keys', proof, device))
                if harness.key_handler:
                    result = harness.key_handler()
                    if result is not None:
                        return result
                return harness.keys

        self.Http, self.Soap = Http, Soap

    def native_login(self, url, timeout, *, interrupt=False, initial_properties=None):
        self.calls.append(('ui', url, interrupt))
        if interrupt:
            return self.mfa_properties.copy()
        return {'DAToken': self.user_da.token_xml,
                'DASessionKey': base64.b64encode(self.user_da.session_key).decode(),
                'DAExpires': '2099-01-01T00:00:00Z',
                'SigninName': 'person@example.test', 'CID': CID, 'PUID': PUID}

    def install(self, monkeypatch):
        monkeypatch.setattr(sdk.requests, 'Session', self.Http)
        monkeypatch.setattr(sdk, 'SoapClient', self.Soap)
        monkeypatch.setattr(sdk, '_native_login', self.native_login)
        return self


@pytest.fixture
def harness(monkeypatch):
    return Harness().install(monkeypatch)


def test_login_returns_validated_reusable_state(harness):
    state = sdk.login('person@example.test')
    assert state.cid == CID and state.username == 'person@example.test'
    assert state._afs_ticket == 'afs-access-ticket'
    assert [c[0] for c in harness.calls] == ['provision', 'ui', 'ticket']
    query = parse_qs(urlsplit(harness.calls[1][1]).query)
    assert query['id'] == ['80601']
    assert query['platform'] == ['android2.1.0524.0520']
    assert query['client_id'] == ['android-app://com.azure.authenticator.Q2GTRUJN356ZSJWGVNIK2LBJJVJ2P5V5']
    assert harness.calls[-1][1:3] == (AFS_SCOPE, AFS_POLICY)
    assert 'afs-access-ticket' not in repr(state)
    assert 'device-password' not in repr(state)


def test_entire_restore_uses_backup_key_id_and_returns_plain_totp(harness):
    state = sdk.login()
    harness.calls.clear()
    keys = sdk.get_totp_keys(state)
    assert len(keys) == 1
    assert keys[0].secret == SECRET and keys[0].username == 'person@example.test'
    assert [c[0] for c in harness.calls] == ['get', 'ticket', 'keys']
    get = harness.calls[0]
    assert get[1] == 'https://activity.windows.com/v2/feeds/me/activities/01234567-89ab-cdef-0123-456789abcdef'
    assert get[2]['headers']['Authorization'] == 'Bearer afs-access-ticket'
    assert harness.calls[1][1:3] == ('http://Passport.NET/purpose', 'PURPOSE_GETKEYDATA_ROAMING')
    assert harness.calls[2][1] == 'login-proof-ticket'
    assert SECRET not in state.to_json()


def test_serialized_state_can_renew_and_read_without_new_ui_or_registration(harness):
    original = sdk.login()
    serialized = original.to_json()
    restored = sdk.LoginState.from_json(serialized)
    assert restored._user_da.session_key == original._user_da.session_key
    assert restored._device.password == original._device.password
    assert restored.to_json() == serialized
    harness.calls.clear()
    renewed = sdk.login(state=serialized)
    assert sdk.get_totp_keys(renewed)[0].secret == SECRET
    assert all(c[0] not in ('ui', 'provision') for c in harness.calls)


def test_mfa_flow_token_resumes_same_scope_with_refreshed_user_da(harness):
    seen = []
    newer = DAToken('<RefreshedUserDA/>', b'n' * 32, NOW + 3600)
    def handler(scope, policy, flow):
        if scope != AFS_SCOPE:
            return None
        seen.append(flow)
        if flow is None:
            return TicketResult(refreshed_user_da=newer, cid=CID, puid=PUID,
                                interactive_url='https://login.live.com/proof')
        assert flow == 'flow-after-verification'
        return TicketResult('verified-afs', newer, NOW + 3600, CID, PUID)
    harness.ticket_handler = handler
    state = sdk.login()
    assert state._afs_ticket == 'verified-afs' and state._user_da == newer
    assert seen == [None, 'flow-after-verification']
    ui_calls = [c for c in harness.calls if c[0] == 'ui']
    assert len(ui_calls) == 2 and ui_calls[1][2] is True
    second_ticket = [c for c in harness.calls if c[0] == 'ticket'][1]
    assert second_ticket[4] == newer


def test_expired_device_is_refreshed_before_requesting_proof(harness):
    state = sdk.login()
    state._device = replace(state._device, da=replace(state._device.da, expires_at=NOW - 1))
    harness.calls.clear()
    assert sdk.get_totp_keys(state)[0].secret == SECRET
    assert [c[0] for c in harness.calls] == ['get', 'refresh', 'ticket', 'keys']
    assert state._device.da.expires_at == NOW + 7200


def test_device_without_expiration_is_refreshed(harness):
    state = sdk.login()
    state._device = replace(state._device, da=replace(state._device.da, expires_at=None))
    harness.calls.clear()
    sdk.get_totp_keys(state)
    assert any(c[0] == 'refresh' for c in harness.calls)


def test_rejected_cached_afs_ticket_is_renewed_once(harness):
    state = sdk.login()
    harness.http_codes.extend([401, 200])
    harness.calls.clear()
    assert sdk.get_totp_keys(state)[0].secret == SECRET
    assert [c[0] for c in harness.calls] == ['get', 'ticket', 'get', 'ticket', 'keys']
    assert harness.calls[1][1] == AFS_SCOPE


def test_force_signin_getkey_error_requests_fresh_proof_once(harness):
    state = sdk.login()
    attempts = []
    def keys():
        attempts.append(1)
        if len(attempts) == 1:
            raise StsAuthenticationError('New proof required', format(-2147217396 & 0xffffffff, 'x'))
    harness.key_handler = keys
    harness.calls.clear()
    assert sdk.get_totp_keys(state)[0].secret == SECRET
    assert len(attempts) == 2
    assert [c[0] for c in harness.calls] == ['get', 'ticket', 'keys', 'ticket', 'keys']


def test_backup_absent_is_error_without_key_request(harness):
    state = sdk.login()
    harness.http_codes.append(404)
    harness.calls.clear()
    with pytest.raises(BackupNotFoundError):
        sdk.get_totp_keys(state)
    assert [c[0] for c in harness.calls] == ['get']


def test_wrong_or_missing_key_never_produces_empty_success(harness):
    state = sdk.login()
    harness.keys.pop('required-key-id')
    with pytest.raises(AuthenticationError):
        sdk.get_totp_keys(state)
    harness.keys['required-key-id'] = base64.b64encode(b'z' * 16).decode()
    with pytest.raises(IntegrityError):
        sdk.get_totp_keys(state)


def test_other_account_response_and_verification_are_rejected(harness):
    def different_account(*args):
        return TicketResult('ticket-for-other-account', cid='ffffffffffffffff', puid=PUID)
    harness.ticket_handler = different_account
    with pytest.raises(AuthenticationError):
        sdk.login()
    def proof(*args):
        return TicketResult(interactive_url='https://login.live.com/proof')
    harness.ticket_handler = proof
    harness.mfa_properties['CID'] = 'ffffffffffffffff'
    with pytest.raises(AuthenticationError):
        sdk.login()


def test_state_parser_rejects_malformed_credentials_without_exposing_them(harness):
    state = json.loads(sdk.login().to_json())
    state['user_da']['key'] = 'bad-private-value%'
    with pytest.raises(ProtocolError) as exc:
        sdk.LoginState.from_json(json.dumps(state))
    assert 'bad-private-value' not in str(exc.value)
