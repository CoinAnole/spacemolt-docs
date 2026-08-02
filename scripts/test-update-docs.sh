#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
export INTER_FETCH_DELAY=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'Assertion failed: %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

write_fake_curl() {
  local next_version="$1"
  local bin_dir="$2"

  cat > "${bin_dir}/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail

output=""
write_out=""
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

case "\$url" in
  *"/repos/SpaceMolt/www/contents/public/guides"*)
    printf '%s\n' '[
      {"name":"base-builder.md","type":"file"},
      {"name":"client-dev.md","type":"file"},
      {"name":"crafting.md","type":"file"},
      {"name":"drones.md","type":"file"},
      {"name":"explorer.md","type":"file"},
      {"name":"fuel.md","type":"file"},
      {"name":"miner.md","type":"file"},
      {"name":"new-guide.md","type":"file"},
      {"name":"pirate-hunter.md","type":"file"},
      {"name":"trader.md","type":"file"},
      {"name":"ignored.txt","type":"file"},
      {"name":"nested","type":"dir"}
    ]' > "\$output"
    ;;
  *"/api/v2/openapi.json")
    printf '{"info":{"x-gameserver-version":"%s"}}\n' "$next_version" > "\$output"
    ;;
  *"/api/openapi.json")
    printf '{"openapi":"3.0.0"}\n' > "\$output"
    ;;
  *"/api/catalog.json")
    printf '{"version":"%s","ships":[],"skills":[],"recipes":[],"items":[],"modules":[],"facilities":[]}\n' "$next_version" > "\$output"
    ;;
  *)
    printf 'refreshed from %s\n' "\$url" > "\$output"
    ;;
esac

if [[ "\$write_out" == '%{http_code}' ]]; then
  printf '200'
fi
EOF
  chmod +x "${bin_dir}/curl"
}

make_fixture_repo() {
  local dir="$1"
  local old_version="$2"

  mkdir -p "${dir}/scripts"
  cp "${repo_root}/scripts/update-docs.sh" "${dir}/scripts/update-docs.sh"
  cp "${repo_root}/guides-manifest.txt" "${dir}/guides-manifest.txt"
  printf 'removed-guide.md\n' >> "${dir}/guides-manifest.txt"
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
    printf '{"version":"%s","ships":[],"skills":[],"recipes":[],"items":[],"modules":[],"facilities":[]}\n' "$old_version" > catalog.json
    printf 'base builder\n' > base-builder.md
    printf 'client dev\n' > client-dev.md
    printf 'crafting\n' > crafting.md
    printf 'drones\n' > drones.md
    printf 'explorer\n' > explorer.md
    printf 'fuel\n' > fuel.md
    printf 'local limits docs\n' > limits.md
    printf 'miner\n' > miner.md
    printf 'pirate hunter\n' > pirate-hunter.md
    printf 'removed guide\n' > removed-guide.md
    printf 'trader\n' > trader.md
    printf 'ws docs\n' > ws.md
    printf '{"current_version":"%s","page":1,"per_page":20,"releases":[]}\n' "$old_version" > changelog.json

    git add .
    git commit --quiet -m initial
  )
}

test_commits_when_gameserver_version_changes() {
  local fixture="${workdir}/changed"
  local bin_dir="${workdir}/bin-changed"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  write_fake_curl "v2.0.0" "$bin_dir"

  (
    cd "$fixture"
    PATH="${bin_dir}:$PATH" bash scripts/update-docs.sh
  )

  local subject
  subject="$(git -C "$fixture" log -1 --format=%s)"
  assert_eq "v2.0.0" "$subject" "commit subject should be the new gameserver version"
}

test_does_not_commit_when_gameserver_version_is_unchanged() {
  local fixture="${workdir}/unchanged"
  local bin_dir="${workdir}/bin-unchanged"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v2.0.0"
  write_fake_curl "v2.0.0" "$bin_dir"

  (
    cd "$fixture"
    PATH="${bin_dir}:$PATH" bash scripts/update-docs.sh
  )

  local subject
  subject="$(git -C "$fixture" log -1 --format=%s)"
  assert_eq "initial" "$subject" "script should not create a release commit without a version change"
}

test_discovers_added_guides_and_removes_only_manifested_guides() {
  local fixture="${workdir}/guide-sync"
  local bin_dir="${workdir}/bin-guide-sync"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  write_fake_curl "v2.0.0" "$bin_dir"

  (
    cd "$fixture"
    PATH="${bin_dir}:$PATH" bash scripts/update-docs.sh
  )

  if [[ ! -f "${fixture}/new-guide.md" ]]; then
    printf 'Dynamically discovered guide was not installed.\n' >&2
    exit 1
  fi
  if [[ -e "${fixture}/removed-guide.md" ]]; then
    printf 'Guide absent from the upstream listing was not removed.\n' >&2
    exit 1
  fi
  if [[ ! -f "${fixture}/limits.md" ]]; then
    printf 'Local Markdown file outside the guide manifest was removed.\n' >&2
    exit 1
  fi
  if ! git -C "$fixture" ls-files --error-unmatch new-guide.md >/dev/null 2>&1; then
    printf 'Dynamically discovered guide was not committed.\n' >&2
    exit 1
  fi
  if git -C "$fixture" ls-files --error-unmatch removed-guide.md >/dev/null 2>&1; then
    printf 'Removed upstream guide is still tracked.\n' >&2
    exit 1
  fi
  if grep -q '^removed-guide\.md$' "${fixture}/guides-manifest.txt"; then
    printf 'Removed guide remains in the generated manifest.\n' >&2
    exit 1
  fi
  if ! grep -q '^new-guide\.md$' "${fixture}/guides-manifest.txt"; then
    printf 'New guide is missing from the generated manifest.\n' >&2
    exit 1
  fi
}

