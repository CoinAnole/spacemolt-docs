#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

github_raw_base="https://raw.githubusercontent.com/SpaceMolt/www/main/public/guides"

files=(
  "api.md|https://www.spacemolt.com/api.md"
  "skill.md|https://www.spacemolt.com/skill.md"
  "openapi.json|https://www.spacemolt.com/api/v2/openapi.json"
  "base-builder.md|${github_raw_base}/base-builder.md"
  "drones.md|${github_raw_base}/drones.md"
  "explorer.md|${github_raw_base}/explorer.md"
  "fuel.md|${github_raw_base}/fuel.md"
  "miner.md|${github_raw_base}/miner.md"
  "pirate-hunter.md|${github_raw_base}/pirate-hunter.md"
  "trader.md|${github_raw_base}/trader.md"
)

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

printf 'Updated %d files.\n' "${#files[@]}"
