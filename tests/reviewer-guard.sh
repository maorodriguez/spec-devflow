#!/usr/bin/env bash
# tests/reviewer-guard.sh — regression tests for scripts/reviewer-bash-guard.sh.
#
#   tests/reviewer-guard.sh
#
# Pipes hook payloads ({"tool_input":{"command":"..."}}) into the guard and checks its exit code:
# 0 for the commands in ALLOW, 2 for those in DENY. Every DENY entry is a bypass found in review
# (or a close variant), so add a case here whenever the guard changes. It runs twice: with jq, and
# with a PATH that has no jq so the sed/bash JSON fallback is exercised. Exit status 1 on any failure.
# Needs bash, git, sed, tr, head, dirname and cat; jq only for the first pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/reviewer-bash-guard.sh"
cd "$ROOT"

NOJQ="$(mktemp -d)"; trap 'rm -rf "$NOJQ"' EXIT
for b in cat sed head tr git dirname; do ln -s "$(command -v "$b")" "$NOJQ/$b"; done

# JSON-encode a command line without depending on python or jq.
mk() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; printf '{"tool_input":{"command":"%s"}}' "$s"; }

ALLOW=('git status' 'git log --oneline -5' 'git diff HEAD~1 HEAD' 'git log --grep commit' 'git branch -a' 'git branch --show-current' 'git show HEAD:foo | grep commit' 'ls && git status' 'git log --format="%h %s" -3' 'git rev-parse HEAD' 'git ls-files' '.claude/skills/spec-devflow/scripts/review.sh context' 'bash .claude/skills/spec-devflow/scripts/review.sh status' './.claude/skills/spec-devflow/scripts/review.sh context --since abc123' 'bash .claude/skills/spec-devflow/scripts/review.sh context --base main' '/home/u/.claude/skills/spec-devflow/scripts/review.sh status' "$ROOT/scripts/review.sh context" "bash $ROOT/scripts/review.sh status" 'echo hi' 'grep -rn "git commit" docs' 'grep -rn "a|b" src' 'grep -E "(foo|bar)" f' 'git diff --stat -- config/app.yml' 'openspec validate --all' 'npm test' 'npm run lint' 'shellcheck scripts/review.sh' 'git blame -L 1,5 f' 'jq . package.json' 'gh pr view 12' 'git log --format="a\"b" -1' "echo 'it;s|fine'" 'go test ./...' 'go test -v ./pkg/...' 'cargo test --workspace' 'make test' 'pytest -q tests/x.py' "git log -- 'src/*.js'" 'git grep -n "foo bar" -- scripts' 'git grep -in -e TODO' 'git log 2>&1 | head -5' 'git status >/dev/null 2>&1' 'cat f | wc -l' 'ls -la /tmp' 'git log --oneline -n 5 --author="A B"' 'git grep -n foo' 'git log --oneline -n1' 'echo "cost $"' 'echo $f' 'echo "$HOME"' 'grep -n "foo$" file' 'grep -E "^x$" f' 'grep foo$ file' 'echo hi # a comment' $'ls # it\'s fine\ngit status' 'git log -GOpen' 'git log -SfooOK' 'git grep -o pattern' 'git log -- OpenFile' 'if git diff --quiet; then echo clean; fi' 'echo hi 2>&1 2>&1' 'ls 2>&1|head -3' 'echo $?' 'echo "a $1 b"' 'gh pr diff 1 --name-only' 'gh pr view 1 --json title')
DENY=('git commit -m x' 'git -c user.name=a commit' '/usr/bin/git commit' '(git commit)' 'echo $(git commit)' 'cd x && git add .' 'sh -c "git commit -m x"' 'git config alias.ci commit && git ci -m a' 'git -c Alias.ci=commit ci -m a' 'git --config-env=alias.x=V x' 'git co""mmit -m a' 'git c\ommit' "git \$'commit'" $'git \\\ncommit -m a' $'cd x\ngit commit -m a' 'git $SUB' 'git bisect start' 'git notes add' 'git update-index --add f' 'git submodule update' 'git filter-branch' 'g""it commit' '\git commit' 'env git reset --hard' 'git config user.name x' 'git "commit"' 'git update-ref -d refs/heads/x' 'git branch -f x HEAD' 'git branch newb' 'git worktree add /x' 'xargs git commit'
 'git -c include.path=/tmp/x.cfg ci -m x' 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit git ci -m x' 'git -C "$(pwd)" commit -m x' 'git `echo commit` -m x' 'git commit>/dev/null -m x' 'git apply<p.diff' 'git --attr-source HEAD commit -m x' $'echo foo\\\\\ngit commit -m x' 'git ci -m x' 'git st' 'git diff --output=out.txt' 'git grep -O less foo' 'echo x > file' 'echo x >> file' 'cat f > /tmp/x' 'tee f' 'rm -rf x' 'mv a b' 'cp a b' 'touch x' 'mkdir x' 'python3 -c "print(1)"' 'node -e 1' 'awk "BEGIN{system(\"ls\")}"' 'curl http://x' 'eval "git commit"' 'bash -c "git commit"' 'bash scripts/evil.sh' './scripts/commit.sh' 'bash .claude/skills/spec-devflow/scripts/review.sh record r.md' 'bash .claude/skills/spec-devflow/scripts/review.sh publish 1 --confirm' 'npm run build' 'npm install' 'gh pr comment 1 -b x' 'gh pr merge 1' 'gh api /x' 'openspec archive x' 'echo "unterminated' 'diff <(git show a) b' 'git log | tee f' 'X=1 git log' 'command git commit' 'git stash' 'git stash pop' 'git tag v1' 'git remote add x y' 'git fetch' 'git clean -fd' 'git checkout -- .' 'ls; git commit' 'ls && rm x' 'ls || rm x' 'ls | xargs rm' 'ls & rm x' 'wc -l < /dev/null' 'echo "a$(git commit)b"' 'echo "a`git commit`b"' 'git log --format="x" ; git commit'
 'bash -n +n -c "echo EXECUTED"' 'sh -n f' 'bash -n f' 'git grep --open=echo -l x' 'git grep -Orm -l x' 'git grep --op=echo x' 'git log --out=f' 'git diff --outp=f' 'git log --ext-diff' 'git log --ext=x' 'git log --out""put=f' 'sort -ro out f' 'sort f' 'sed -nibak 1p f' 'sed -n 1p f' 'find . -name x' 'find . {-delete,}' 'find /x ${X:--print}' 'rg foo' 'rg --pretty foo' 'date' 'file f' 'uniq a b' 'sort --compress-program=cat' 'make test -f -' 'make test -t' 'make test extra' 'go test -exec cat ./...' 'go vet -vettool=x ./...' 'pytest --basetemp=out' 'pytest -p x' 'echo hi >&1foo' 'echo hi >&1/x/y' 'echo hi >&-name' 'ls >/dev/nullx' 'git log $X' 'git log *' 'git log {a,b}' 'git log -- src/*.js' 'npm test -- --foo' 'npm run lint -- x' 'cargo test -- --nocapture' 'git commit -am x scripts/review.sh context' 'bash scripts/review.sh context $X' 'bash scripts/review.sh context *'
 'printf -v PATH %s /x; git status' 'printf hi' "[[ -v 'a[\$(touch M)]' ]]" "[[ 'a[\$(touch M)]' -eq 0 ]]" "test -v 'a[\$(touch M)]'" '[ -d x ]' 'test -f x' 'git grep -iOecho -l hello' 'git grep -nO less x' 'git grep -Oecho x' 'git grep -iO./p.sh hello' 'git -C /some/repo log' 'cd /x' 'cd /x && git log' 'cd /x && scripts/review.sh context' 'scripts/review.sh context' 'bash scripts/review.sh context' 'bash /tmp/evil/scripts/review.sh context' '/tmp/x/review.sh status' './review.sh status' 'gh pr view 1 --web' $'echo hi # it\'s\ntouch PWNED # \'' $'ls # "\nrm x # "' 'diff3>&1 a b c' 'diff3 >&1 a b c' 'diff3 --diff-program=/bin/echo a b c' 'for f in a b; do echo $f; done' 'for HOME in /tmp; do git status; done' 'for PATH in /x; do git status; done' 'bash .claude/skills/spec-devflow/../../../evil/review.sh context' 'bash /x/.claude/skills/spec-devflow/scripts/../../../../tmp/review.sh context' 'bash /x/*/.claude/skills/spec-devflow/scripts/review.sh context' 'echo hi>&1x' 'gh pr view 1 -w' 'gh pr view 1 --web=true' 'gh pr view 1 -cw' "echo \${x:='a[\$(touch M)]'} \$[x]" "for i in \${y:='a[\$(touch M)]'} \$[y]; do :; done" 'echo ${x}' 'echo "${x:-y}"' 'echo $[1]' 'echo $((1))' '((echo))' 'for ((i=0;i<1;i++)); do :; done' "echo \$'x'" 'echo $(( x ))' "echo \$[ a[\$(touch M)] ]")
