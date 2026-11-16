# `gh-outside-access.sh`

Lists a GitHub organization's **outside collaborators** as CSV on stdout — one row per collaborator per repo — for access reviews. For each (collaborator, repo) pair it reports the collaborator's login, real name, MFA status, last activity on the org's own repos, the repo, and their permission on it.

Pair it with [`gh-members-access.sh`](gh-members-access.md), which covers owners and members; run both per org for the full access picture. Empty fields are written as a dash (`-`), so no cell is ever blank. A collaborator with access to several repos appears once per repo; their per-user fields (real name, MFA, last activity) are looked up once and reused.

**Columns:** `org,user,real_name,mfa_enabled,last_active,repo,permission`

* **`real_name`** — the user's GitHub profile name, or `-` if unset.
* **`mfa_enabled`** — `yes`/`no` when you run as an org **owner** (the only role that can read 2FA state); otherwise `unknown`.
* **`last_active`** — activity on **this org's repos only**: the most recent of the user's last commit and the last PR/issue they opened. Org-wide, not per-repo. A dash (`-`) means no such authored activity (see the note below).
* **`repo`** — the repository the collaborator has access to.
* **`permission`** — their role on that repo: `read`, `triage`, `write`, `maintain`, or `admin`.

> **Reading `last_active`:** it counts only *authored* work (commits, opened PRs/issues) on the org's own repos. It does **not** count review-only or comment-only activity, and commit search only matches commits whose author email is linked to the user's GitHub account. So a dash is a strong signal to investigate, not proof of zero activity — confirm a specific user (e.g. with a broad `involves:<login>` search) before revoking access.

**Requires:** `bash` and [`gh`](https://cli.github.com/), authenticated (see `gh auth status`) with at least the `read:org` scope. Owner access is needed for real `mfa_enabled` values. The script uses the GitHub search API (~30 requests/min) for `last_active`; it backs off and retries when rate-limited. It also scans every repo in the org (one API call per repo), so it is slower than the members report.

Output rows contain names and logins (PII). The repo's `.gitignore` ignores `*.csv` so reports are not committed by accident.

## Flags

This script takes one or more organization logins as positional arguments.

* **`ORG [ORG ...]`**: One or more GitHub organization logins to report on. At least one is required.
* **`-h` / `--help`**: Show help and exit.

## Usage Examples

**One org to a CSV file:**

```bash
./gh-outside-access.sh your-org > outside.csv
```

**Find admin-level outside collaborators (a common thing to review):**

```bash
./gh-outside-access.sh your-org | awk -F, '$7 == "admin"'
```

**Several orgs in one report:**

```bash
./gh-outside-access.sh your-org your-org-dev your-org-sandbox > outside.csv
```
