"""Errors do not include credentials, response bodies, or secret key values."""


class SDKError(Exception):
    """Base SDK exception."""


class AuthenticationError(SDKError):
    """Microsoft rejected or requires renewal of the login."""


class LoginCancelledError(AuthenticationError):
    """The interactive login was cancelled."""


class ProtocolError(SDKError):
    """The server response does not match the supported protocol."""


class NetworkError(SDKError):
    """A network operation failed."""


class BackupNotFoundError(SDKError):
    """The Microsoft recovery account has no readable Authenticator cloud backup."""


class BackupFormatError(ProtocolError):
    """A backup contains malformed data."""


class IntegrityError(BackupFormatError):
    """Backup decryption or integrity verification failed."""


class UnsupportedBackupError(SDKError):
    """The backup is not an Authenticator MSA cloud backup."""
