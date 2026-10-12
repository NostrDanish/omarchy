#!/bin/bash

set -euo pipefail

# Exercises migrations/1791324018.sh: links the recovery skill for existing
# agents without replacing user skills, writes no launcher, and leaves
# machines without hermes-desktop alone. Launcher fixes live in omarchy-pkgs.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1791324018.sh"
[[ -f $migration ]] || fail "Hermes desktop launcher recovery migration exists"
[[ $(stat -c %a "$migration") == "644" ]] || fail "migration is a plain 0644 file"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin" "$test_tmp/omarchy/default/agents/skills/hermes-desktop-recovery"
printf '# recovery skill\n' >"$test_tmp/omarchy/default/agents/skills/hermes-desktop-recovery/SKILL.md"

cat >"$mock_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash
[[ $1 == "hermes-desktop" && ${OMARCHY_TEST_DESKTOP_INSTALLED:-0} == 1 ]]
SH
chmod +x "$mock_bin/omarchy-pkg-present"

run_migration() {
  OMARCHY_TEST_DESKTOP_INSTALLED="${OMARCHY_TEST_DESKTOP_INSTALLED:-1}" \
    PATH="$mock_bin:$PATH" \
    HOME="$test_tmp/home" \
    OMARCHY_PATH="$test_tmp/omarchy" \
    bash -euo pipefail "$migration" >/dev/null
}

skill_src="$test_tmp/omarchy/default/agents/skills/hermes-desktop-recovery"
skill_link="$test_tmp/home/.hermes/skills/hermes-desktop-recovery"
profile_link="$test_tmp/home/.hermes/profiles/work/skills/hermes-desktop-recovery"

mkdir -p "$test_tmp/home"
OMARCHY_TEST_DESKTOP_INSTALLED=0 run_migration || fail "migration exits clean without Hermes Desktop"
[[ ! -e $skill_link ]] || fail "skill is not linked without Hermes Desktop"
pass "migration only applies where Omarchy installed Hermes Desktop"

mkdir -p "$test_tmp/home/.hermes/profiles/work"
run_migration || fail "migration exits clean with Hermes Desktop installed"
[[ -L $skill_link && $(readlink "$skill_link") == "$skill_src" ]] || fail "skill linked into ~/.hermes/skills"
[[ -L $profile_link && $(readlink "$profile_link") == "$skill_src" ]] || fail "skill linked into existing profiles"
[[ ! -e $test_tmp/home/.config/omarchy/bin/hermes-desktop ]] || fail "migration writes no user launcher"
run_migration || fail "migration is idempotent"
pass "migration links the recovery skill for existing agents"

rm -f "$skill_link"
ln -s /somewhere/custom "$skill_link"
run_migration || fail "migration exits clean with a custom skill link"
[[ $(readlink "$skill_link") == /somewhere/custom ]] || fail "custom skill link is preserved"
pass "migration preserves a user's own skill link"

! grep -q 'config/omarchy/bin' "$ROOT/bin/omarchy-install-ai-hermes" ||
  fail "omarchy-install-ai-hermes does not depend on ~/.config/omarchy/bin"
pass "install-ai-hermes launches the packaged launcher"

skill_dir="$ROOT/default/agents/skills/hermes-desktop-recovery"
for ref in fast-fix.md desktop-recovery-checklist.md; do
  [[ -f $skill_dir/references/$ref ]] || fail "skill reference $ref exists"
done
pass "hermes-desktop-recovery skill ships all referenced docs"
