#!/usr/bin/env bash
# install-hooks.sh — install the spec-devflow commit-msg hook (optional backstop).
#
# In human mode the hook removes AI attribution lines (Co-Authored-By: Claude..., "Generated with...",
# Claude-Session:) from any commit message, whichever tool wrote it. In automated mode it does nothing.
# It never overwrites an existing hook that is not ours; it prints instructions instead.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"

hp="$(git config --get core.hooksPath || true)"
if [ -n "$hp" ]; then
  die "core.hooksPath is set to '$hp' (husky/lefthook?). Add the logic from $SCRIPT_DIR/../assets/commit-msg-hook.sh to your hook manager instead."
fi
dir="$(git rev-parse --git-common-dir)/hooks"
target="$dir/commit-msg"
mkdir -p "$dir"
if [ -f "$target" ] && ! grep -q 'spec-devflow' "$target"; then
  die "$target already exists and is not ours. Merge $SCRIPT_DIR/../assets/commit-msg-hook.sh into it manually."
fi
cp "$SCRIPT_DIR/../assets/commit-msg-hook.sh" "$target"
chmod +x "$target"
echo "installed: $target (shared by all worktrees of this repository)"
