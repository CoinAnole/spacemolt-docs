#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
export INTER_FETCH_DELAY=0
# Production spaces shared spec buckets by 60s. Tests opt in when they cover that wait.
export SPEC_MIN_INTERVAL=0

default_upstream_files=(
  docs/crafting.md
  docs/new-doc.md
  docs/ignored.txt
  docs/nested/skip.md
  guides/crafting.md
  guides/new-guide.md
  guides/ignored.txt
  guides/nested/skip.md
)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'Assertion failed: %s\nexpected: %s\nactual: %s\n' \
      "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

make_upstream() {
  local dir="$1"
  shift

  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" config user.name 'Docs Test'
  git -C "$dir" config user.email 'docs-test@example.com'

  local rel
  if [[ $# -eq 0 ]]; then
    printf 'placeholder\n' > "${dir}/README"
    git -C "$dir" add -- README
  else
    for rel in "$@"; do
      mkdir -p "${dir}/public/$(dirname -- "$rel")"
      printf 'upstream %s\n' "$rel" > "${dir}/public/${rel}"
      git -C "$dir" add -- "public/${rel}"
    done
  fi
  git -C "$dir" commit --quiet -m upstream
}

write_fake_curl() {
  local next_version="$1"
  local bin_dir="$2"
  local rate_limit_pattern="${3:-}"
  local hard_failure_pattern="${4:-}"
  local rate_limit_retry_after="${5:-0}"
  local state_file="${bin_dir}/.rate-limit-state"
  local request_log="${bin_dir}/requests.log"

  cat > "${bin_dir}/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail

output=""
write_out=""
header_file=""
url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --output)
      output="\$2"
      shift 2
      ;;
    --write-out)
      write_out="\$2"
      shift 2
      ;;
    --dump-header)
      header_file="\$2"
      shift 2
      ;;
    http*)
      url="\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' "\$url" >> "$request_log"

status="200"
if [[ -n "$hard_failure_pattern" && "\$url" == *"$hard_failure_pattern"* ]]; then
  status="500"
  printf '{"error":"server_error"}\n' > "\$output"
elif [[ -n "$rate_limit_pattern" && "\$url" == *"$rate_limit_pattern"* ]]; then
  count=0
  if [[ -f "$state_file" ]]; then
    count="\$(<"$state_file")"
  fi
  count=\$((count + 1))
  printf '%s' "\$count" > "$state_file"
  if (( count == 1 )); then
    status="429"
    printf '{"error":"rate_limited"}\n' > "\$output"
    printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: %s\r\n\r\n' "$rate_limit_retry_after" > "\$header_file"
  fi
fi

if [[ "\$status" == "200" ]]; then
  case "\$url" in
    *"/api/v2/openapi.json")
      printf '{"info":{"x-gameserver-version":"%s"}}\n' "$next_version" > "\$output"
      ;;
    *"/api/openapi.json")
      printf '{"openapi":"3.0.0"}\n' > "\$output"
      ;;
    *"/api/catalog.json")
      printf '{"version":"%s","ships":[],"skills":[],"recipes":[],"items":[],"modules":[],"facilities":[]}\n' \
        "$next_version" > "\$output"
      ;;
    *)
      printf 'refreshed from %s\n' "\$url" > "\$output"
      ;;
  esac
fi

if [[ "\$write_out" == '%{http_code}' ]]; then
  printf '%s' "\$status"
fi
EOF
  chmod +x "${bin_dir}/curl"
}

make_fixture_repo() {
  local dir="$1"
  local old_version="$2"

  mkdir -p "${dir}/scripts" "${dir}/docs" "${dir}/guides"
  cp "${repo_root}/scripts/update-docs.sh" "${dir}/scripts/update-docs.sh"
  chmod +x "${dir}/scripts/update-docs.sh"

  (
    cd "$dir"
    git init --quiet
    git config user.name 'Docs Test'
    git config user.email 'docs-test@example.com'

    printf 'api docs\n' > api.md
    printf 'skill docs\n' > skill.md
    printf '{"openapi":"3.0.0"}\n' > openapi-v1.json
    printf '{"info":{"x-gameserver-version":"%s"}}\n' "$old_version" > openapi.json
    printf '{"version":"%s","ships":[],"skills":[],"recipes":[],"items":[],"modules":[],"facilities":[]}\n' \
      "$old_version" > catalog.json
    printf 'ws docs\n' > ws.md
    printf '{"current_version":"%s","page":1,"per_page":20,"releases":[]}\n' \
      "$old_version" > changelog.json
    printf 'local limits docs\n' > limits.md
    printf 'old docs crafting\n' > docs/crafting.md
    printf 'stale docs file\n' > docs/stale-doc.md
    printf 'old guide crafting\n' > guides/crafting.md
    printf 'stale guide file\n' > guides/stale-guide.md

    git add .
    git commit --quiet -m initial
  )
}

