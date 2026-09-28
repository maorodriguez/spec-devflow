#!/usr/bin/env bash
# spec-devflow commit-msg hook.
# Human mode (default): strip AI attribution lines so commits carry only the author's identity.
# Automated mode (DEVFLOW_AUTOMATED=1 or CI): leave the message untouched.
msg_file="$1"
case "${CI:-}" in true|1) exit 0;; esac
[ "${DEVFLOW_AUTOMATED:-0}" = 1 ] && exit 0
[ -n "${GITHUB_ACTIONS:-}" ] && exit 0
re='^(Co-[Aa]uthored-[Bb]y:.*(Claude|anthropic\.com|[Oo]pen[Cc]ode)|.*Generated with \[?(Claude Code|opencode|OpenCode)|Claude-Session:)'
tmp="$(mktemp)"
grep -Ev "$re" "$msg_file" > "$tmp" || true
# Drop trailing blank lines left behind.
awk 'NF{for(i=0;i<blank;i++)print ""; blank=0; print; next} {blank++}' "$tmp" > "$msg_file"
rm -f "$tmp"
exit 0
