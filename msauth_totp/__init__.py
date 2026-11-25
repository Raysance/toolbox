"""macOS Python SDK for Microsoft Authenticator login and backed-up TOTP keys."""
from ._client import LoginState, login, get_totp_keys
from ._backup import TotpKey
from ._errors import (
    SDKError, AuthenticationError, LoginCancelledError, NetworkError, ProtocolError,
    BackupNotFoundError, BackupFormatError, UnsupportedBackupError, IntegrityError,
)

__version__ = "0.1.4"
__all__ = ["login", "get_totp_keys", "LoginState", "TotpKey", "SDKError",
           "AuthenticationError", "LoginCancelledError", "NetworkError", "ProtocolError",
           "BackupNotFoundError", "BackupFormatError", "UnsupportedBackupError", "IntegrityError"]
