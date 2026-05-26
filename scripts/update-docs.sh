#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to read openapi.json gameserver versions.\n' >&2
  exit 1
fi

github_raw_base="https://raw.githubusercontent.com/SpaceMolt/www/main/public/guides"

files=(
  "api.md|https://www.spacemolt.com/api.md"
  "skill.md|https://www.spacemolt.com/skill.md"
  "openapi-v1.json|https://game.spacemolt.com/api/openapi.json"
  "openapi.json|https://www.spacemolt.com/api/v2/openapi.json"
  "base-builder.md|${github_raw_base}/base-builder.md"
  "drones.md|${github_raw_base}/drones.md"
  "explorer.md|${github_raw_base}/explorer.md"
  "fuel.md|${github_raw_base}/fuel.md"
  "miner.md|${github_raw_base}/miner.md"
  "pirate-hunter.md|${github_raw_base}/pirate-hunter.md"
  "trader.md|${github_raw_base}/trader.md"
)

openapi_path="${repo_root}/openapi.json"
previous_gameserver_version=""
if [[ -f "$openapi_path" ]]; then
  previous_gameserver_version="$(jq -r '.info."x-gameserver-version" // ""' "$openapi_path")"
fi

download() {
  local target="$1"
  local url="$2"
  local tmpfile="${tmpdir}/${target}"

  mkdir -p "$(dirname -- "$tmpfile")"
  printf 'Fetching %s\n' "$target"
  curl --fail --location --silent --show-error --output "$tmpfile" "$url"

  if [[ ! -s "$tmpfile" ]]; then
    printf 'Downloaded file is empty: %s\n' "$url" >&2
    return 1
  fi
}

for entry in "${files[@]}"; do
  IFS='|' read -r target url <<< "$entry"
  download "$target" "$url"
done

for entry in "${files[@]}"; do
  IFS='|' read -r target _ <<< "$entry"
  install -m 0644 "${tmpdir}/${target}" "${repo_root}/${target}"
done

current_gameserver_version="$(jq -r '.info."x-gameserver-version" // ""' "$openapi_path")"
if [[ -z "$current_gameserver_version" ]]; then
  printf 'Missing info.x-gameserver-version in %s\n' "$openapi_path" >&2
  exit 1
fi

printf 'Updated %d files.\n' "${#files[@]}"

if [[ "$current_gameserver_version" != "$previous_gameserver_version" ]]; then
  targets=()
  for entry in "${files[@]}"; do
    IFS='|' read -r target _ <<< "$entry"
    targets+=("$target")
  done

  git -C "$repo_root" add -- "${targets[@]}"
  if git -C "$repo_root" diff --cached --quiet -- "${targets[@]}"; then
    printf 'Gameserver version changed to %s, but there are no staged doc changes to commit.\n' "$current_gameserver_version"
  else
    git -C "$repo_root" commit -m "$current_gameserver_version" -- "${targets[@]}"
  fi
else
  printf 'Gameserver version unchanged: %s\n' "$current_gameserver_version"
fi
