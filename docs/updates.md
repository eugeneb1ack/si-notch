[English](updates.md) · [Русский](ru/updates.md) · [简体中文](zh-CN/updates.md)

# Updates

The app reads GitHub Releases at launch and every six hours. Users can disable background checks, select stable or beta, or check manually in **Settings → About**. A new release appears in About and the menu bar menu. Installation requires **Install and Restart**; preferences and agent configurations are preserved.

DMG is the installer. The updater uses a ZIP plus `update.json`. It checks an Ed25519 signature, ZIP size and SHA-256, bundle ID, version, build and code signature. A failed replacement or launch restores the previous bundle. No privileged helper is installed.

Updates use this repository’s public Releases and do not require a GitHub account. Builds use ad hoc signing; Developer ID signing and notarization remain pending.

## Publish a release

1. Update `version` and `build` in `release.json`; use `-beta.1` for a beta.
2. Add release notes in English to `docs/release-VERSION.md`, describing user-visible fixes. Use the same file for GitHub Releases and the update feed. Commit and push the source.
3. Build and prepare assets with the signing key kept outside the repository:

```sh
scripts/test.sh
scripts/build-app.sh release
scripts/verify-release.sh
scripts/build-dmg.sh
python3 scripts/package-release.py \
  --dmg build/si-notch-macos-arm64-VERSION.dmg \
  --notes docs/release-VERSION.md \
  --private-key /secure/path/update-ed25519.pem \
  --output /tmp/si-notch-release-VERSION
scripts/publish-release.sh /tmp/si-notch-release-VERSION docs/release-VERSION.md
```

Replace `VERSION` with the version in `release.json`. Keep the Ed25519 private key backed up securely; the public key is pinned in installed apps. Never commit or upload the private key as a release asset. Beta releases are marked prerelease and do not replace the latest stable release.

[GitHub Actions](../.github/workflows/ci.yml) tests the source, verifies the ZIP and builds the DMG on each push and pull request. Release signing and publication run locally with the maintainer’s key. No GitHub token is shipped in the app.

## Release retention

The [Release retention workflow](../.github/workflows/release-retention.yml) runs after each stable or beta release is published, including manual publication on GitHub. It keeps three published releases ordered by publication time, reserving one of those slots for the current **Latest** stable release. Older release records and their assets are deleted. Drafts, Git tags and source history are preserved.

Cleanup runs sequentially, uses the script from the default branch and rechecks Latest before each deletion. API errors or inconsistent metadata stop the cleanup. A failed cleanup does not roll back the new release; rerun **Actions → Release retention → Run workflow** after resolving the error. The cleanup job uses GitHub’s temporary token with `contents: write`; it needs no additional secret. If publication moves into another workflow using `GITHUB_TOKEN`, explicitly dispatch this workflow afterward because those release events do not trigger another workflow.

To preview the current plan locally with an authenticated GitHub CLI:

```sh
python3 scripts/prune-releases.py --repo eugeneb1ack/si-notch
```

Deletion requires `--apply`. The normal publication command needs no additional step.

## Plugin announcements

`release.json` may include `pluginUpdates`, an array of up to 20 entries with unique `id`, `name`, `version`, `change` (`added` or `updated`) and `installURL`. Installation links must be HTTPS GitHub repository pages. The release packager includes this metadata in the signed feed and the app bundle. Keep the list scoped to plugins introduced or changed in that release; use a versioned GitHub installation page.

Settings → About and the menu bar display these announcements with installation links. They describe the release, not the installed state of a remote profile. Plugins are installed separately. Links remain available after updating the app; changing update channels cannot reuse announcements from another channel. Older feeds without plugin metadata continue to work.
