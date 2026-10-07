#!/usr/bin/env bash
# Builds the T3 Code Android Preview APK from an upstream nightly tag, signs
# it with the stable release key, verifies it, records the version in
# README.md and publishes it as a GitHub Release.
#
# Usage: scripts/release.sh [--tag TAG] [--dry-run] [--repo OWNER/NAME]
#                           [--version-code N] [--no-t3-connect]
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [options]

  --tag TAG           Upstream tag to build (default: the newest v*-nightly.* tag)
  --dry-run           Build and verify, even if already released, but do not
                      commit, push or create a GitHub Release
  --repo OWNER/NAME   GitHub repository to publish to
                      (default: $NIGHTLY_REPO, the origin remote, or
                      DanielSintimbrean/t3code-android-nightly)
  --version-code N    Override the Android versionCode; must exceed the latest
                      release's (default: minutes since the Unix epoch)
  --no-t3-connect     Build without T3 Connect (default: enabled with upstream's
                      public production config from .env.example)
  -h, --help          Show this help

Configuration is read from the environment and from release.env in the
repository root (see release.env.example).
EOF
}

log() { printf '\n==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The build saturates every core. NIGHTLY_IDLE=1 runs it at idle priority to
# keep the desktop usable. Under cgroup v2, nice only orders processes within
# one cgroup, so prefer a separate scope with idle CPU weight.
if [[ "${NIGHTLY_IDLE:-0}" == 1 && -z "${NIGHTLY_IDLE_ACTIVE:-}" ]]; then
  export NIGHTLY_IDLE_ACTIVE=1
  if command -v systemd-run >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    exec systemd-run --user --scope --quiet -p CPUWeight=idle -p IOWeight=1 -- "${BASH_SOURCE[0]}" "$@"
  fi
  renice -n 19 -p $$ >/dev/null || true
  ionice -c 3 -p $$ 2>/dev/null || true
fi

tag=""
dry_run=0
repo=""
version_code=""
t3_connect_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    --version-code) version_code="${2:?--version-code needs a value}"; shift 2 ;;
    --no-t3-connect) t3_connect_override=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

# --- Configuration ----------------------------------------------------------

# shellcheck source=scripts/lib/config.sh
source "$repo_root/scripts/lib/config.sh"
load_config "$repo_root"

# Use the toolchain pinned in mise.toml regardless of the current directory;
# the upstream checkout lives outside this repository.
command -v mise >/dev/null || die "mise is required (https://mise.jdx.dev)"
mise_env="$(mise env -C "$repo_root" -s bash)" ||
  die "mise could not load $repo_root/mise.toml (run 'mise trust' and 'mise install')"
eval "$mise_env"

upstream_url="${NIGHTLY_UPSTREAM_URL:-https://github.com/pingdotgg/t3code.git}"
upstream_web="${upstream_url%.git}"
cache_dir="${NIGHTLY_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/t3code-android-nightly}"
src="$cache_dir/upstream"
keystore="$NIGHTLY_KEYSTORE_FILE"
key_alias="$NIGHTLY_KEY_ALIAS"
expected_package="com.t3tools.t3code.preview"
max_version_code=2100000000

# Native code is compiled once per ABI, which dominates the build time.
# 64-bit ARM covers current phones; add ABIs as a comma-separated list.
architectures="${NIGHTLY_ARCHITECTURES:-arm64-v8a}"
[[ "$architectures" =~ ^(armeabi-v7a|arm64-v8a|x86|x86_64)(,(armeabi-v7a|arm64-v8a|x86|x86_64))*$ ]] ||
  die "NIGHTLY_ARCHITECTURES must be a comma-separated list of armeabi-v7a, arm64-v8a, x86, x86_64"

t3_connect="${t3_connect_override:-${NIGHTLY_T3_CONNECT:-1}}"
[[ "$t3_connect" == 0 || "$t3_connect" == 1 ]] || die "NIGHTLY_T3_CONNECT must be 0 or 1"
# The checkout's .env is the only source of T3 Connect settings; upstream's
# config loader would otherwise also pick these up from the shell.
unset T3CODE_CLERK_PUBLISHABLE_KEY VITE_CLERK_PUBLISHABLE_KEY EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY \
  T3CODE_CLERK_JWT_TEMPLATE VITE_CLERK_JWT_TEMPLATE EXPO_PUBLIC_CLERK_JWT_TEMPLATE \
  T3CODE_RELAY_URL VITE_T3CODE_RELAY_URL

