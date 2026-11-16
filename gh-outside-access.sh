#!/usr/bin/env bash
# List outside collaborators across an org's repos, with identity and access.
#
# Usage: ./gh-outside-access.sh org1 [org2 ...] > outside.csv
#
# Columns: org,user,real_name,mfa_enabled,last_active,repo,permission
#
# Field sources and caveats:
# - real_name   : /users/{login} -> .name (a dash "-" if the user set no name).
# - mfa_enabled : derived from the owner-only outside-collaborator filter
#                 `2fa_disabled`. Only reliable when you are an OWNER of the org;
#                 otherwise reported as "unknown".
# - last_active : activity on THIS org's repos only -- the most recent of the
#                 user's last commit in the org and the last PR/issue they
#                 opened in the org (GitHub commit/issue search). A dash "-" if
#                 they have never committed or opened a PR/issue here. Activity on
#                 repos outside this org does NOT count. Review-only or
#                 comment-only activity is not counted (only authored work).
#                 This value is org-wide, not per-repo.
# - repo        : repository the collaborator has access to.
# - permission  : the collaborator's role on that repo (role_name: read / triage
#                 / write / maintain / admin).
#
# A collaborator appears once per repo they can access.
#
# Note: last_active uses the GitHub search API (~30 requests/min). The script
# backs off and retries when rate-limited, so large orgs run slowly but finish.
#
# Requires: an authenticated `gh` (see `gh auth status`) with at least read:org.
set -euo pipefail

# Quote a value for CSV only when it contains a comma, quote, CR or LF.
csv_escape() {
  local s=${1-}
  if [[ $s == *[,\"$'\n'$'\r']* ]]; then
    printf '"%s"' "${s//\"/\"\"}"
  else
    printf '%s' "$s"
  fi
}

# Run a gh api call, retrying with backoff when GitHub rate-limits us
# (search endpoints allow only ~30 requests/minute). Echoes the --jq output.
gh_jq() {
  local path=$1 filter=$2 errf val attempt=0
  errf=$(mktemp)
  while :; do
    if val=$(gh api -H "Accept: application/vnd.github+json" "$path" --jq "$filter" 2>"$errf"); then
      rm -f "$errf"; printf '%s' "$val"; return 0
    fi
    if [[ $attempt -lt 6 ]] && grep -qiE 'rate limit|too quickly|secondary' "$errf"; then
      sleep $(( (attempt + 1) * 5 )); attempt=$((attempt + 1)); continue
    fi
    rm -f "$errf"; return 1
  done
}

# Most recent of (last commit, last authored PR/issue) by $2 within org $1,
# as YYYY-MM-DD. Blank when the user has neither in this org.
org_last_active() {
  local org=$1 u=$2 c i m
  c=$(gh_jq "/search/commits?q=org:$org+author:$u&sort=committer-date&order=desc&per_page=1" '.items[0].commit.committer.date // ""') || c=""
  i=$(gh_jq "/search/issues?q=org:$org+author:$u&sort=created&order=desc&per_page=1" '.items[0].created_at // ""') || i=""
  m=$c
  [[ $i > $m ]] && m=$i
  printf '%s' "${m:0:10}"
}

usage() {
  cat <<EOF
Usage: gh-outside-access.sh ORG [ORG ...]

List outside collaborators across a GitHub organization's repos as CSV on
stdout, one row per collaborator per repo: org, user, real name, MFA status,
last activity on the org's own repos, repo, and permission.

  -h, --help   Show this help and exit.

Notes:
  * Run as an org OWNER to read real MFA status; otherwise mfa_enabled is
    reported as "unknown". Empty fields are written as a dash ("-").
  * last_active counts only THIS org's repos (most recent of the user's last
    commit and the last PR/issue they opened). It uses the GitHub search API
    (~30 requests/min) and backs off when rate-limited, so large orgs run
    slowly but finish.

Requires: an authenticated gh (see 'gh auth status') with at least read:org.
EOF
}

orgs=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do orgs+=("$1"); shift; done; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) orgs+=("$1"); shift ;;
  esac
done
if [ ${#orgs[@]} -eq 0 ]; then
  echo "Error: at least one ORG is required." >&2
  usage >&2
  exit 2
fi

caller=$(gh api /user --jq '.login')

echo "org,user,real_name,mfa_enabled,last_active,repo,permission"

for org in "${orgs[@]}"; do
  # Only org owners can read collaborators' 2FA state.
  caller_role=$(gh api "/orgs/$org/memberships/$caller" --jq '.role' 2>/dev/null || echo "")
  declare -A mfa_off=()
  mfa_known=0
  if [[ $caller_role == admin ]]; then
    mfa_known=1
    while read -r u; do
      [[ -n $u ]] && mfa_off[$u]=1
    done < <(gh api --paginate "/orgs/$org/outside_collaborators?filter=2fa_disabled&per_page=100" --jq '.[].login')
  fi

  # Cache per-login lookups; collaborators recur across many repos.
  declare -A name_cache=()
  declare -A last_cache=()

  while read -r repo; do
    [[ -z $repo ]] && continue
    while IFS=$'\t' read -r u perm; do
      [[ -z $u ]] && continue
      if [[ -z ${name_cache[$u]+x} ]]; then
        name_cache[$u]=$(gh api "/users/$u" --jq '.name // ""' 2>/dev/null || echo "")
        last_cache[$u]=$(org_last_active "$org" "$u")
      fi
      if [[ $mfa_known -eq 1 ]]; then
        mfa=$([[ -n ${mfa_off[$u]:-} ]] && echo no || echo yes)
      else
        mfa=unknown
      fi
      printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$org")" "$(csv_escape "$u")" "$(csv_escape "${name_cache[$u]:--}")" \
        "$mfa" "${last_cache[$u]:--}" "$(csv_escape "$repo")" "$(csv_escape "${perm:--}")"
    done < <(gh api --paginate "/repos/$org/$repo/collaborators?affiliation=outside&per_page=100" --jq '.[] | [.login, .role_name] | @tsv')
  done < <(gh api --paginate "/orgs/$org/repos?per_page=100" --jq '.[].name')

  unset mfa_off name_cache last_cache
done
