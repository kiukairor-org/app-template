#!/usr/bin/env bash
# Escalation gate for the reviewer, enforced in code BEFORE Claude runs.
# Runs from the default branch (workflow_run), never from PR code. Reads the PR via the API only.
# Env: GH_TOKEN, GH_REPO, PR, HEAD_SHA, AUTO_MERGE_ENABLED, MAX_CHANGED_LINES (default 400),
#      V1_MAX_CHANGED_LINES (default 2000, only for the first Build v1 PR of a new app, D69).
# Writes `escalate=true|false` and `reason=...` to $GITHUB_OUTPUT.
set -euo pipefail
MAX="${MAX_CHANGED_LINES:-400}"
reasons=()

pr_json=$(gh api "repos/$GH_REPO/pulls/$PR")
state=$(jq -r .state <<<"$pr_json")
head=$(jq -r .head.sha <<<"$pr_json")
labels=$(jq -r '[.labels[].name] | join(",")' <<<"$pr_json")
changed=$(jq -r '.additions + .deletions' <<<"$pr_json")

[ "$state" = open ] || { echo "escalate=skip" >> "$GITHUB_OUTPUT"; echo "PR not open"; exit 0; }
[ "$head" = "$HEAD_SHA" ] || { echo "escalate=skip" >> "$GITHUB_OUTPUT"; echo "stale CI run (head moved)"; exit 0; }

[ "${AUTO_MERGE_ENABLED:-}" = "true" ] || reasons+=("kill switch: org variable AUTO_MERGE_ENABLED is not 'true'")
case ",$labels," in *,hold,*) reasons+=("label 'hold' is set") ;; esac
case ",$labels," in *,fix-round-2,*) reasons+=("the PR has already used its 2 fix rounds") ;; esac
# Build v1 of a NEW app (D69): the size limit is V1_MAX instead of MAX when ALL of these hold:
#  - the PR carries `build-v1` (copied by claude.yml from the issue the catcher created with a new repo),
#  - it was opened by the author agent (kiu-homie-bot[bot]),
#  - the repo has never merged a PR (so only the first build of a fresh repo; a label added later is useless).
# Every other rule below (and above) is unchanged; the reviewer still reviews the whole diff.
limit_note=""
author=$(jq -r .user.login <<<"$pr_json")
if [[ ",$labels," == *,build-v1,* ]] && [ "$author" = "kiu-homie-bot[bot]" ]; then
  merged=$(gh api "repos/$GH_REPO/pulls?state=closed&per_page=100" --jq '[.[] | select(.merged_at != null)] | length')
  if [ "$merged" = 0 ]; then
    MAX="${V1_MAX_CHANGED_LINES:-2000}"
    limit_note=", Build v1 limit"
    echo "first Build v1 PR of a new app: size limit $MAX"
  else
    echo "build-v1 label ignored: the repo already has $merged merged PR(s)"
  fi
fi
[ "$changed" -le "$MAX" ] || reasons+=("diff is $changed changed lines (> $MAX$limit_note)")

# Sensitive paths: CI/workflows, ownership, agent instructions, secrets/RBAC/permissions in deploy/.
files=$(gh api --paginate "repos/$GH_REPO/pulls/$PR/files" --jq '.[].filename')
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    .github/*)                  reasons+=("changes CI/automation: $f") ;;
    CODEOWNERS|*/CODEOWNERS)    reasons+=("changes CODEOWNERS: $f") ;;
    CLAUDE.md|.claude/*)        reasons+=("changes agent instructions: $f") ;;
  esac
  if [[ "$f" == deploy/* ]] && grep -qiE '(secret|sealed|rbac|role|serviceaccount|networkpolic|psp|permission)' <<<"$f"; then
    reasons+=("changes secrets/RBAC/permissions in deploy/: $f")
  fi
done <<<"$files"
# Content check for deploy/: new or edited permission-bearing kinds.
patches=$(gh api --paginate "repos/$GH_REPO/pulls/$PR/files" --jq '.[] | select(.filename | startswith("deploy/")) | .patch // ""')
if grep -qE '^\+.*kind:[[:space:]]*(Secret|SealedSecret|Role|ClusterRole|RoleBinding|ClusterRoleBinding|ServiceAccount|NetworkPolicy)\b' <<<"$patches"; then
  reasons+=("adds/edits Secret, RBAC, ServiceAccount or NetworkPolicy objects in deploy/")
fi
if grep -qE '^\+.*(hostNetwork|privileged|hostPath|automountServiceAccountToken:[[:space:]]*true)' <<<"$patches"; then
  reasons+=("adds privileged pod settings in deploy/")
fi

if [ "${#reasons[@]}" -gt 0 ]; then
  {
    echo "escalate=true"
    echo "reason<<EOF"; printf -- '- %s\n' "${reasons[@]}"; echo "EOF"
  } >> "$GITHUB_OUTPUT"
  printf 'ESCALATE:\n'; printf -- '- %s\n' "${reasons[@]}"
else
  echo "escalate=false" >> "$GITHUB_OUTPUT"
  echo "no escalation rule applies"
fi
