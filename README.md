# Microsoft Authenticator TOTP SDK for macOS

A Python SDK with two operations:

- Sign in to a Microsoft personal account and obtain reusable login state.
- Retrieve TOTP secret keys stored in that account's Microsoft Authenticator Android cloud backup.

This is an unofficial SDK. Sign-in and TOTP secret retrieval have been verified end to end with a live account.

## Requirements

- macOS and Python 3.10 or later.
- A Microsoft personal recovery account with an existing Microsoft Authenticator **Android backup stored in that Microsoft account**.

The SDK retrieves **secret keys**, not the current six-digit verification codes. Keys that were never backed up cannot be retrieved. Work or school account entries generally do not contain recoverable keys. iCloud and Google Block Store backups are not supported.

## Installation

Install from GitHub:

```bash
python3 -m pip install "git+https://github.com/Raysance/msauth-totp-macos-sdk.git"
```

Or install from a downloaded source directory:

```bash
python3 -m pip install .
```

## Quick start

```python
from msauth_totp import login, get_totp_keys

state = login()
keys = get_totp_keys(state)

for entry in keys:
    print(entry.account_name, entry.username)
    secret = entry.secret  # The original TOTP secret key.
```

`login()` opens a native macOS window containing Microsoft's sign-in page. Enter the recovery account's credentials and complete any verification Microsoft requests. The SDK captures the resulting login state automatically. No manual copying of cookies, tokens, or encryption keys is required.

Microsoft may request another verification step when retrieving keys. The SDK displays that step in the same type of sign-in window.

## API

### `login(username=None, *, state=None, timeout=30, interactive_timeout=900)`

Returns a `LoginState` after successful authentication.

| Parameter | Description |
| --- | --- |
| `username` | Optional account hint, such as `"name@example.com"`. |
| `state` | A previous `LoginState` or its JSON representation to validate and renew. Omit to start a new sign-in. |
| `timeout` | Timeout in seconds for each network request. |
| `interactive_timeout` | Timeout in seconds for each sign-in window. |

```python
state = login("name@example.com")
print(state.username, state.cid)
```

### `get_totp_keys(state, *, timeout=30, interactive_timeout=900)`

Returns a tuple of `TotpKey` entries. `state` must be a `LoginState` returned by `login()` or restored using `LoginState.from_json()`.

| Field | Description |
| --- | --- |
| `account_name` | Account display name. |
| `username` | Username associated with the entry. |
| `secret` | Original TOTP secret string. |
| `account_type` | `microsoft`, `third_party`, `work_school`, or `unknown`. |
| `enabled` | Whether the backup marks the secret as enabled. |
| `hidden` | Whether the backup marks the code as hidden in Authenticator. |

All entries containing a nonempty secret are returned, including hidden entries. Entries without a stored secret are omitted. A missing backup raises an error; an empty tuple means a backup exists but contains no nonempty secrets.

Reading keys does not modify the cloud backup.

## Reusing login state

```python
from msauth_totp import LoginState, login, get_totp_keys

saved = state.to_json()
# Store `saved` in your application's secure storage.

restored = LoginState.from_json(saved)
state = login(state=restored)
keys = get_totp_keys(state)
```

The serialized state contains authentication credentials. The SDK does not automatically save it to disk. Secret values are excluded from the default string representations of login state and TOTP entries.

If a saved login has expired or been revoked and cannot be renewed, call `login()` without `state` to sign in again.

## Error handling

```python
from msauth_totp import (
    login, get_totp_keys,
    LoginCancelledError, AuthenticationError, BackupNotFoundError, SDKError,
)

try:
    keys = get_totp_keys(login())
except LoginCancelledError:
    print("Sign-in was cancelled.")
except AuthenticationError:
    print("Authentication could not be completed. Try signing in again.")
except BackupNotFoundError:
    print("No supported Authenticator backup was found for this recovery account.")
except SDKError as error:
    print(error)
```

Other exceptions include `NetworkError`, `UnsupportedBackupError`, `BackupFormatError`, `IntegrityError`, and `ProtocolError`. All SDK exceptions inherit from `SDKError`.