test_workflow_configures_git_identity_before_refreshing_docs() {
  local workflow="${repo_root}/.github/workflows/update-docs.yml"
  local config_line
  local refresh_line

  config_line="$(awk '/git config user.name/ { print NR; exit }' "$workflow")"
  refresh_line="$(awk '/run: bash scripts\/update-docs\.sh/ { print NR; exit }' "$workflow")"

  if [[ -z "$config_line" || -z "$refresh_line" ]]; then
    printf 'Could not find git identity config or update-docs run line in %s\n' "$workflow" >&2
    exit 1
  fi

  if (( config_line >= refresh_line )); then
    printf 'Workflow must configure git identity before running scripts/update-docs.sh.\n' >&2
    exit 1
  fi
}

write_rate_limited_curl() {
  local next_version="$1"
  local fail_pattern="$2"
  local bin_dir="$3"
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
case "\$url" in
  *"/repos/SpaceMolt/www/contents/public/guides"*)
    printf '%s\n' '[
      {"name":"base-builder.md","type":"file"},
      {"name":"client-dev.md","type":"file"},
      {"name":"crafting.md","type":"file"},
      {"name":"drones.md","type":"file"},
      {"name":"explorer.md","type":"file"},
      {"name":"fuel.md","type":"file"},
      {"name":"miner.md","type":"file"},
      {"name":"new-guide.md","type":"file"},
      {"name":"pirate-hunter.md","type":"file"},
      {"name":"trader.md","type":"file"}
    ]' > "\$output"
    ;;
  *"$fail_pattern"*)
    count=0
    if [[ -f "$state_file" ]]; then
      count="\$(<"$state_file")"
    fi
    count=\$((count + 1))
    printf '%s' "\$count" > "$state_file"
    if (( count == 1 )); then
      status="429"
      printf '{"error":"rate_limited"}\n' > "\$output"
      if [[ -n "\$header_file" ]]; then
        printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 0\r\n\r\n' > "\$header_file"
      fi
    else
      printf '{"openapi":"3.0.0"}\n' > "\$output"
    fi
    ;;
  *"/api/v2/openapi.json")
    printf '{"info":{"x-gameserver-version":"%s"}}\n' "$next_version" > "\$output"
    ;;
  *"/api/openapi.json")
    printf '{"openapi":"3.0.0"}\n' > "\$output"
    ;;
  *"/api/catalog.json")
    printf '{"version":"%s","ships":[],"skills":[],"recipes":[],"items":[],"modules":[],"facilities":[]}\n' "$next_version" > "\$output"
    ;;
  *)
    printf 'refreshed from %s\n' "\$url" > "\$output"
    ;;
esac

if [[ "\$write_out" == '%{http_code}' ]]; then
  printf '%s' "\$status"
fi
EOF
  chmod +x "${bin_dir}/curl"
}

test_retries_after_rate_limit() {
  local fixture="${workdir}/rate-limited"
  local bin_dir="${workdir}/bin-rate-limited"
  mkdir -p "$bin_dir"
  make_fixture_repo "$fixture" "v1.0.0"
  write_rate_limited_curl "v2.0.0" "/api/openapi.json" "$bin_dir"

  # The fake curl always succeeds on retry, so keep retries fast in tests.
  (
    cd "$fixture"
    CURL_RETRY_BASE_DELAY=0 PATH="${bin_dir}:$PATH" bash scripts/update-docs.sh
  )

  local subject
  subject="$(git -C "$fixture" log -1 --format=%s)"
  assert_eq "v2.0.0" "$subject" "script should retry past transient 429 responses"
}

test_workflow_pushes_script_created_commits() {
  local workflow="${repo_root}/.github/workflows/update-docs.yml"

  if ! grep -q 'UPDATE_DOCS_BASE_SHA' "$workflow"; then
    printf 'Workflow must record the starting commit so script-created commits can be pushed.\n' >&2
    exit 1
  fi

  if ! grep -q 'git rev-parse HEAD' "$workflow"; then
    printf 'Workflow must compare the current commit against the starting commit before deciding there is nothing to push.\n' >&2
    exit 1
  fi
}

test_commits_when_gameserver_version_changes
test_does_not_commit_when_gameserver_version_is_unchanged
test_discovers_added_guides_and_removes_only_manifested_guides
test_retries_after_rate_limit
test_workflow_configures_git_identity_before_refreshing_docs
test_workflow_pushes_script_created_commits

printf 'All update-docs tests passed.\n'
