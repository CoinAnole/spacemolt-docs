#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to read openapi.json gameserver versions.\n' >&2
  exit 1
fi

github_raw_base="https://raw.githubusercontent.com/SpaceMolt/www/main/public"
github_www_repo="https://github.com/SpaceMolt/www.git"
collections=("docs" "guides")

CURL_RETRY_MAX_ATTEMPTS="${CURL_RETRY_MAX_ATTEMPTS:-8}"
CURL_RETRY_BASE_DELAY="${CURL_RETRY_BASE_DELAY:-5}"

# Identify ourselves politely. Some origins (and CDNs/WAFs in front of them) apply
# different rate limits or bot handling to generic "curl/..." User-Agents vs
# identified clients. GitHub runner IPs are also often treated as automation traffic.
DOCS_UPDATER_UA="${DOCS_UPDATER_UA:-spacemolt-docs-updater/1.0 (https://github.com/CoinAnole/spacemolt-docs)}"
# Small delay between top-level fetches to reduce burstiness against origin rate limits.
INTER_FETCH_DELAY="${INTER_FETCH_DELAY:-2}"
# OpenAPI v1 and v2 share one bucket of 1 request per minute per IP. catalog.json
# is limited the same way on its own bucket. After a request in a bucket, wait at
# least this long before the next one. Unrestricted documents fill that wait.
SPEC_MIN_INTERVAL="${SPEC_MIN_INTERVAL:-60}"
FETCH_FALLBACK_DELAY="$CURL_RETRY_BASE_DELAY"
FETCH_RETRY_AFTER=0

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

# OpenAPI spec fetches share a bucket. The catalog dump uses a separate one.
spec_bucket_for_url() {
  case "$1" in
    https://game.spacemolt.com/api/openapi.json|https://game.spacemolt.com/api/v2/openapi.json)
      printf 'openapi'
      ;;
    https://game.spacemolt.com/api/catalog.json)
      printf 'catalog'
      ;;
    *)
      printf ''
      ;;
  esac
}

epoch_now() {
  date +%s
}

# One HTTP attempt. Returns 0 on a usable body, 2 on HTTP 429, and 1 otherwise.
# On 429, FETCH_RETRY_AFTER is the seconds to wait before trying this URL again.
fetch_once() {
  local target="$1"
  local url="$2"
  local use_persistent_etag="${3:-true}"
  local attempt="$4"
  local tmpfile="${tmpdir}/${target}"
  local headers_file="${tmpdir}/headers-${target//\//-}-${attempt}"
  local status=""
  local fallback="${FETCH_FALLBACK_DELAY:-$CURL_RETRY_BASE_DELAY}"

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

  if [[ "$status" == "429" ]]; then
    local retry_after="$fallback"
    if [[ -f "$headers_file" ]]; then
      local header_retry
      header_retry="$(
        awk 'tolower($1) == "retry-after:" { print $2; exit }' "$headers_file" | tr -d '\r'
      )"
      if [[ "$header_retry" =~ ^[0-9]+$ ]]; then
        retry_after="$header_retry"
      fi
    fi
    FETCH_RETRY_AFTER="$retry_after"
    rm -f "$headers_file"
    return 2
  fi

  rm -f "$headers_file"
  if [[ ! -s "$tmpfile" ]]; then
    printf 'Failed to fetch %s: HTTP %s (empty response)\n' "$url" "$status" >&2
  else
    printf 'Failed to fetch %s: HTTP %s\n' "$url" "$status" >&2
  fi
  return 1
}

pace_before_fetch() {
  local last_fetch_epoch="$1"
  if (( last_fetch_epoch == 0 || INTER_FETCH_DELAY == 0 )); then
    return 0
  fi
  local elapsed=$(( $(epoch_now) - last_fetch_epoch ))
  if (( elapsed < INTER_FETCH_DELAY )); then
    sleep $((INTER_FETCH_DELAY - elapsed))
  fi
  return 0
}

