#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to read openapi.json gameserver versions.\n' >&2
  exit 1
fi

github_api_base="https://api.github.com/repos/SpaceMolt/www/contents/public"
github_raw_base="https://raw.githubusercontent.com/SpaceMolt/www/main/public"
collections=("docs" "guides")

CURL_RETRY_MAX_ATTEMPTS="${CURL_RETRY_MAX_ATTEMPTS:-8}"
CURL_RETRY_BASE_DELAY="${CURL_RETRY_BASE_DELAY:-5}"

# Identify ourselves politely. Some origins (and CDNs/WAFs in front of them) apply
# different rate limits or bot handling to generic "curl/..." User-Agents vs
# identified clients. GitHub runner IPs are also often treated as automation traffic.
DOCS_UPDATER_UA="${DOCS_UPDATER_UA:-spacemolt-docs-updater/1.0 (https://github.com/CoinAnole/spacemolt-docs)}"
# Small delay between top-level fetches to reduce burstiness against origin rate limits.
INTER_FETCH_DELAY="${INTER_FETCH_DELAY:-2}"

fixed_files=(
  "api.md|https://www.spacemolt.com/api.md"
  "skill.md|https://www.spacemolt.com/skill.md"
  "openapi-v1.json|https://game.spacemolt.com/api/openapi.json"
  "openapi.json|https://game.spacemolt.com/api/v2/openapi.json"
  "catalog.json|https://game.spacemolt.com/api/catalog.json"
  "ws.md|https://game.spacemolt.com/ws.md"
  "changelog.json|https://game.spacemolt.com/api/changelog"
)

fixed_targets=()
for entry in "${fixed_files[@]}"; do
  IFS='|' read -r target _ <<< "$entry"
  fixed_targets+=("$target")
done

openapi_path="${repo_root}/openapi.json"
previous_gameserver_version=""
if [[ -f "$openapi_path" ]]; then
  previous_gameserver_version="$(jq -r '.info."x-gameserver-version" // ""' "$openapi_path")"
fi

download() {
  local target="$1"
  local url="$2"
  local use_persistent_etag="${3:-true}"
  local tmpfile="${tmpdir}/${target}"
  local attempt=1
  local delay="$CURL_RETRY_BASE_DELAY"
  local status=""

  mkdir -p "$(dirname -- "$tmpfile")"
  printf 'Fetching %s\n' "$target"

  # Persistent ETag sidecar (dotfile, not committed) for conditional requests on
  # rate-limited, cacheable endpoints (catalog.json, openapi*.json).
  local etag_file="${repo_root}/.${target}.etag"
  local etag_args=()
  if [[ "$use_persistent_etag" == "true" ]]; then
    mkdir -p "$(dirname -- "$etag_file")"
    etag_args=(--etag-compare "$etag_file" --etag-save "$etag_file")
  fi

  while (( attempt <= CURL_RETRY_MAX_ATTEMPTS )); do
    local headers_file="${tmpdir}/headers-${target//\//-}-${attempt}"

    status="$(
      curl --location --silent --show-error \
        --user-agent "$DOCS_UPDATER_UA" \
        "${etag_args[@]}" \
        --output "$tmpfile" \
        --dump-header "$headers_file" \
        --write-out '%{http_code}' \
        "$url"
    )"

    if [[ "$status" == "200" && -s "$tmpfile" ]]; then
      rm -f "$headers_file"
      return 0
    fi

    if [[ "$status" == "304" ]]; then
      # Not modified — reuse the already-installed copy for this run.
      local existing="${repo_root}/${target}"
      if [[ -f "$existing" ]]; then
        cp "$existing" "$tmpfile"
        rm -f "$headers_file"
        return 0
      fi
      # No prior file despite 304 — fall through to error (should not happen).
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

# raw.githubusercontent.com cannot list directories, so discover each managed
# Markdown collection through GitHub's contents API. Collection names are also
# repository directories; files outside them are never considered for pruning.
collection_files=()
declare -A collection_counts=()
declare -A current_collection_files=()

