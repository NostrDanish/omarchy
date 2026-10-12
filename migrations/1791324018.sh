echo "Link the Hermes Desktop recovery skill for existing agents"

# The launcher fixes (5-value launch options, weak-NVIDIA software GPU) ship in
# the hermes-desktop package from omarchy-pkgs. This only makes the recovery
# skill discoverable for agents set up before it existed. Never replace a skill
# the user already has under this name.

omarchy-pkg-present hermes-desktop || exit 0

skill_src="${OMARCHY_PATH:-/usr/share/omarchy}/default/agents/skills/hermes-desktop-recovery"
[[ -d $skill_src ]] || exit 0

link_skill() {
  local dir=$1
  mkdir -p "$dir"
  [[ -e $dir/hermes-desktop-recovery || -L $dir/hermes-desktop-recovery ]] && return 0
  ln -s "$skill_src" "$dir/hermes-desktop-recovery"
}

link_skill "$HOME/.hermes/skills"
for profile in "$HOME"/.hermes/profiles/*/; do
  [[ -d $profile ]] && link_skill "${profile%/}/skills"
done
exit 0
