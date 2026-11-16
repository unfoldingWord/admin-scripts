#!/usr/bin/env bash
# List org owners and members with identity and security details.
#
# Usage: ./gh-members-access.sh org1 [org2 ...] > members.csv
#
# Columns: org,user,real_name,role,mfa_enabled,last_active,status
#
# Field sources and caveats:
# - real_name   : /users/{login} -> .name (a dash "-" if the user set no name).
# - role        : owner (API role=admin) or member.
# - mfa_enabled : derived from the owner-only member filter `2fa_disabled`.
#                 Only reliable when you are an OWNER of the org. For non-owners
#                 the 2FA state cannot be read, so it is reported as "unknown".
# - last_active : activity on THIS org's repos only -- the most recent of the
#                 user's last commit in the org and the last PR/issue they
#                 opened in the org (GitHub commit/issue search). A dash "-" if
#                 they have never committed or opened a PR/issue here. Activity on
#                 repos outside this org does NOT count. Review-only or
#                 comment-only activity is not counted (only authored work).
# - status      : org membership state (active/pending).
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
Usage: gh-members-access.sh ORG [ORG ...]

List GitHub organization owners and members as CSV on stdout, one row per
member: org, user, real name, role, MFA status, last activity on the org's
own repos, and membership status.

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

echo "org,user,real_name,role,mfa_enabled,last_active,status"

for org in "${orgs[@]}"; do
  # Only org owners can read members' 2FA state.
  caller_role=$(gh api "/orgs/$org/memberships/$caller" --jq '.role' 2>/dev/null || echo "")
  declare -A mfa_off=()
  mfa_known=0
  if [[ $caller_role == admin ]]; then
    mfa_known=1
    while read -r u; do
      [[ -n $u ]] && mfa_off[$u]=1
    done < <(gh api --paginate "/orgs/$org/members?filter=2fa_disabled&per_page=100" --jq '.[].login')
  fi

  for role in admin member; do
    label=$([ "$role" = admin ] && echo owner || echo member)
    while read -r u; do
      [[ -z $u ]] && continue
      name=$(gh api "/users/$u" --jq '.name // ""' 2>/dev/null || echo "")
      last=$(org_last_active "$org" "$u")
      status=$(gh api "/orgs/$org/memberships/$u" --jq '.state // ""' 2>/dev/null || echo "")
      if [[ $mfa_known -eq 1 ]]; then
        mfa=$([[ -n ${mfa_off[$u]:-} ]] && echo no || echo yes)
      else
        mfa=unknown
      fi
      printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$org")" "$(csv_escape "$u")" "$(csv_escape "${name:--}")" \
        "$label" "$mfa" "${last:--}" "$(csv_escape "${status:--}")"
    done < <(gh api --paginate "/orgs/$org/members?role=$role&per_page=100" --jq '.[].login')
  done

  unset mfa_off
done