# Fetch fixed artifacts and collection Markdown without blocking on a spec
# rate limit. A bucket that is cooling down, or any single URL in Retry-After,
# stays queued while every other ready URL is fetched.
download_pending() {
  local -a targets=() urls=() etags=() buckets=()
  local -a attempts=() not_before=() delays=() done_flags=()
  local entry target url bucket

  for entry in "${fixed_files[@]}"; do
    IFS='|' read -r target url <<< "$entry"
    targets+=("$target")
    urls+=("$url")
    etags+=("true")
    buckets+=("$(spec_bucket_for_url "$url")")
    attempts+=(0)
    not_before+=(0)
    delays+=("$CURL_RETRY_BASE_DELAY")
    done_flags+=(0)
  done
  for entry in "${collection_files[@]}"; do
    IFS='|' read -r target url <<< "$entry"
    targets+=("$target")
    urls+=("$url")
    etags+=("false")
    buckets+=("$(spec_bucket_for_url "$url")")
    attempts+=(0)
    not_before+=(0)
    delays+=("$CURL_RETRY_BASE_DELAY")
    done_flags+=(0)
  done

  local pending=${#targets[@]}
  local last_fetch_epoch=0
  local -A bucket_not_before=()

  while (( pending > 0 )); do
    local now pick=-1 earliest=-1 earliest_target="" pass i
    local ready_at bucket_ready
    now="$(epoch_now)"

    for pass in spec other; do
      for i in "${!targets[@]}"; do
        if (( done_flags[i] == 1 )); then
          continue
        fi
        bucket="${buckets[i]}"
        if [[ "$pass" == spec && -z "$bucket" ]]; then
          continue
        fi
        if [[ "$pass" == other && -n "$bucket" ]]; then
          continue
        fi

        ready_at="${not_before[i]}"
        if [[ -n "$bucket" ]]; then
          bucket_ready="${bucket_not_before[$bucket]:-0}"
          if (( bucket_ready > ready_at )); then
            ready_at="$bucket_ready"
          fi
        fi
        if (( ready_at > now )); then
          if (( earliest < 0 || ready_at < earliest )); then
            earliest="$ready_at"
            earliest_target="${targets[i]}"
          fi
          continue
        fi

        pick="$i"
        break
      done
      if (( pick >= 0 )); then
        break
      fi
    done

    if (( pick < 0 )); then
      if (( earliest < 0 )); then
        printf 'Internal error: %d downloads still pending with nothing to wait for\n' \
          "$pending" >&2
        return 1
      fi
      now="$(epoch_now)"
      local wait_for=$((earliest - now))
      if (( wait_for > 0 )); then
        printf 'Waiting %ss for the rate limit on %s to expire\n' \
          "$wait_for" "$earliest_target" >&2
        sleep "$wait_for"
      fi
      continue
    fi

    pace_before_fetch "$last_fetch_epoch"

    target="${targets[pick]}"
    url="${urls[pick]}"
    attempts[pick]=$((attempts[pick] + 1))
    FETCH_FALLBACK_DELAY="${delays[pick]}"
    local rc=0
    fetch_once "$target" "$url" "${etags[pick]}" "${attempts[pick]}" || rc=$?
    last_fetch_epoch="$(epoch_now)"

    if (( rc == 0 )); then
      done_flags[pick]=1
      pending=$((pending - 1))
      if [[ -n "${buckets[pick]}" ]] && (( SPEC_MIN_INTERVAL > 0 )); then
        bucket_not_before["${buckets[pick]}"]=$((last_fetch_epoch + SPEC_MIN_INTERVAL))
      fi
      continue
    fi

    if (( rc == 2 && attempts[pick] < CURL_RETRY_MAX_ATTEMPTS )); then
      printf 'Rate limited fetching %s (HTTP 429, attempt %d/%d); retrying in %ss\n' \
        "$target" "${attempts[pick]}" "$CURL_RETRY_MAX_ATTEMPTS" "$FETCH_RETRY_AFTER" >&2
      now="$(epoch_now)"
      not_before[pick]=$((now + FETCH_RETRY_AFTER))
      delays[pick]=$((delays[pick] * 2))
      if [[ -n "${buckets[pick]}" ]]; then
        bucket_ready=$((now + FETCH_RETRY_AFTER))
        local previous="${bucket_not_before[${buckets[pick]}]:-0}"
        if (( bucket_ready > previous )); then
          bucket_not_before["${buckets[pick]}"]=$bucket_ready
        fi
      fi
      continue
    fi

    if (( rc == 2 )); then
      printf 'Failed to fetch %s: HTTP 429\n' "$url" >&2
    fi
    return 1
  done
}

# raw.githubusercontent.com cannot list directories. A blobless clone lists
# each managed collection without the contents API: unauthenticated
# api.github.com calls from GitHub-hosted runners share a 60-request hourly
# budget per IP, and a spent budget fails that call with HTTP 403. Collection
# names are also repository directories; files outside them are never
# considered for pruning. Tests point UPSTREAM_WWW_DIR at a local repository.
if [[ -n "${UPSTREAM_WWW_DIR:-}" ]]; then
  upstream_dir="$UPSTREAM_WWW_DIR"
  if [[ ! -e "${upstream_dir}/.git" && ! -f "${upstream_dir}/HEAD" ]]; then
    printf 'UPSTREAM_WWW_DIR is not a git checkout: %s\n' "$upstream_dir" >&2
    exit 1
  fi
else
  upstream_dir="${tmpdir}/www"
  printf 'Cloning SpaceMolt/www file index\n'
  if ! GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --filter=blob:none --no-checkout --branch main \
    "$github_www_repo" "$upstream_dir"; then
    printf 'Failed to clone the SpaceMolt/www file index.\n' >&2
    exit 1
  fi
fi

collection_files=()
declare -A collection_counts=()
declare -A current_collection_files=()

for collection in "${collections[@]}"; do
  printf 'Indexing upstream %s\n' "$collection"
  kind="$(git -C "$upstream_dir" cat-file -t "HEAD:public/${collection}" 2>/dev/null || true)"
  if [[ "$kind" != "tree" ]]; then
    printf 'Upstream %s directory is missing from SpaceMolt/www.\n' "$collection" >&2
    exit 1
  fi

  names=()
  while IFS= read -r -d '' entry; do
    name="${entry#*$'\t'}"
    meta="${entry%%$'\t'*}"
    entry_type="${meta#* }"
    entry_type="${entry_type%% *}"
    [[ "$entry_type" == "blob" && "$name" == *.md ]] || continue
    names+=("$name")
  done < <(git -C "$upstream_dir" ls-tree -z "HEAD:public/${collection}")

  if (( ${#names[@]} == 0 )); then
    printf 'No Markdown files found in upstream %s; refusing to prune the collection.\n' \
      "$collection" >&2
    exit 1
  fi
  names_file="${tmpdir}/collection-names-${collection}"
  printf '%s\0' "${names[@]}" | LC_ALL=C sort -zu > "$names_file"
  mapfile -d '' names < "$names_file"
  collection_counts["$collection"]="${#names[@]}"

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
# temporary responses so it can never receive an unusable 304. Spec buckets are
# fetched as soon as they are free, and unrestricted documents run during the
# 1/minute waits instead of leaving the updater idle.
download_pending

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
