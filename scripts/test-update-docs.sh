#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

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
url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --output)
      output="\$2"
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
  *"/api/v2/openapi.json")
    printf '{"info":{"x-gameserver-version":"%s"}}\n' "$next_version" > "\$output"
    ;;
  *"/api/openapi.json")
    printf '{"openapi":"3.0.0"}\n' > "\$output"
    ;;
  *)
    printf 'refreshed from %s\n' "\$url" > "\$output"
    ;;
esac
EOF
  chmod +x "${bin_dir}/curl"
}

make_fixture_repo() {
  local dir="$1"
  local old_version="$2"

  mkdir -p "${dir}/scripts"
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
    printf 'base builder\n' > base-builder.md
    printf 'drones\n' > drones.md
    printf 'explorer\n' > explorer.md
    printf 'fuel\n' > fuel.md
    printf 'miner\n' > miner.md
    printf 'pirate hunter\n' > pirate-hunter.md
    printf 'trader\n' > trader.md

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

test_commits_when_gameserver_version_changes
test_does_not_commit_when_gameserver_version_is_unchanged

printf 'All update-docs tests passed.\n'
