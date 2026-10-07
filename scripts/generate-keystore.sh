#!/usr/bin/env bash
# Generates the stable release keystore used to sign every nightly APK.
# Run once. Obtainium (and Android) reject updates signed with a different key.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/config.sh
source "$repo_root/scripts/lib/config.sh"
load_config "$repo_root"

keystore="$NIGHTLY_KEYSTORE_FILE"
alias_name="$NIGHTLY_KEY_ALIAS"

if [[ -e "$keystore" ]]; then
  echo "error: $keystore already exists; refusing to overwrite it." >&2
  exit 1
fi
case "$keystore" in
  "$repo_root"/*)
    echo "error: keep the keystore outside the repository ($keystore)." >&2
    exit 1
    ;;
esac

# Only a directory created here is restricted; never chmod an existing one.
[[ -d "$(dirname "$keystore")" ]] || mkdir -p -m 700 "$(dirname "$keystore")"

# keytool prompts for the password when it is not provided.
password_args=()
if [[ -n "$NIGHTLY_KEYSTORE_PASSWORD" ]]; then
  export NIGHTLY_KEYSTORE_PASSWORD
  password_args=(-storepass:env NIGHTLY_KEYSTORE_PASSWORD)
fi

keytool -genkeypair \
  -keystore "$keystore" \
  -storetype PKCS12 \
  -alias "$alias_name" \
  -keyalg RSA -keysize 4096 \
  -validity 10000 \
  -dname "CN=T3 Code Android Nightly (unofficial)" \
  "${password_args[@]}"
chmod 600 "$keystore"

echo
echo "Created $keystore (alias: $alias_name)."
echo "Certificate SHA-256 (publish this so users can verify the APK):"
keytool -list -v -keystore "$keystore" -alias "$alias_name" "${password_args[@]}" \
  | sed -n 's/^[[:space:]]*SHA256: //p'
echo
echo "Back up the keystore and its password somewhere safe now."