run_updater() {
  local fixture="$1"
  local bin_dir="$2"
  local upstream="$3"

  (
    cd "$fixture"
    UPSTREAM_WWW_DIR="$upstream" PATH="${bin_dir}:$PATH" bash scripts/update-docs.sh
  )
}

# Advance the updater's clock only when it sleeps, so a long Retry-After or
# spec interval stays deterministic without waiting out the wall clock.
install_virtual_clock() {
  local bin_dir="$1"
  local system_date
  system_date="$(command -v date)"
  local offset_file="${bin_dir}/clock-offset"

  cat > "${bin_dir}/date" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "+%s" && \$# -eq 1 ]]; then
  offset=0
  if [[ -f "$offset_file" ]]; then
    offset="\$(tr -d '[:space:]' < "$offset_file")"
  fi
  real="\$("$system_date" +%s)"
  printf '%s\n' "\$((real + offset))"
  exit 0
fi
exec "$system_date" "\$@"
EOF

  cat > "${bin_dir}/sleep" <<EOF
#!/usr/bin/env bash
seconds="\${1:-0}"
offset=0
if [[ -f "$offset_file" ]]; then
  offset="\$(tr -d '[:space:]' < "$offset_file")"
fi
printf '%s' "\$((offset + seconds))" > "$offset_file"
EOF
  chmod +x "${bin_dir}/date" "${bin_dir}/sleep"
}

assert_fetch_between() {
  local log="$1"
  local start="$2"
  local middle="$3"
  local end="$4"
  local message="$5"

  if ! awk -v start="$start" -v middle="$middle" -v end="$end" '
    index($0, start) && phase == 0 { phase = 1; next }
    index($0, middle) && phase == 1 { phase = 2; next }
    index($0, end) && phase == 2 { phase = 3; exit }
    END { exit (phase == 3) ? 0 : 1 }
  ' "$log"; then
    printf 'Request order:\n' >&2
    cat "$log" >&2
    fail "$message"
  fi
}

test_commits_when_gameserver_version_changes() {
  local fixture="${workdir}/changed"
  local bin_dir="${workdir}/bin-changed"
  local upstream="${workdir}/upstream-changed"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  make_upstream "$upstream" "${default_upstream_files[@]}"
  write_fake_curl "v2.0.0" "$bin_dir"

  run_updater "$fixture" "$bin_dir" "$upstream"

  assert_eq "v2.0.0" "$(git -C "$fixture" log -1 --format=%s)" \
    "commit subject should be the new gameserver version"
}

test_does_not_commit_when_gameserver_version_is_unchanged() {
  local fixture="${workdir}/unchanged"
  local bin_dir="${workdir}/bin-unchanged"
  local upstream="${workdir}/upstream-unchanged"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v2.0.0"
  make_upstream "$upstream" "${default_upstream_files[@]}"
  write_fake_curl "v2.0.0" "$bin_dir"

  run_updater "$fixture" "$bin_dir" "$upstream"

  assert_eq "initial" "$(git -C "$fixture" log -1 --format=%s)" \
    "script should not create a release commit without a version change"
}