repo="${repo:-${NIGHTLY_REPO:-}}"
if [[ -z "$repo" ]]; then
  origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    repo="${BASH_REMATCH[1]%.git}"
  else
    repo="DanielSintimbrean/t3code-android-nightly"
  fi
fi

if [[ -n "$version_code" ]] &&
  ! [[ "$version_code" =~ ^[1-9][0-9]*$ && "$version_code" -le $max_version_code ]]; then
  die "--version-code must be an integer between 1 and $max_version_code"
fi

# --- Preflight ----------------------------------------------------------------

for tool in git node vp java keytool unzip sha256sum flock; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
[[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/build-tools" ]] ||
  die "ANDROID_HOME has no build-tools; run 'mise run android-sdk'"
build_tools="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
for tool in apksigner aapt2 zipalign; do
  [[ -x "$build_tools/$tool" ]] || die "$tool not found in $build_tools"
done

[[ -f "$keystore" ]] ||
  die "release keystore not found at $keystore (generate it once with 'mise run keystore')"
[[ -n "$NIGHTLY_KEYSTORE_PASSWORD" ]] || die "NIGHTLY_KEYSTORE_PASSWORD is not set"
case "$keystore" in
  "$repo_root"/*) die "the keystore must live outside the repository" ;;
esac

# keytool prints the digest as colon-separated uppercase hex; apksigner as plain lowercase.
normalize_digest() { tr -d ':\r ' | tr '[:upper:]' '[:lower:]'; }
expected_cert="$(
  NIGHTLY_KEYSTORE_PASSWORD="$NIGHTLY_KEYSTORE_PASSWORD" keytool -list -v \
    -keystore "$keystore" -alias "$key_alias" -storepass:env NIGHTLY_KEYSTORE_PASSWORD |
    sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | normalize_digest | sed -n 1p
)"
[[ "$expected_cert" =~ ^[0-9a-f]{64}$ ]] ||
  die "could not read alias '$key_alias' from $keystore (wrong password or alias?)"

# Prints a GitHub API response. Returns 1 if the resource does not exist and 2
# on any other failure, so an outage is never mistaken for "no release".
gh_get() {
  local out
  if out="$(gh api "$@" 2>&1)"; then
    printf '%s\n' "$out"
  elif [[ "$out" == *"HTTP 404"* ]]; then
    return 1
  else
    printf 'error: GitHub API request failed (gh api %s): %s\n' "$*" "$out" >&2
    return 2
  fi
}

release_exists() {
  local status=0
  gh_get "repos/$repo/releases/tags/$1" >/dev/null || status=$?
  ((status != 2)) || exit 1
  ((status == 0))
}

gh_ready=0
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1 &&
  gh repo view "$repo" --json name >/dev/null 2>&1; then
  gh_ready=1
elif [[ $dry_run -eq 0 ]]; then
  die "gh cannot access $repo (install gh, run 'gh auth login', and create the repository first)"
else
  warn "gh cannot access $repo; skipping release checks in dry-run mode"
fi

# Publishing commits README.md and pushes it, so start from a clean checkout
# that matches its remote branch.
branch=""
if [[ $dry_run -eq 0 ]]; then
  [[ -z "$(git -C "$repo_root" status --porcelain)" ]] ||
    die "the repository has uncommitted changes; commit or stash them first"
  branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD)" || die "the repository is not on a branch"
  git -C "$repo_root" fetch --quiet origin "$branch" || die "could not fetch origin/$branch"
  [[ "$(git -C "$repo_root" rev-parse HEAD)" == "$(git -C "$repo_root" rev-parse "origin/$branch")" ]] ||
    die "$branch is not in sync with origin/$branch; pull or push first"
fi

mkdir -p "$cache_dir"
exec 9>"$cache_dir/release.lock"
flock -n 9 || die "another release is already running (lock: $cache_dir/release.lock)"

# --- Upstream checkout ------------------------------------------------------

log "Fetching $upstream_url"
if [[ ! -d "$src/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$upstream_url" "$src"
fi
git -C "$src" remote set-url origin "$upstream_url"
git -C "$src" fetch --prune --prune-tags --tags --force origin

# Upstream tags each nightly as vX.Y.Z-nightly.YYYYMMDD.N. Only tags trigger
# a build, so commits on main without a new tag are ignored.
if [[ -z "$tag" ]]; then
  tag="$(git -C "$src" tag -l 'v*-nightly.*' --sort=-v:refname | sed -n 1p)"
  [[ -n "$tag" ]] || die "upstream has no v*-nightly.* tags"
fi
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsupported tag name: $tag"
sha="$(git -C "$src" rev-parse --verify --quiet "refs/tags/$tag^{commit}")" ||
  die "upstream tag not found: $tag"
short="${sha:0:7}"
subject="$(git -C "$src" log -1 --format=%s "$sha")"
commit_date="$(git -C "$src" log -1 --format=%cI "$sha")"
log "Upstream $tag is $sha ($subject)"

if [[ $gh_ready -eq 1 ]] && release_exists "$tag"; then
  if [[ $dry_run -eq 0 ]]; then
    log "$tag is already released; nothing to do"
    exit 0
  fi
  warn "$tag is already released; building anyway because of --dry-run"
fi

# Each release body ends with machine-readable markers (see the notes below).
previous_sha=""
previous_code=0
if [[ $gh_ready -eq 1 ]]; then
  latest_body="$(gh_get "repos/$repo/releases/latest" --jq .body)" ||
    { [[ $? -eq 1 ]] || exit 1; latest_body=""; }
  marker() { sed -n "s/.*<!-- $1: \([^ ]*\) -->.*/\1/p" <<<"$latest_body" | sed -n 1p; }
  previous_sha="$(marker upstream-sha)"
  previous_code="$(marker version-code)"
  previous_code="${previous_code:-0}"
  [[ "$previous_code" =~ ^[0-9]+$ ]] || die "invalid version-code marker in the latest release: $previous_code"
  previous_cert="$(marker signing-cert)"
  if [[ -n "$previous_cert" && "$previous_cert" != "$expected_cert" ]]; then
    die "the keystore certificate ($expected_cert) differs from the one that signed the latest release ($previous_cert); users could not update"
  fi
fi

git -C "$src" reset --hard --quiet
git -C "$src" clean -ffd --quiet
git -C "$src" checkout --quiet --detach "$sha"
git -C "$src" clean -ffd --quiet
# Prebuild output is regenerated every time so build-time patches never stack.
rm -rf "$src/apps/mobile/android"

# T3 Connect is configured through the repository-root .env, which upstream
# keeps ignored. Upstream's .env.example carries the public identifiers of the
# production Clerk instance and relay that official builds use.
rm -f "$src/.env" "$src/.env.local"
clerk_key="-"
relay_url="-"
if [[ "$t3_connect" == 1 ]]; then
  cp "$src/.env.example" "$src/.env"
  clerk_key="$(sed -n 's/^T3CODE_CLERK_PUBLISHABLE_KEY=//p' "$src/.env" | sed -n 1p)"
  relay_url="$(sed -n 's/^T3CODE_RELAY_URL=//p' "$src/.env" | sed -n 1p)"
  [[ -n "$clerk_key" && -n "$relay_url" ]] ||
    die "upstream .env.example no longer provides the T3 Connect config; update this script or pass --no-t3-connect"
  log "T3 Connect enabled (relay: $relay_url)"
else
  log "T3 Connect disabled"
fi

# --- Version ----------------------------------------------------------------

# Minutes since the epoch, bumped past the latest release if needed, so every
# release has a higher versionCode than the one before.
if [[ -z "$version_code" ]]; then
  version_code=$(($(date -u +%s) / 60))
  ((version_code > previous_code)) || version_code=$((previous_code + 1))
fi
((version_code > previous_code)) ||
  die "versionCode $version_code must be greater than the latest release's ($previous_code)"
((version_code <= max_version_code)) || die "versionCode $version_code exceeds $max_version_code"

# --- Build ------------------------------------------------------------------

export APP_VARIANT=preview
export T3CODE_MOBILE_UPDATES_ENABLED=0
export EXPO_NO_GIT_STATUS=1

log "Installing dependencies"
(cd "$src" && vp i --frozen-lockfile)

# react-native-shiki-engine looks up its bundled per-ABI libonig.so without
# NO_DEFAULT_PATH, so CMake picks a host /usr/lib/libonig.so first when the
# oniguruma system package is installed, and the Android link fails. Restrict
# the lookup to the bundled jniLibs. sed -i replaces the file, so the shared
# pnpm store it is hard-linked from stays untouched.
for cmake_file in "$src"/node_modules/.pnpm/react-native-shiki-engine@*/node_modules/react-native-shiki-engine/android/CMakeLists.txt; do
  [[ -f "$cmake_file" ]] || continue
  if ! grep -q 'NO_CMAKE_FIND_ROOT_PATH NO_DEFAULT_PATH' "$cmake_file"; then
    sed -i 's/^\([[:space:]]*\)NO_CMAKE_FIND_ROOT_PATH$/\1NO_CMAKE_FIND_ROOT_PATH NO_DEFAULT_PATH/' "$cmake_file"
    grep -q 'NO_CMAKE_FIND_ROOT_PATH NO_DEFAULT_PATH' "$cmake_file" || die "could not patch $cmake_file"
    log "Patched libonig lookup in $cmake_file"
  fi
done

log "Running expo prebuild (Android, preview)"
(cd "$src/apps/mobile" && vp exec -- expo prebuild --platform android </dev/null)

gradle_file="$src/apps/mobile/android/app/build.gradle"
[[ -f "$gradle_file" ]] || die "prebuild did not produce $gradle_file"
# The version name is the upstream tag, the same string as the release tag.
version_name="$tag"
sed -i -E \
  -e "s/^([[:space:]]*)versionCode [0-9]+/\1versionCode $version_code/" \
  -e "s/^([[:space:]]*)versionName \"[^\"]+\"/\1versionName \"$version_name\"/" \
  "$gradle_file"
grep -q "versionCode $version_code\$" "$gradle_file" || die "could not set versionCode in $gradle_file"
grep -q "versionName \"$version_name\"" "$gradle_file" || die "could not set versionName in $gradle_file"
log "Version $version_name (versionCode $version_code)"

# Gradle signs with the template's debug key; the release key is applied
# afterwards so that no build script ever sees it. The android/ directory is
# regenerated every run, so task outputs are reused through the build cache in
# ~/.gradle instead of the project's up-to-date checks.
log "Building release APK ($architectures)"
(cd "$src/apps/mobile/android" &&
  ./gradlew :app:assembleRelease --no-daemon --build-cache -PreactNativeArchitectures="$architectures")

built_apk="$src/apps/mobile/android/app/build/outputs/apk/release/app-release.apk"
[[ -f "$built_apk" ]] || die "APK not found at $built_apk"

out_dir="$repo_root/dist/$tag"
asset_name="t3code-preview-$tag.apk"
apk="$out_dir/$asset_name"
rm -rf "$out_dir"
mkdir -p "$out_dir"

log "Signing with the release key"
NIGHTLY_KEYSTORE_PASSWORD="$NIGHTLY_KEYSTORE_PASSWORD" NIGHTLY_KEY_PASSWORD="$NIGHTLY_KEY_PASSWORD" \
  "$build_tools/apksigner" sign \
  --ks "$keystore" --ks-key-alias "$key_alias" \
  --ks-pass env:NIGHTLY_KEYSTORE_PASSWORD --key-pass env:NIGHTLY_KEY_PASSWORD \
  --v4-signing-enabled false \
  --out "$apk" "$built_apk"

# --- Verify -----------------------------------------------------------------

log "Verifying APK"
badging="$("$build_tools/aapt2" dump badging "$apk" | sed -n 1p)"
[[ "$badging" == *"name='$expected_package'"* ]] || die "unexpected package: $badging"
[[ "$badging" == *"versionCode='$version_code'"* ]] || die "unexpected versionCode: $badging"
[[ "$badging" == *"versionName='$version_name'"* ]] || die "unexpected versionName: $badging"

# Native libraries must stay 16 KB aligned for Android 15+ devices.
"$build_tools/zipalign" -c -P 16 4 "$apk" >/dev/null || die "APK is not zip-aligned"

certs="$("$build_tools/apksigner" verify --print-certs "$apk")" || die "apksigner rejected the APK"
# One digest line per signature scheme (e.g. "V3.0 Signer: ..."); all must be the release key.
signer_certs="$(sed -n 's/.*certificate SHA-256 digest: //p' <<<"$certs" | normalize_digest | sort -u)"
[[ "$signer_certs" == "$expected_cert" ]] ||
  die "APK is signed with '$(tr '\n' ' ' <<<"$signer_certs")', expected the release key $expected_cert"

apk_abis="$(unzip -Z1 "$apk" 'lib/*' 2>/dev/null | cut -d/ -f2 | sort -u | paste -sd,)"
[[ "$apk_abis" == "$(tr ',' '\n' <<<"$architectures" | sort -u | paste -sd,)" ]] ||
  die "APK native libraries are for '$apk_abis', expected '$architectures'"

bundle_size="$(unzip -l "$apk" assets/index.android.bundle | awk '$4 == "assets/index.android.bundle" { print $1 }')"
[[ "${bundle_size:-0}" -gt 0 ]] || die "assets/index.android.bundle is missing from the APK"

# The app reads T3 Connect settings from the embedded Expo config; "-" means unset.
embedded="$(unzip -p "$apk" assets/app.config | node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d)).on("end", () => {
    const extra = JSON.parse(s).extra ?? {};
    const str = (v) => (typeof v === "string" && v ? v : "-");
    console.log(str(extra.clerk?.publishableKey), str(extra.relay?.url));
  });
