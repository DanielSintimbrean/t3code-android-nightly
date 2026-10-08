# T3 Code Android Nightly

Unofficial nightly Android builds of [T3 Code](https://github.com/pingdotgg/t3code), published as GitHub Releases so you can install them and keep them updated with [Obtainium](https://github.com/ImranR98/Obtainium).

T3 Code is built by [T3 Tools Inc.](https://github.com/pingdotgg) and the [T3 Code contributors](https://github.com/pingdotgg/t3code/graphs/contributors). All credit for the app goes to them. This is a community build: it is **not affiliated with, endorsed by, or supported by** T3 Tools Inc. Please don't report problems with these builds to the upstream project unless you can reproduce them with an official build.

This repository contains no T3 Code source code, only the scripts that fetch upstream, build the APK and publish it.

## Install

[<img src="https://raw.githubusercontent.com/ImranR98/Obtainium/main/assets/graphics/badge_obtainium.png" alt="Get it on Obtainium" height="80">](https://apps.obtainium.imranr.dev/redirect?r=obtainium://add/https://github.com/DanielSintimbrean/t3code-android-nightly)

Or download the APK manually from the [Releases page](https://github.com/DanielSintimbrean/t3code-android-nightly/releases).

Current build:

<!-- current-build:start -->
**[v0.0.46-nightly.20261008.2801](https://github.com/DanielSintimbrean/t3code-android-nightly/releases/tag/v0.0.46-nightly.20261008.2801)**, built from upstream commit [`d720210`](https://github.com/pingdotgg/t3code/commit/d720210996a514368ba99f4860063110033d93fa) on 2026-10-08.
<!-- current-build:end -->

What you get:

- The **Preview** variant of the mobile app: package `com.t3tools.t3code.preview`, shown as **T3 Code Preview**. It installs alongside the T3 Code app from Google Play and does not replace it.
- A build of each upstream nightly tag, such as `v0.0.46-nightly.20261007.2774`. The release tag and the app's version name are that same tag. Upstream commits without a new nightly tag are not built.
- Native code is built for 64-bit ARM (`arm64-v8a`) only, which covers current Android phones. 32-bit devices and x86 emulators are not supported.
- Over-the-air updates are disabled; new versions arrive only as new releases.
- T3 Connect is enabled and uses the official production service (`relay.t3.codes` and T3's Clerk sign-in), configured with the public identifiers upstream ships in its `.env.example`. You can also connect to a server directly (local network, Tailscale, etc.). This build is signed with a different key than the official app, so sign-in methods tied to the official app's signature, such as passkeys or native Google sign-in, may not work.

**Server compatibility:** the app talks to a T3 Code server, and nightly builds follow upstream's nightly tags, which currently use the orchestrator v2 protocol. Run a server from the same upstream nightly, or a compatible one. An older stable server may not work with a nightly app.

Every release is signed with the same key. Its certificate SHA-256 is listed in each release's notes, so you can check it with `apksigner verify --print-certs`.

## Maintainer guide

### One-time setup

1. Install [mise](https://mise.jdx.dev), then from this directory:

   ```sh
   mise trust
   mise install           # node, java, Android cmdline-tools, vp, gh
   mise run android-sdk   # SDK platform, build-tools, NDK and CMake
   gh auth login
   ```

2. Create the configuration file and pick a strong keystore password:

   ```sh
   cp release.env.example release.env
   $EDITOR release.env
   ```

3. Generate the release keystore once:

   ```sh
   mise run keystore
   ```

   It is written to `~/.config/t3code-android-nightly/release.keystore` by default. Back up the keystore and its password. Every release must be signed with this key. If you lose it, users cannot update and have to uninstall and reinstall the app.

4. Create the GitHub repository and push this branch. Releases commit to it.

### Publishing a release

```sh
mise run release                     # build the newest upstream nightly tag and publish it
mise run release -- --dry-run        # build and verify, even if already released; publish nothing
mise run release -- --tag <tag>      # build a specific upstream tag
mise run release -- --no-t3-connect  # build without T3 Connect
```

The script:

1. When publishing, requires a clean checkout of this repository that matches its remote branch, since it will commit and push.
2. Clones or updates upstream into `~/.cache/t3code-android-nightly/upstream` (override with `NIGHTLY_CACHE_DIR`) and picks the newest `v*-nightly.*` tag. If a release with that tag already exists, it stops: new upstream commits without a new tag are ignored.
3. Reads the markers at the end of the latest release's notes and refuses to continue if the keystore's certificate differs from the one that signed it.
4. Copies upstream's `.env.example` to `.env` in the checkout to enable T3 Connect (skip with `--no-t3-connect` or `NIGHTLY_T3_CONNECT=0`).
5. Runs `vp i --frozen-lockfile`, then `expo prebuild --platform android` and `./gradlew :app:assembleRelease` in `apps/mobile` with `APP_VARIANT=preview` and `T3CODE_MOBILE_UPDATES_ENABLED=0`. Native code is compiled only for `arm64-v8a` (override with `NIGHTLY_ARCHITECTURES`), and Gradle's build cache in `~/.gradle` reuses outputs from earlier builds. With `NIGHTLY_IDLE=1` the whole build runs at idle CPU and I/O priority (a `systemd-run` scope with `CPUWeight=idle`, or `nice`/`ionice` without systemd) so the machine stays usable.
6. Patches the generated `android/app/build.gradle` in the cache, not upstream sources, so that:
   - `versionCode` is the build time in minutes since the Unix epoch, raised above the latest release's if needed, so it always increases.
   - `versionName` is the upstream tag, for example `v0.0.46-nightly.20261007.2774`.
7. Signs the APK with `apksigner` after Gradle finishes, so build scripts never see the key. It then checks the package id, version, signing certificate, 16 KB zip alignment, the native library ABIs, that the JS bundle is present and that the T3 Connect config is embedded.
8. Writes the APK, its SHA-256, the upstream license and the release notes to `dist/<tag>/`.
9. Updates the "Current build" line in this README, commits it as `Release <tag>`, pushes, and creates the GitHub Release on that commit.

Configuration is read from the environment and from `release.env`, with the environment taking precedence; see [`release.env.example`](release.env.example).

## License

T3 Code is released under the MIT License, copyright T3 Tools Inc. See [NOTICE](NOTICE). Each release includes the upstream license as `LICENSE-t3code.txt`.
