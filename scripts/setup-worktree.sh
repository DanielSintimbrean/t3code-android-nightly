#!/usr/bin/env bash
# Share the main checkout's release configuration with a linked worktree.
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
project_root="${T3CODE_PROJECT_ROOT:-}"
if [[ -z "$project_root" ]]; then
  # T3 sets T3CODE_PROJECT_ROOT for setup hooks, but ordinary shells do not.
  IFS= read -r -d '' main_entry < <(git -C "$repo_root" worktree list --porcelain -z)
  project_root="${main_entry#worktree }"
fi
project_root="$(cd "$project_root" && pwd -P)" || die "cannot access the main checkout"
project_common="$(git -C "$project_root" rev-parse --path-format=absolute --git-common-dir)"
[[ "$project_common" == "$common_dir" ]] ||
  die "T3CODE_PROJECT_ROOT must point to a checkout of this repository"

source_config="$project_root/release.env"
[[ -f "$source_config" && -r "$source_config" ]] ||
  die "missing or unreadable $source_config; configure release.env in the main checkout first"

if [[ "$repo_root" != "$project_root" ]]; then
  target_config="$repo_root/release.env"
  [[ ! -e "$target_config" || -L "$target_config" ]] ||
    die "$target_config is an existing file; refusing to replace it"
  [[ ! -d "$target_config" ]] || die "$target_config is a directory; refusing to replace it"
  ln -sfnT -- "$source_config" "$target_config"
  printf 'Linked release.env to %s\n' "$source_config"
fi

mise trust -q "$repo_root/mise.toml"
printf 'Worktree setup complete.\n'
