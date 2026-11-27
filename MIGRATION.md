# Migration · 2026-11-26

## Preserved Git history

| Tool | Original main HEAD | Reachable original commits | Namespaced original tags |
| --- | --- | --- | --- |
| codex-companion | `4b301c1ed22d946467a5b3c6dc7bd1fde37543a7` | 6 | `codex-companion/v1.0.0`, `codex-companion/v1.0.1`, `codex-companion/v2.0.1` |
| raynote | `52257eecc0c67222998a85e07723914228c68a40` | 11 | `raynote/v0.1.0`, `raynote/v0.2.0`, `raynote/v0.3.0`, `raynote/v0.3.1` |
| pagepilot | `7c6dab6738fc627a0f697be38640dcea5091db58` | 18 | `pagepilot/v1.0.0` |

The original Git objects are imported unchanged. New packaging, documentation, and branding changes are committed on top. The original repositories are deleted only after remote history and release attachments have been verified and local Git bundles have been retained.

PagePilot additionally includes the three uncommitted local source changes found during migration, in a separate commit after its original history.

## GitHub records

`history/<tool>/` contains repository metadata, branches, tags, release records and asset checksums, issue/PR metadata, comments, reviews, changed-file metadata, PR patches, and original Git refs. Empty lists indicate no records. None of the three repositories had a wiki repository at migration time. A PR head is also retained through an `archive/<tool>/pull/<number>/head` tag.

Original release asset names and bytes are preserved. Original publication dates are recorded in the JSON archives; GitHub assigns a new publication timestamp to migrated releases. Old release descriptions may contain historical URLs.

The history backup distributed with this migration contains Git bundles for full restoration plus GitHub metadata and checksums. The linked release attachments remain independently downloadable from Toolbox.

## Rename compatibility

InboxCode retains the internal `mailcode` extension ID, `local.mailcode.app` app ID, keychain service, and configuration location. AuthCode retains the `local-2fa` extension ID and original import location. Display-name changes do not reset existing accounts.

## Repository status

All three original GitHub repositories (`codex-companion`, `RayNote`, and `PagePilot`) were deleted on 2026-11-26 after Git history, release attachments, and local restoration bundles were verified. Authenticated GitHub API checks confirmed that the old repositories no longer exist. Detailed results are recorded in `migration-status.json`.

Use the corresponding tool branches in `Raysance/toolbox` for future work. Original local checkouts and the migration backup remain available; old GitHub clone URLs and links are no longer valid.

## Additional tools · 2026-11-27

| Tool | Original main HEAD | Original commits | Namespaced original tags |
| --- | --- | --- | --- |
| microsoft-authenticator-totp-export | `2aeddf659b4c89c8101738066e9e1d241f946b84` | 2 | None |
| EdgeSwipe | `031a8d72a44c029605b439cc9cdb6847e9a40bbd` | 9 | `edgeswipe/v0.1.0`, `edgeswipe/v0.2.0`, `edgeswipe/v0.3.0`, `edgeswipe/v0.4.0`, `edgeswipe/v0.5.0` |

Both tools retain their original commit objects; only migration documentation and the SDK repository/install URLs are changed in new commits. Each has a single original main branch and neither has issues, PRs, or a wiki. EdgeSwipe has five releases with five ZIP attachments; the Microsoft exporter has no releases or tags. GitHub records and SHA-256 manifests are archived under their respective `history/<tool>/` directories.

A separate restoration archive, `toolbox-history-backup-2026-11-27.zip`, preserves both original Git bundles, GitHub metadata, and all five original release attachments. The 2026-11-26 backup is unchanged. Both original repositories were deleted on 2026-11-27 after a fresh remote fetch verified every original Git object and all five downloaded attachments matched their original SHA-256 checksums. Authenticated GitHub API checks returned 404 for both old repositories. See `history/migration-2026-11-27-verification.json` and `migration-status.json`.