test_syncs_both_managed_collections() {
  local fixture="${workdir}/collection-sync"
  local bin_dir="${workdir}/bin-collection-sync"
  local upstream="${workdir}/upstream-collection-sync"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  make_upstream "$upstream" "${default_upstream_files[@]}"
  write_fake_curl "v2.0.0" "$bin_dir"

  run_updater "$fixture" "$bin_dir" "$upstream"

  [[ -f "${fixture}/docs/new-doc.md" ]] || fail 'Discovered reference doc was not installed.'
  [[ -f "${fixture}/guides/new-guide.md" ]] || fail 'Discovered guide was not installed.'
  [[ ! -e "${fixture}/docs/stale-doc.md" ]] || fail 'Stale reference doc was not removed.'
  [[ ! -e "${fixture}/guides/stale-guide.md" ]] || fail 'Stale guide was not removed.'
  [[ -f "${fixture}/limits.md" ]] || fail 'Unmanaged root Markdown was removed.'
  [[ ! -e "${fixture}/docs/ignored.txt" ]] || fail 'Non-Markdown docs entry was installed.'
  [[ ! -e "${fixture}/guides/ignored.txt" ]] || fail 'Non-Markdown guide entry was installed.'
  [[ ! -e "${fixture}/docs/skip.md" && ! -e "${fixture}/docs/nested/skip.md" ]] || \
    fail 'Nested reference doc was installed.'
  [[ ! -e "${fixture}/guides/skip.md" && ! -e "${fixture}/guides/nested/skip.md" ]] || \
    fail 'Nested guide was installed.'
  if grep -q 'api.github.com' "${bin_dir}/requests.log"; then
    fail 'Collection discovery must not call the GitHub REST API.'
  fi

  grep -q '/public/docs/crafting.md' "${fixture}/docs/crafting.md" || \
    fail 'docs/crafting.md did not come from public/docs.'
  grep -q '/public/guides/crafting.md' "${fixture}/guides/crafting.md" || \
    fail 'guides/crafting.md did not come from public/guides.'

  git -C "$fixture" ls-files --error-unmatch docs/new-doc.md >/dev/null 2>&1 || \
    fail 'Discovered reference doc was not committed.'
  git -C "$fixture" ls-files --error-unmatch guides/new-guide.md >/dev/null 2>&1 || \
    fail 'Discovered guide was not committed.'
  if git -C "$fixture" ls-files --error-unmatch docs/stale-doc.md >/dev/null 2>&1; then
    fail 'Removed reference doc is still tracked.'
  fi
  if git -C "$fixture" ls-files --error-unmatch guides/stale-guide.md >/dev/null 2>&1; then
    fail 'Removed guide is still tracked.'
  fi
}

assert_updater_fails_without_tracked_changes() {
  local name="$1"
  local hard_failure_pattern="${2:-}"
  shift 2
  local fixture="${workdir}/${name}"
  local bin_dir="${workdir}/bin-${name}"
  local upstream="${workdir}/upstream-${name}"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  make_upstream "$upstream" "$@"
  write_fake_curl "v2.0.0" "$bin_dir" "" "$hard_failure_pattern"

  if run_updater "$fixture" "$bin_dir" "$upstream"; then
    fail "Updater unexpectedly succeeded for ${name}."
  fi

  assert_eq "" "$(git -C "$fixture" status --short)" \
    "failed updater should not modify tracked files for ${name}"
}

test_rejects_invalid_collection_inventories() {
  assert_updater_fails_without_tracked_changes \
    "empty-inventory" "" \
    docs/ignored.txt \
    guides/crafting.md guides/new-guide.md
  assert_updater_fails_without_tracked_changes \
    "missing-inventory" "" \
    guides/crafting.md guides/new-guide.md
  assert_updater_fails_without_tracked_changes \
    "unsafe-filename" "" \
    "docs/has space.md" \
    guides/crafting.md
}

test_failed_download_does_not_modify_tracked_docs() {
  assert_updater_fails_without_tracked_changes \
    "failed-download" "/public/guides/new-guide.md" \
    "${default_upstream_files[@]}"
}

test_retries_after_rate_limit() {
  local fixture="${workdir}/rate-limited"
  local bin_dir="${workdir}/bin-rate-limited"
  local upstream="${workdir}/upstream-rate-limited"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  make_upstream "$upstream" "${default_upstream_files[@]}"
  write_fake_curl "v2.0.0" "$bin_dir" "/api/openapi.json"

  CURL_RETRY_BASE_DELAY=0 run_updater "$fixture" "$bin_dir" "$upstream"

  assert_eq "v2.0.0" "$(git -C "$fixture" log -1 --format=%s)" \
    "script should retry past transient 429 responses"
}

