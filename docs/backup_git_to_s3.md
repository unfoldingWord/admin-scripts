# `backup_git_to_s3.sh`

Archives changed bare git repos to S3, one `tar.gz` per repo. This is the **per-repo restore layer** — EBS snapshots already cover full-volume recovery, so this exists to pull back a single repo without a whole-volume restore. It is **incremental**: only repos changed since the last successful run are re-tarred and re-uploaded.

Layout assumption — a Gitea/DCS tree of bare repos at uniform depth 2:

```
<source>/<owner>/<repo>.git   ->   s3://<bucket>/<prefix>/<owner>/<repo>.tar.gz
```

"Changed since last run" is decided by a **marker file's mtime**: any `*.git` directory newer than the marker is re-uploaded. On the first run (no marker) every repo is treated as changed. The marker is only advanced when *every* changed repo uploaded successfully, so a partial failure retries next run. To stay crash-safe it is written to a temp file and moved into place only at the very end.

**Requires:** `bash`, AWS CLI v2, `tar`, `find`, coreutils (`sha256sum` for the derived marker). Assumes credentials are available (e.g. an IAM instance role).

## The marker path

By default the marker lives in `--marker-dir` under a name **hashed from `(source, bucket, prefix)`** — the tuple that identifies a backup job. So distinct jobs on one host each get their own marker automatically, and pointing a job at a new bucket/prefix cleanly starts a full run (the new destination is empty, so a full upload is what you want). Pass `-m` / `--marker` to pin an explicit path and bypass the derivation.

## Flags

* **`-s` / `--source <dir>`**: Root of the bare-repo tree (repos at `<dir>/<owner>/<repo>.git`). Default: `/data/git/repositories`.
* **`-b` / `--bucket <name>`**: Destination S3 bucket name (no `s3://`). **Required.**
* **`-p` / `--prefix <prefix>`**: Key prefix under the bucket. Leading/trailing/duplicate slashes are normalized. Default: `repos`.
* **`-m` / `--marker <path>`**: Marker file recording the last successful run. Pins an explicit path; overrides the derived default.
* **`--marker-dir <dir>`**: Directory for the auto-derived marker (see above). Ignored if `--marker` is set. Default: `/var/lib/git-s3-backup`.
* **`-c` / `--storage-class <class>`**: S3 storage class. Default: `STANDARD_IA` (each tarball is well over the 128 KB IA minimum, so IA is safe and cheaper).
* **`-t` / `--tmp-dir <dir>`**: Directory for staging tarballs before upload. Default: `/tmp`.
* **`--dry-run`**: List what would be uploaded; make no changes and leave the marker untouched.
* **`-h` / `--help`**: Show help and exit.

Environment variables mirror the flags (`SOURCE_DIR`, `BUCKET`, `PREFIX`, `MARKER`, `MARKER_DIR`, `STORAGE_CLASS`, `TMP_DIR`); the flag wins if both are given.

## Usage Examples

**Back up the default tree to a bucket (all defaults except bucket):**

```bash
./backup_git_to_s3.sh -b uw-git-backups
```

**See what would upload without doing anything:**

```bash
./backup_git_to_s3.sh -b uw-git-backups --dry-run
```

**Nest the objects under a deeper prefix:**

```bash
./backup_git_to_s3.sh -b uw-git-backups -p dcs/repos
```

**Fully explicit invocation:**

```bash
./backup_git_to_s3.sh \
  --source /data/git/repositories \
  --bucket uw-git-backups \
  --prefix dcs/repos \
  --marker-dir /var/lib/git-s3-backup \
  --storage-class STANDARD_IA \
  --tmp-dir /tmp
```

## Notes

* **Idempotent**: running twice in a row uploads nothing the second time (nothing changed).
* **Per-repo error handling**: a failure on one repo is logged and the run continues; the marker is not advanced if any repo failed.
* **Logging**: timestamped lines to stdout, so the systemd journal captures them.
* **Consistency**: if a push lands mid-tar, git writes objects before refs, so the worst case is a few harmless orphan objects — never a dangling ref. This layer accepts that; EBS snapshots are the consistent source of truth.
