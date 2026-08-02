#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
export INTER_FETCH_DELAY=0

valid_docs_response='[
  {"name":"crafting.md","type":"file"},
  {"name":"new-doc.md","type":"file"},
  {"name":"ignored.txt","type":"file"},
  {"name":"nested","type":"dir"}
]'
valid_guides_response='[
  {"name":"crafting.md","type":"file"},
  {"name":"new-guide.md","type":"file"},
  {"name":"ignored.txt","type":"file"},
  {"name":"nested","type":"dir"}
]'

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

write_fake_curl() {
  local next_version="$1"
  local bin_dir="$2"
  local docs_response="${3:-$valid_docs_response}"
  local guides_response="${4:-$valid_guides_response}"
  local rate_limit_pattern="${5:-}"
  local hard_failure_pattern="${6:-}"
  local state_file="${bin_dir}/.rate-limit-state"

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
    printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 0\r\n\r\n' > "\$header_file"
  fi
fi

if [[ "\$status" == "200" ]]; then
  case "\$url" in
    *"/contents/public/docs"*)
      printf '%s\n' '$docs_response' > "\$output"
      ;;
    *"/contents/public/guides"*)
      printf '%s\n' '$guides_response' > "\$output"
      ;;
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

  (
    cd "$fixture"
    PATH="${bin_dir}:$PATH" bash scripts/update-docs.sh
  )
}

test_commits_when_gameserver_version_changes() {
  local fixture="${workdir}/changed"
  local bin_dir="${workdir}/bin-changed"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  write_fake_curl "v2.0.0" "$bin_dir"

  run_updater "$fixture" "$bin_dir"

  assert_eq "v2.0.0" "$(git -C "$fixture" log -1 --format=%s)" \
    "commit subject should be the new gameserver version"
}

test_does_not_commit_when_gameserver_version_is_unchanged() {
  local fixture="${workdir}/unchanged"
  local bin_dir="${workdir}/bin-unchanged"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v2.0.0"
  write_fake_curl "v2.0.0" "$bin_dir"

  run_updater "$fixture" "$bin_dir"

  assert_eq "initial" "$(git -C "$fixture" log -1 --format=%s)" \
    "script should not create a release commit without a version change"
}

test_syncs_both_managed_collections() {
  local fixture="${workdir}/collection-sync"
  local bin_dir="${workdir}/bin-collection-sync"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  write_fake_curl "v2.0.0" "$bin_dir"

  run_updater "$fixture" "$bin_dir"

  [[ -f "${fixture}/docs/new-doc.md" ]] || fail 'Discovered reference doc was not installed.'
  [[ -f "${fixture}/guides/new-guide.md" ]] || fail 'Discovered guide was not installed.'
  [[ ! -e "${fixture}/docs/stale-doc.md" ]] || fail 'Stale reference doc was not removed.'
  [[ ! -e "${fixture}/guides/stale-guide.md" ]] || fail 'Stale guide was not removed.'
  [[ -f "${fixture}/limits.md" ]] || fail 'Unmanaged root Markdown was removed.'
  [[ ! -e "${fixture}/docs/ignored.txt" ]] || fail 'Non-Markdown docs entry was installed.'
  [[ ! -e "${fixture}/guides/ignored.txt" ]] || fail 'Non-Markdown guide entry was installed.'

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
  local docs_response="$2"
  local guides_response="$3"
  local hard_failure_pattern="${4:-}"
  local fixture="${workdir}/${name}"
  local bin_dir="${workdir}/bin-${name}"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  write_fake_curl "v2.0.0" "$bin_dir" "$docs_response" "$guides_response" "" \
    "$hard_failure_pattern"

  if run_updater "$fixture" "$bin_dir"; then
    fail "Updater unexpectedly succeeded for ${name}."
  fi

  assert_eq "" "$(git -C "$fixture" status --short)" \
    "failed updater should not modify tracked files for ${name}"
}

test_rejects_invalid_collection_inventories() {
  assert_updater_fails_without_tracked_changes \
    "empty-inventory" '[]' "$valid_guides_response"
  assert_updater_fails_without_tracked_changes \
    "malformed-inventory" "$valid_docs_response" '{"message":"bad response"}'
  assert_updater_fails_without_tracked_changes \
    "unsafe-filename" '[{"name":"../escape.md","type":"file"}]' "$valid_guides_response"
}

test_failed_download_does_not_modify_tracked_docs() {
  assert_updater_fails_without_tracked_changes \
    "failed-download" "$valid_docs_response" "$valid_guides_response" \
    "/public/guides/new-guide.md"
}

test_retries_after_rate_limit() {
  local fixture="${workdir}/rate-limited"
  local bin_dir="${workdir}/bin-rate-limited"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  write_fake_curl "v2.0.0" "$bin_dir" "$valid_docs_response" "$valid_guides_response" \
    "/api/openapi.json"

  CURL_RETRY_BASE_DELAY=0 run_updater "$fixture" "$bin_dir"

  assert_eq "v2.0.0" "$(git -C "$fixture" log -1 --format=%s)" \
    "script should retry past transient 429 responses"
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
test_repository_uses_clean_collection_paths
test_workflow_configures_git_identity_before_refreshing_docs
test_workflow_pushes_script_created_commits

printf 'All update-docs tests passed.\n'
