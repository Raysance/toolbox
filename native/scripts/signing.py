#!/usr/bin/env python3
"""Keep one local signing identity in Keychain; never silently use ad-hoc signing."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

NAME = "InboxCode Local Signing"
DIRECTORY = Path.home() / "Library/Application Support/InboxCode/Signing"
CONFIG = DIRECTORY / "identity.json"


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{args[0]} failed")
    return result.stdout


def identities(keychain=None):
    output = run("/usr/bin/security", "find-identity", "-p", "codesigning", *([keychain] if keychain else []))
    return dict(re.findall(r'\b([0-9A-Fa-f]{40})\s+"([^"\n]+)"', output))


def write_config(fingerprint, keychain):
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(DIRECTORY, 0o700)
    with tempfile.NamedTemporaryFile(mode="w", dir=DIRECTORY, delete=False) as target:
        json.dump({"fingerprint": fingerprint, "keychain": keychain}, target, indent=2)
        target.write("\n")
        target.flush()
        os.fsync(target.fileno())
    os.replace(target.name, CONFIG)


def resolve():
    fingerprint = os.environ.get("INBOXCODE_SIGNING_IDENTITY")
    keychain = None
    if fingerprint is None:
        if not CONFIG.exists():
            raise RuntimeError("Run python3 native/scripts/signing.py setup once before building.")
        config = json.loads(CONFIG.read_text())
        fingerprint, keychain = config["fingerprint"], config["keychain"]
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint):
        raise RuntimeError("Signing identity must be the certificate's full SHA-1 fingerprint, not '-' or a name.")
    fingerprint = fingerprint.upper()
    if fingerprint not in identities(keychain):
        raise RuntimeError("Saved signing identity is unavailable. Unlock or restore its Keychain; do not generate a replacement.")
    return fingerprint, keychain


def setup():
    if CONFIG.exists():
        # Existing configuration is authoritative, even when the caller has an override.
        override = os.environ.pop("INBOXCODE_SIGNING_IDENTITY", None)
        try:
            fingerprint, _ = resolve()
        finally:
            if override is not None:
                os.environ["INBOXCODE_SIGNING_IDENTITY"] = override
        print(f"Reusing saved signing identity {fingerprint}")
        return
    keychain = run("/usr/bin/security", "default-keychain", "-d", "user").strip().strip('"')
    existing = [fingerprint for fingerprint, name in identities(keychain).items() if name == NAME]
    if len(existing) > 1:
        raise RuntimeError("Multiple InboxCode signing identities exist. Restore identity.json instead of choosing a new identity.")
    if existing:
        write_config(existing[0], keychain)
        print(f"Restored configuration for existing identity {existing[0]}")
        return
    # A certificate without its private key must not cause accidental identity rotation.
    found = subprocess.run(["/usr/bin/security", "find-certificate", "-c", NAME, keychain], capture_output=True)
    if found.returncode == 0:
        raise RuntimeError("InboxCode certificate exists but its private key is unavailable. Restore the original private key.")
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(DIRECTORY, 0o700)
    with tempfile.TemporaryDirectory(prefix="setup-", dir=DIRECTORY) as temporary:
        folder = Path(temporary)
        key, certificate, combined = folder / "private.pem", folder / "certificate.pem", folder / "identity.pem"
        run("/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
            "-days", "3650", "-subj", f"/CN={NAME}/", "-keyout", str(key), "-out", str(certificate),
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
            "-addext", "extendedKeyUsage=critical,codeSigning")
        fingerprint = run("/usr/bin/openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1").split("=", 1)[1].strip().replace(":", "")
        combined.write_bytes(certificate.read_bytes() + key.read_bytes())
        os.chmod(combined, 0o600)
        # Only Apple's codesign is preauthorized for this new private key. No broad ACL/trust changes.
        run("/usr/bin/security", "import", str(combined), "-k", keychain, "-f", "pemseq", "-T", "/usr/bin/codesign")
        if fingerprint not in identities(keychain):
            raise RuntimeError("Imported identity was not found in Keychain; refusing to continue.")
        write_config(fingerprint, keychain)
    print(f"Saved signing identity {fingerprint}. Private key remains in Keychain; temporary PEM files removed.")


def sign(app):
    fingerprint, keychain = resolve()
    run("/usr/bin/codesign", "--force", "--sign", fingerprint,
        *(["--keychain", keychain] if keychain else []), "--identifier", "local.mailcode.app", "--timestamp=none", app)
    run("/usr/bin/codesign", "--verify", "--strict", app)
    print(f"Signed with persistent identity {fingerprint}")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        if sys.argv[1:] == ["setup"]:
            setup()
        elif sys.argv[1:] == ["check"]:
            print(resolve()[0])
        elif len(sys.argv) == 3 and sys.argv[1] == "sign":
            sign(sys.argv[2])
        else:
            raise RuntimeError("Usage: signing.py setup | check | sign /path/to/InboxCode.app")
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
