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

CURL_RETRY_MAX_ATTEMPTS="${CURL_RETRY_MAX_ATTEMPTS:-8}"
CURL_RETRY_BASE_DELAY="${CURL_RETRY_BASE_DELAY:-5}"

# Identify ourselves politely. Some origins (and CDNs/WAFs in front of them) apply
# different rate limits or bot handling to generic "curl/..." User-Agents vs
# identified clients. GitHub runner IPs are also often treated as automation traffic.
DOCS_UPDATER_UA="${DOCS_UPDATER_UA:-spacemolt-docs-updater/1.0 (https://github.com/CoinAnole/spacemolt-docs)}"
# Small delay between top-level fetches to reduce burstiness against origin rate limits.
INTER_FETCH_DELAY="${INTER_FETCH_DELAY:-2}"

files=(
  "api.md|https://www.spacemolt.com/api.md"
  "skill.md|https://www.spacemolt.com/skill.md"
  "openapi-v1.json|https://game.spacemolt.com/api/openapi.json"
  "openapi.json|https://game.spacemolt.com/api/v2/openapi.json"
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
  local attempt=1
  local delay="$CURL_RETRY_BASE_DELAY"
  local status=""

  mkdir -p "$(dirname -- "$tmpfile")"
  printf 'Fetching %s\n' "$target"

  while (( attempt <= CURL_RETRY_MAX_ATTEMPTS )); do
    local headers_file="${tmpdir}/headers-${target//\//-}-${attempt}"

    status="$(
      curl --location --silent --show-error \
        --user-agent "$DOCS_UPDATER_UA" \
        --output "$tmpfile" \
        --dump-header "$headers_file" \
        --write-out '%{http_code}' \
        "$url"
    )"

    if [[ "$status" == "200" && -s "$tmpfile" ]]; then
      rm -f "$headers_file"
      return 0
    fi

    if [[ "$status" == "429" && attempt -lt CURL_RETRY_MAX_ATTEMPTS ]]; then
      local retry_after="$delay"
      if [[ -f "$headers_file" ]]; then
        local header_retry
        header_retry="$(
          awk 'tolower($1) == "retry-after:" { print $2; exit }' "$headers_file" | tr -d '\r'
        )"
        if [[ "$header_retry" =~ ^[0-9]+$ ]]; then
          retry_after="$header_retry"
        fi
      fi
      printf 'Rate limited fetching %s (HTTP 429, attempt %d/%d); retrying in %ss\n' \
        "$target" "$attempt" "$CURL_RETRY_MAX_ATTEMPTS" "$retry_after" >&2
      rm -f "$headers_file"
      sleep "$retry_after"
      attempt=$((attempt + 1))
      delay=$((delay * 2))
      continue
    fi

    rm -f "$headers_file"
    if [[ ! -s "$tmpfile" ]]; then
      printf 'Failed to fetch %s: HTTP %s (empty response)\n' "$url" "$status" >&2
    else
      printf 'Failed to fetch %s: HTTP %s\n' "$url" "$status" >&2
    fi
    return 1
  done

  printf 'Giving up on %s after %d attempts (last HTTP status: %s)\n' \
    "$url" "$CURL_RETRY_MAX_ATTEMPTS" "$status" >&2
  return 1
}

for entry in "${files[@]}"; do
  IFS='|' read -r target url <<< "$entry"
  download "$target" "$url"
  sleep "$INTER_FETCH_DELAY"
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