run() { # $1 = jq|nojq, $2 = payload -> exit code of the guard
  if [ "$1" = jq ]; then printf '%s' "$2" | bash "$GUARD" >/dev/null 2>&1
  else printf '%s' "$2" | PATH="$NOJQ" /bin/bash "$GUARD" >/dev/null 2>&1; fi
  echo $?
}

fail=0
for mode in jq nojq; do
  if [ "$mode" = jq ] && ! command -v jq >/dev/null 2>&1; then echo "[jq] skipped (jq not installed)"; continue; fi
  bad=0
  for c in "${ALLOW[@]}"; do r="$(run $mode "$(mk "$c")")"; [ "$r" = 0 ] || { echo "[$mode] FALSE BLOCK($r): $c"; bad=1; }; done
  for c in "${DENY[@]}";  do r="$(run $mode "$(mk "$c")")"; [ "$r" = 2 ] || { echo "[$mode] MISSED($r): $c"; bad=1; }; done
  echo "[$mode] $([ $bad = 0 ] && echo ok || echo FAILED) (allow=${#ALLOW[@]} deny=${#DENY[@]})"
  [ $bad = 0 ] || fail=1
done

# Unparseable payloads must be blocked (fail closed), an empty tool_input must be allowed.
for mode in jq nojq; do
  [ "$mode" = nojq ] || command -v jq >/dev/null 2>&1 || continue
  r="$(run $mode 'not json')"; [ "$r" = 2 ] || { echo "[$mode] unparseable payload not blocked ($r)"; fail=1; }
