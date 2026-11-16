# `gh-members-access.sh`

Lists a GitHub organization's owners and members as CSV on stdout — one row per member — for access reviews. For each member it reports their login, real name, role, MFA status, last activity on the org's own repos, and membership status.

Pair it with [`gh-outside-access.sh`](gh-outside-access.md), which covers outside collaborators; run both per org for the full access picture. Empty fields are written as a dash (`-`), so no cell is ever blank.

**Columns:** `org,user,real_name,role,mfa_enabled,last_active,status`

* **`real_name`** — the user's GitHub profile name, or `-` if unset.
* **`role`** — `owner` or `member`.
* **`mfa_enabled`** — `yes`/`no`, but only when you run as an org **owner** (the only role that can read 2FA state); otherwise `unknown`. If the org enforces 2FA org-wide, every member is `yes`.
* **`last_active`** — activity on **this org's repos only**: the most recent of the user's last commit and the last PR/issue they opened. A dash (`-`) means no such authored activity (see the note below).
* **`status`** — org membership state (`active`/`pending`).

> **Reading `last_active`:** it counts only *authored* work (commits, opened PRs/issues) on the org's own repos. It does **not** count review-only or comment-only activity, and commit search only matches commits whose author email is linked to the user's GitHub account. So a dash is a strong signal to investigate, not proof of zero activity — confirm a specific user (e.g. with a broad `involves:<login>` search) before revoking access.

**Requires:** `bash` and [`gh`](https://cli.github.com/), authenticated (see `gh auth status`) with at least the `read:org` scope. Owner access is needed for real `mfa_enabled` values. The script uses the GitHub search API (~30 requests/min) for `last_active`; it backs off and retries when rate-limited, so large orgs run slowly but finish.

Output rows contain names and logins (PII). The repo's `.gitignore` ignores `*.csv` so reports are not committed by accident.

## Flags

This script takes one or more organization logins as positional arguments.

* **`ORG [ORG ...]`**: One or more GitHub organization logins to report on. At least one is required.
* **`-h` / `--help`**: Show help and exit.

## Usage Examples

**One org to a CSV file:**

```bash
./gh-members-access.sh your-org > members.csv
```

**Several orgs in one report:**

```bash
./gh-members-access.sh your-org your-org-dev your-org-sandbox > members.csv
```

**List members without MFA (meaningful when run as an org owner, and only where 2FA is not enforced org-wide):**

```bash
./gh-members-access.sh your-org | awk -F, '$5 == "no"'
```
