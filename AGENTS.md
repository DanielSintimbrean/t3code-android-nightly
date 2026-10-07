# AGENTS.md

This repository publishes unofficial Android APKs of T3 Code (https://github.com/pingdotgg/t3code) as GitHub Releases for Obtainium. It holds release tooling and docs only.

## Rules

- Never add T3 Code source code here. Upstream is cloned at build time into `~/.cache/t3code-android-nightly/upstream` (`NIGHTLY_CACHE_DIR`). Build-time patches go to that checkout, which is reset on every run.
- Never commit keystores, passwords, `release.env` or `dist/`.
- The signing key must never change. Obtainium and Android reject updates signed with a different certificate, so don't add debug-key fallbacks.
- `versionCode` must increase with every release.
- Release notes end with HTML comment markers (`upstream-sha`, `version-code`, `signing-cert`, `t3-connect`, `tooling-rev`). The script reads them from the latest release to skip unchanged builds, keep `versionCode` increasing and refuse a different signing key. Keep them when editing the notes.
- Don't publish releases, push, or create tags unless the maintainer asks. Use `mise run release -- --dry-run` to validate changes.

## Layout

- `scripts/release.sh`: fetch upstream, build the Preview APK, sign, verify, publish (`mise run release`).
- `scripts/generate-keystore.sh`: one-time keystore generation (`mise run keystore`).
- `mise.toml`: pinned toolchain and the Android SDK install task. When upstream bumps Node (`engines`), `vite-plus`, Expo or React Native, update the pins and SDK packages to match `apps/mobile`.
- `scripts/lib/config.sh`: shared loader for `release.env` (environment wins) and defaults.
- `release.env.example`: configuration template.

## Upstream build flow

Mirrors upstream `apps/mobile/README.md`: `vp i` at the root, then in `apps/mobile` with `APP_VARIANT=preview` and `T3CODE_MOBILE_UPDATES_ENABLED=0`, `vp exec -- expo prebuild --platform android` and `cd android && ./gradlew :app:assembleRelease`. Gradle signs with the generated debug key; `scripts/release.sh` then re-signs with `apksigner` so upstream build code never gets the release key. T3 Connect is enabled by copying upstream's `.env.example` (public production Clerk and relay identifiers) to `.env` in the checkout before the build; `--no-t3-connect` skips it. If upstream changes this flow, update `scripts/release.sh` and the README together.

Build-time workarounds in `scripts/release.sh` (drop each one once upstream fixes it):

- `react-native-shiki-engine` resolves `libonig.so` without `NO_DEFAULT_PATH`, so a host oniguruma package (`/usr/lib/libonig.so`) breaks the Android link. The script patches the cached copy of its `CMakeLists.txt`.