for collection in "${collections[@]}"; do
  index_target="_collection-index/${collection}.json"
  index_url="${github_api_base}/${collection}?ref=main"
  download "$index_target" "$index_url" false
  sleep "$INTER_FETCH_DELAY"

  if ! jq -e 'type == "array"' "${tmpdir}/${index_target}" >/dev/null; then
    printf 'Invalid %s directory response from %s\n' "$collection" "$index_url" >&2
    exit 1
  fi

  names_json="$(
    jq -c '[
      .[]
      | select(.type == "file")
      | .name
      | select(endswith(".md"))
    ] | unique | sort' "${tmpdir}/${index_target}"
  )"

  collection_count="$(jq 'length' <<< "$names_json")"
  if [[ "$collection_count" -eq 0 ]]; then
    printf 'No Markdown files found in upstream %s; refusing to prune the collection.\n' \
      "$collection" >&2
    exit 1
  fi
  collection_counts["$collection"]="$collection_count"

  mapfile -t names < <(jq -r '.[]' <<< "$names_json")
  for name in "${names[@]}"; do
    # Names become paths under an updater-owned directory. Only accept a plain,
    # portable basename before using one for downloads, installs, or removals.
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]]; then
      printf 'Unsafe filename returned for upstream %s: %s\n' "$collection" "$name" >&2
      exit 1
    fi

    target="${collection}/${name}"
    current_collection_files["$target"]=1
    collection_files+=("${target}|${github_raw_base}/${collection}/${name}")
  done
done

# Fetch every installable file before modifying tracked documentation. Persistent
# ETags remain enabled for fixed artifacts; collection Markdown is small and uses
# temporary responses so it can never receive an unusable 304.
for entry in "${fixed_files[@]}"; do
  IFS='|' read -r target url <<< "$entry"
  download "$target" "$url"
  sleep "$INTER_FETCH_DELAY"
done

for entry in "${collection_files[@]}"; do
  IFS='|' read -r target url <<< "$entry"
  download "$target" "$url" false
  sleep "$INTER_FETCH_DELAY"
done

for collection in "${collections[@]}"; do
  mkdir -p "${repo_root}/${collection}"
done

for entry in "${fixed_files[@]}"; do
  IFS='|' read -r target _ <<< "$entry"
  install -m 0644 "${tmpdir}/${target}" "${repo_root}/${target}"
done

for entry in "${collection_files[@]}"; do
  IFS='|' read -r target _ <<< "$entry"
  install -m 0644 "${tmpdir}/${target}" "${repo_root}/${target}"
done

shopt -s nullglob
for collection in "${collections[@]}"; do
  for existing in "${repo_root}/${collection}/"*.md; do
    target="${collection}/$(basename -- "$existing")"
    if [[ ! -v 'current_collection_files[$target]' ]]; then
      rm -f -- "$existing"
      printf 'Removed upstream %s file %s\n' "$collection" "$(basename -- "$existing")"
    fi
  done
done
shopt -u nullglob

current_gameserver_version="$(jq -r '.info."x-gameserver-version" // ""' "$openapi_path")"
if [[ -z "$current_gameserver_version" ]]; then
  printf 'Missing info.x-gameserver-version in %s\n' "$openapi_path" >&2
  exit 1
fi

printf 'Updated %d fixed documents, %d reference docs, and %d guides.\n' \
  "${#fixed_files[@]}" "${collection_counts[docs]}" "${collection_counts[guides]}"

if [[ "$current_gameserver_version" != "$previous_gameserver_version" ]]; then
  targets=("${fixed_targets[@]}" "${collections[@]}")

  git -C "$repo_root" add --all -- "${targets[@]}"
  if git -C "$repo_root" diff --cached --quiet -- "${targets[@]}"; then
    printf 'Gameserver version changed to %s, but there are no staged doc changes to commit.\n' "$current_gameserver_version"
  else
    git -C "$repo_root" commit -m "$current_gameserver_version" -- "${targets[@]}"
  fi
else
  printf 'Gameserver version unchanged: %s\n' "$current_gameserver_version"
fi
