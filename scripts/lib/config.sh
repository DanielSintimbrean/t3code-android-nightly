# Configuration shared by the release scripts. Source it, then call load_config.
# Values set in the environment take precedence over release.env.

load_config() {
  local repo_root="$1" name
  if [[ -f "$repo_root/release.env" ]]; then
    local -A preset=()
    while IFS= read -r name; do
      preset[$name]="${!name}"
    done < <(compgen -e | grep '^NIGHTLY_' || true)
    # shellcheck disable=SC1091
    source "$repo_root/release.env"
    for name in "${!preset[@]}"; do
      printf -v "$name" '%s' "${preset[$name]}"
    done
  fi

  NIGHTLY_KEYSTORE_FILE="${NIGHTLY_KEYSTORE_FILE:-$HOME/.config/t3code-android-nightly/release.keystore}"
  NIGHTLY_KEY_ALIAS="${NIGHTLY_KEY_ALIAS:-t3code-nightly}"
  NIGHTLY_KEYSTORE_PASSWORD="${NIGHTLY_KEYSTORE_PASSWORD:-}"
  NIGHTLY_KEY_PASSWORD="${NIGHTLY_KEY_PASSWORD:-$NIGHTLY_KEYSTORE_PASSWORD}"
  # Secrets are passed to the one command that needs them, never to the build.
  export -n NIGHTLY_KEYSTORE_PASSWORD NIGHTLY_KEY_PASSWORD
}
