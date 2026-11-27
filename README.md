# Microsoft Authenticator TOTP Export

> This project now lives in the **`microsoft-authenticator-totp-export`** branch of [Raysance/toolbox](https://github.com/Raysance/toolbox/tree/microsoft-authenticator-totp-export). Original commits and version tags are preserved. [Toolbox catalog](https://github.com/Raysance/toolbox) · [Migration history](https://github.com/Raysance/toolbox/blob/main/MIGRATION.md)


A Python SDK for macOS with two operations:

- Sign in to Microsoft and obtain reusable login state.
- Export TOTP secret keys from your Microsoft Authenticator cloud backup.

Requires macOS, Python 3.10 or later, and the Microsoft personal account used for the cloud backup. This is an unofficial SDK.

## Install

```bash
python3 -m pip install "git+https://github.com/Raysance/toolbox.git@microsoft-authenticator-totp-export"
```

From a downloaded source directory, use `python3 -m pip install .`.

## Usage

```python
from msauth_totp import login, get_totp_keys

state = login()
entries = get_totp_keys(state)

for entry in entries:
    print(entry.account_name, entry.username)
    secret = entry.secret
```

`login()` opens Microsoft's sign-in window. Complete sign-in and any requested verification; the SDK returns the login state automatically.

`get_totp_keys()` returns stored secret keys, not current verification codes. It does not modify your backup. Only entries with a stored, nonempty secret are returned.

## API

### `login(username=None, *, state=None, timeout=30, interactive_timeout=900)`

Returns a `LoginState`.

| Parameter | Description |
| --- | --- |
| `username` | Optional account hint. |
| `state` | Previous `LoginState` or its JSON representation to validate and renew. |
| `timeout` | Network timeout in seconds. |
| `interactive_timeout` | Sign-in window timeout in seconds. |

### `get_totp_keys(state, *, timeout=30, interactive_timeout=900)`

Returns a tuple of `TotpKey` entries.

| Field | Description |
| --- | --- |
| `account_name` | Account display name. |
| `username` | Account username. |
| `secret` | Original stored TOTP secret. |
| `account_type` | `microsoft`, `third_party`, `work_school`, or `unknown`. |
| `enabled` | Whether the backup marks the secret as enabled. |
| `hidden` | Whether the backup marks the entry as hidden. |

Microsoft account secrets are stored in Base64; third-party account secrets are stored in Base32. Convert Microsoft secrets to Base32 when importing into an authenticator that requires Base32 setup keys. Hidden entries are included when they contain a secret.

## Reuse login state

```python
from msauth_totp import LoginState, login, get_totp_keys

saved = state.to_json()
# Store saved in your application's secure storage.

restored = LoginState.from_json(saved)
state = login(state=restored)
entries = get_totp_keys(state)
```

Serialized login state contains credentials. The SDK does not save it automatically. If a session cannot be renewed, call `login()` without `state` to sign in again.

## Errors

All SDK errors inherit from `SDKError`. Common errors include `LoginCancelledError`, `AuthenticationError`, `BackupNotFoundError`, `NetworkError`, and `IntegrityError`.

A missing backup raises `BackupNotFoundError`. An empty tuple means the backup exists but contains no stored secrets.
