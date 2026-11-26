# AuthCode

A small, offline Raycast extension for viewing and copying TOTP verification codes. No account, subscription, or sync is required.

## Use

1. Open Raycast, type `AuthCode`, and press Return.
2. Search by service or account name.
3. Press Return to copy the selected account's current code.

Codes refresh automatically. Copying always uses the current code, even at a refresh boundary.

Press **⌘ Return** to open the selected account's options:

- **View Setup Key**: view or copy the TOTP key, or copy its `otpauth://` URI.
- **Edit Account**: change the service, account name, setup key, algorithm, digits, or period. **⌘ Return** saves the form.
- **Export This Account** / **Export All Accounts**: save standard `otpauth://` entries to a folder you choose. Existing files are never overwritten.

Supported settings: SHA1, SHA256, SHA512; 6, 7, or 8 digits; configurable periods. Exported files contain unencrypted setup keys and should be kept private.

## Install on another Mac

Requires Raycast. Download the AuthCode package from [Toolbox Releases](https://github.com/Raysance/toolbox/releases), then open the `AuthCode.rayext` file to install. Account data is not included in the extension package.

For an initial import, save newline-separated `otpauth://totp/` entries as:

```text
~/Library/Application Support/Local 2FA/import.txt
```

The first run imports the file into Raycast's encrypted local storage and deletes the import file after verifying the save. Once accounts exist, the extension uses the saved accounts. There is no cloud sync.

## Build from source

```sh
git clone --branch authcode --single-branch https://github.com/Raysance/toolbox.git AuthCode
cd AuthCode
npm ci
npm test
npm run build
npm run dev
```

`npm run dev` installs the local extension for development. Closing the watcher does not remove the installed command.

The internal extension ID remains `local-2fa` so existing account storage is retained when upgrading. No TOTP account data is included in this repository.