test_fetches_other_docs_while_spec_is_rate_limited() {
  local fixture="${workdir}/spec-wait"
  local bin_dir="${workdir}/bin-spec-wait"
  local upstream="${workdir}/upstream-spec-wait"
  local spec_url="https://game.spacemolt.com/api/v2/openapi.json"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  make_upstream "$upstream" "${default_upstream_files[@]}"
  write_fake_curl "v2.0.0" "$bin_dir" "/api/v2/openapi.json" "" 30
  install_virtual_clock "$bin_dir"

  SPEC_MIN_INTERVAL=0 run_updater "$fixture" "$bin_dir" "$upstream"

  assert_fetch_between "${bin_dir}/requests.log" \
    "$spec_url" "/skill.md" "$spec_url" \
    "unrestricted docs should be fetched while a spec Retry-After is in effect"
  assert_eq "v2.0.0" "$(git -C "$fixture" log -1 --format=%s)" \
    "spec fetch should succeed after the overlapped wait"
}

test_spaces_shared_openapi_bucket_with_other_docs() {
  local fixture="${workdir}/spec-spacing"
  local bin_dir="${workdir}/bin-spec-spacing"
  local upstream="${workdir}/upstream-spec-spacing"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  make_upstream "$upstream" "${default_upstream_files[@]}"
  write_fake_curl "v2.0.0" "$bin_dir"
  install_virtual_clock "$bin_dir"

  SPEC_MIN_INTERVAL=30 run_updater "$fixture" "$bin_dir" "$upstream"

  assert_fetch_between "${bin_dir}/requests.log" \
    "https://game.spacemolt.com/api/openapi.json" \
    "/skill.md" \
    "https://game.spacemolt.com/api/v2/openapi.json" \
    "the second OpenAPI spec should wait while unrestricted docs are fetched"
  assert_eq "v2.0.0" "$(git -C "$fixture" log -1 --format=%s)" \
    "spaced spec fetches should still update the gameserver version"
}

test_repository_uses_clean_collection_paths() {
  local old_guides=(
    base-builder.md client-dev.md crafting.md drones.md explorer.md fuel.md
    miner.md pirate-hunter.md trader.md
  )

  for guide in "${old_guides[@]}"; do
    [[ ! -e "${repo_root}/${guide}" ]] || fail "Root compatibility file still exists: ${guide}"
    [[ -f "${repo_root}/guides/${guide}" ]] || fail "Migrated guide is missing: guides/${guide}"
  done
  [[ ! -e "${repo_root}/guides-manifest.txt" ]] || fail 'Obsolete guide manifest still exists.'
}

test_workflow_configures_git_identity_before_refreshing_docs() {
  local workflow="${repo_root}/.github/workflows/update-docs.yml"
  local config_line
  local refresh_line

  config_line="$(awk '/git config user.name/ { print NR; exit }' "$workflow")"
  refresh_line="$(awk '/run: bash scripts\/update-docs\.sh/ { print NR; exit }' "$workflow")"

  [[ -n "$config_line" && -n "$refresh_line" ]] || \
    fail "Could not find git identity config or updater invocation in ${workflow}."
  (( config_line < refresh_line )) || \
    fail 'Workflow must configure git identity before running the updater.'
}

test_workflow_pushes_script_created_commits() {
  local workflow="${repo_root}/.github/workflows/update-docs.yml"

  grep -q 'UPDATE_DOCS_BASE_SHA' "$workflow" || \
    fail 'Workflow must record the starting commit.'
  grep -q 'git rev-parse HEAD' "$workflow" || \
    fail 'Workflow must compare HEAD against the starting commit before pushing.'
}

test_commits_when_gameserver_version_changes
test_does_not_commit_when_gameserver_version_is_unchanged
test_syncs_both_managed_collections
test_rejects_invalid_collection_inventories
test_failed_download_does_not_modify_tracked_docs
test_retries_after_rate_limit
test_fetches_other_docs_while_spec_is_rate_limited
test_spaces_shared_openapi_bucket_with_other_docs
test_repository_uses_clean_collection_paths
test_workflow_configures_git_identity_before_refreshing_docs
test_workflow_pushes_script_created_commits

printf 'All update-docs tests passed.\n'