done

# DEVFLOW_TEST_CMD: read from the MAIN worktree's conf only, matched against the whole command line.
tmp="$(mktemp -d)"; trap 'rm -rf "$NOJQ" "$tmp"' EXIT
git -C "$tmp" init -q && git -C "$tmp" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo 'DEVFLOW_TEST_CMD="npm ci && npm test 2>/dev/null"' > "$tmp/.spec-devflow.conf"
git -C "$tmp" worktree add -q --detach "$tmp-wt"
echo 'DEVFLOW_TEST_CMD=git commit' > "$tmp-wt/.spec-devflow.conf"      # a change tries to redefine it
check_test_cmd() { # $1 = expected exit code, $2 = command
  local r; r="$(cd "$tmp-wt" && printf '%s' "$(mk "$2")" | bash "$GUARD" >/dev/null 2>&1; echo $?)"
  [ "$r" = "$1" ] || { echo "[test-cmd] expected $1 got $r: $2"; fail=1; }
}
check_test_cmd 0 'npm ci && npm test 2>/dev/null'
check_test_cmd 2 'npm ci && npm test'
check_test_cmd 2 'npm ci && npm test 2>/dev/null && git commit -m x'
check_test_cmd 2 'git commit -m x'
git -C "$tmp" worktree remove --force "$tmp-wt" 2>/dev/null; rm -rf "$tmp-wt"
echo "[test-cmd] done"

[ "$fail" = 0 ] && echo "all guard tests passed" || { echo "GUARD TESTS FAILED"; exit 1; }