')" || die "could not read assets/app.config from the APK"
[[ "$embedded" == "$clerk_key $relay_url" ]] ||
  die "embedded T3 Connect config is '$embedded', expected '$clerk_key $relay_url'"
if [[ "$t3_connect" == 1 ]]; then
  t3_connect_line="- T3 Connect: enabled (relay \`$relay_url\`)"
else
  t3_connect_line="- T3 Connect: disabled"
fi

# --- Artifacts --------------------------------------------------------------

cp "$src/LICENSE" "$out_dir/LICENSE-t3code.txt"
(cd "$out_dir" && sha256sum "$asset_name" >"$asset_name.sha256")
apk_sha256="$(cut -d' ' -f1 "$out_dir/$asset_name.sha256")"
apk_size="$(du -h "$apk" | cut -f1)"

tooling_rev="$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null || echo none)"
[[ -z "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]] || tooling_rev+="-dirty"

compare_line=""
if [[ -n "$previous_sha" && "$previous_sha" != "$sha" ]]; then
  compare_line="- Changes since the previous nightly: [\`${previous_sha:0:7}...$short\`]($upstream_web/compare/$previous_sha...$sha)
"
fi

notes="$out_dir/release-notes.md"
cat >"$notes" <<EOF
Unofficial nightly build of the [T3 Code]($upstream_web) Android app (Preview variant). Not affiliated with or endorsed by T3 Tools Inc.

- Upstream: [\`$tag\`]($upstream_web/tree/$tag), commit [\`$short\`]($upstream_web/commit/$sha) $subject ($commit_date)
${compare_line}- Package: \`$expected_package\` (installs alongside the Play Store app)
- ABIs: $architectures
- versionCode: $version_code
- APK SHA-256: \`$apk_sha256\`
- Signing certificate SHA-256: \`$expected_cert\`
$t3_connect_line

Connect it to a T3 Code server that is compatible with this upstream commit.

T3 Code is copyright T3 Tools Inc. and released under the MIT License; see \`LICENSE-t3code.txt\`.

<!-- upstream-tag: $tag -->
<!-- upstream-sha: $sha -->
<!-- version-code: $version_code -->
<!-- signing-cert: $expected_cert -->
<!-- t3-connect: $t3_connect -->
<!-- architectures: $architectures -->
<!-- tooling-rev: $tooling_rev -->
EOF

cat >&2 <<EOF

APK:       $apk
Size:      $apk_size
SHA-256:   $apk_sha256
Signer:    $expected_cert
Version:   $version_name ($version_code)
Upstream:  $sha
EOF

if [[ $dry_run -eq 1 ]]; then
  log "Dry run: not publishing $tag"
  exit 0
fi

# --- Publish ----------------------------------------------------------------

log "Recording $tag in README.md"
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] ||
  die "the repository changed during the build; not committing"
readme="$repo_root/README.md"
grep -q '<!-- current-build:start -->' "$readme" && grep -q '<!-- current-build:end -->' "$readme" ||
  die "README.md is missing the current-build markers"
current_build="**[$tag](https://github.com/$repo/releases/tag/$tag)**, built from upstream commit [\`$short\`]($upstream_web/commit/$sha) on $(date -u +%Y-%m-%d)."
awk -v line="$current_build" '
  /<!-- current-build:start -->/ { print; print line; skip = 1; next }
  /<!-- current-build:end -->/ { skip = 0 }
  !skip { print }
' "$readme" >"$readme.tmp"
mv "$readme.tmp" "$readme"
# A rerun after a failed release finds the README already up to date.
if ! git -C "$repo_root" diff --quiet -- README.md; then
  git -C "$repo_root" commit --quiet -m "Release $tag" -- README.md
  if ! git -C "$repo_root" push --quiet origin "HEAD:$branch"; then
    git -C "$repo_root" reset --quiet --hard HEAD~1
    die "git push failed; the README commit was undone"
  fi
fi

# gh uploads to a draft and only publishes once every asset is attached.
log "Publishing $tag to $repo"
gh release create "$tag" \
  --repo "$repo" \
  --target "$(git -C "$repo_root" rev-parse HEAD)" \
  --title "T3 Code Preview $tag" \
  --notes-file "$notes" \
  --latest \
  "$apk" \
  "$out_dir/$asset_name.sha256" \
  "$out_dir/LICENSE-t3code.txt"
log "Published https://github.com/$repo/releases/tag/$tag"
