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
github_guides_api="https://api.github.com/repos/SpaceMolt/www/contents/public/guides?ref=main"
guide_manifest="guides-manifest.txt"

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
  "catalog.json|https://game.spacemolt.com/api/catalog.json"
  "ws.md|https://game.spacemolt.com/ws.md"
  "changelog.json|https://game.spacemolt.com/api/changelog"
)

declare -A fixed_targets=()
for entry in "${files[@]}"; do
  IFS='|' read -r target _ <<< "$entry"
  fixed_targets["$target"]=1
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

# raw.githubusercontent.com cannot list a directory, so use GitHub's contents API
# to discover the current set of top-level Markdown guides before downloading any
# installable files. Do not persist an ETag for this temporary index: a 304 would
# be unusable without a tracked copy of the response.
guide_index="_guides-index.json"
download "$guide_index" "$github_guides_api" false

if ! jq -e 'type == "array"' "${tmpdir}/${guide_index}" >/dev/null; then
  printf 'Invalid guide directory response from %s\n' "$github_guides_api" >&2
  exit 1
fi

guide_names_json="$(
  jq -c '[
    .[]
    | select(.type == "file")
    | .name
    | select(endswith(".md"))
  ] | unique | sort' "${tmpdir}/${guide_index}"
)"

if [[ "$(jq 'length' <<< "$guide_names_json")" -eq 0 ]]; then
  printf 'No Markdown guides found in %s; refusing to remove tracked guides.\n' \
    "$github_guides_api" >&2
  exit 1
fi

mapfile -t guide_names < <(jq -r '.[]' <<< "$guide_names_json")
declare -A current_guides=()
for guide in "${guide_names[@]}"; do
  # Guide names become repository-root paths. Restrict them to plain basenames
  # before using them for downloads, installs, removals, or git pathspecs.
  if [[ ! "$guide" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]]; then
    printf 'Unsafe guide filename returned by GitHub: %s\n' "$guide" >&2
    exit 1
  fi
  if [[ -v 'fixed_targets[$guide]' ]]; then
    printf 'Upstream guide conflicts with fixed document target: %s\n' "$guide" >&2
    exit 1
  fi
  current_guides["$guide"]=1
  files+=("${guide}|${github_raw_base}/${guide}")
done

removed_guides=()
if [[ -f "${repo_root}/${guide_manifest}" ]]; then
  while IFS= read -r guide || [[ -n "$guide" ]]; do
    [[ -z "$guide" ]] && continue
    if [[ ! "$guide" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]]; then
      printf 'Unsafe guide filename in %s: %s\n' "$guide_manifest" "$guide" >&2
      exit 1
    fi
    if [[ -v 'fixed_targets[$guide]' ]]; then
      printf 'Guide manifest conflicts with fixed document target: %s\n' "$guide" >&2
      exit 1
    fi
    if [[ ! -v 'current_guides[$guide]' ]]; then
      removed_guides+=("$guide")
    fi
  done < "${repo_root}/${guide_manifest}"
fi

for entry in "${files[@]}"; do
  IFS='|' read -r target url <<< "$entry"
  download "$target" "$url"
  sleep "$INTER_FETCH_DELAY"
done

for entry in "${files[@]}"; do
  IFS='|' read -r target _ <<< "$entry"
  install -m 0644 "${tmpdir}/${target}" "${repo_root}/${target}"
done

printf '%s\n' "${guide_names[@]}" > "${tmpdir}/${guide_manifest}"
install -m 0644 "${tmpdir}/${guide_manifest}" "${repo_root}/${guide_manifest}"

for guide in "${removed_guides[@]}"; do
  rm -f -- "${repo_root}/${guide}"
  printf 'Removed upstream guide %s\n' "$guide"
done

current_gameserver_version="$(jq -r '.info."x-gameserver-version" // ""' "$openapi_path")"
if [[ -z "$current_gameserver_version" ]]; then
  printf 'Missing info.x-gameserver-version in %s\n' "$openapi_path" >&2
  exit 1
fi

printf 'Updated %d documents (%d guides).\n' "${#files[@]}" "${#guide_names[@]}"

if [[ "$current_gameserver_version" != "$previous_gameserver_version" ]]; then
  targets=("$guide_manifest")
  for entry in "${files[@]}"; do
    IFS='|' read -r target _ <<< "$entry"
    targets+=("$target")
  done
  targets+=("${removed_guides[@]}")

  git -C "$repo_root" add --all -- "${targets[@]}"
  if git -C "$repo_root" diff --cached --quiet -- "${targets[@]}"; then
    printf 'Gameserver version changed to %s, but there are no staged doc changes to commit.\n' "$current_gameserver_version"
  else
    git -C "$repo_root" commit -m "$current_gameserver_version" -- "${targets[@]}"
  fi
else
  printf 'Gameserver version unchanged: %s\n' "$current_gameserver_version"
fi
