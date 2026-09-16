#!/usr/bin/env bash
#
# backup_git_to_s3.sh
# Archive changed bare git repos to S3, one tar.gz per repo.
#
# This is the per-repo restore layer: EBS snapshots already cover full-volume
# recovery, so this exists to pull back a single repo without a whole-volume
# restore. It is incremental — only repos changed since the last successful run
# are re-tarred and re-uploaded.
#
# Layout assumption: a Gitea/DCS tree of bare repos at uniform depth 2,
#   <source>/<owner>/<repo>.git
# uploaded to
#   s3://<bucket>/<prefix>/<owner>/<repo>.tar.gz
#
# "Changed since last run" is decided by a marker file's mtime: any *.git
# directory newer than the marker is re-uploaded. On the first run (no marker)
# every repo is treated as changed. The marker is only advanced when every
# changed repo uploaded successfully, so a partial failure retries next run.
#
# Auth: assumes the AWS CLI picks up credentials from an attached IAM instance
# role (no keys on disk).
#
# Usage:
#   ./backup_git_to_s3.sh                              # use defaults
#   ./backup_git_to_s3.sh -s /data/git/repositories -b my-bucket
#   ./backup_git_to_s3.sh --dry-run                    # show what would upload
#
# Requires: bash, aws cli v2, tar, find, coreutils.
#
# Consistency note: if a push lands mid-tar, git writes objects before refs, so
# the worst case captured here is a few harmless orphan objects — never a
# dangling ref. This layer accepts that; EBS snapshots are the consistent
# source of truth. We do not lock repos or quiesce Gitea.

set -euo pipefail

# --- config (defaults) ----------------------------------------------------

# Root of the bare-repo tree. Repos are expected at <SOURCE_DIR>/<owner>/<repo>.git.
SOURCE_DIR="${SOURCE_DIR:-/data/git/repositories}"

# Destination S3 bucket (name only, no s3:// prefix) and key prefix under it.
BUCKET="${BUCKET:-}"
PREFIX="${PREFIX:-repos}"

# Marker file whose mtime records the last successful run. Its parent dir must
# be writable — we stage a temp marker beside it and move it into place at the
# very end so a crash mid-run never advances the timestamp.
#
# By default the marker lives in MARKER_DIR under a name derived from a hash of
# (source, bucket, prefix): the tuple that identifies this backup job. That way
# distinct jobs on one host each get their own marker automatically, and pointing
# the same job at a new bucket/prefix starts a clean full run (the new
# destination is empty, so a full upload is what you want) — while re-running the
# same job keeps reusing its marker. Set MARKER (or --marker) to pin an explicit
# path and bypass the derivation entirely.
MARKER_DIR="${MARKER_DIR:-/var/lib/git-s3-backup}"
MARKER="${MARKER:-}"

# S3 storage class. Each object is a whole-repo tarball, comfortably over the
# 128 KB IA minimum, so STANDARD_IA is safe and cheaper for cold restore data.
STORAGE_CLASS="${STORAGE_CLASS:-STANDARD_IA}"

# Where per-repo tarballs are staged before upload. Needs room for the largest
# repo's compressed size (one at a time — we clean up as we go).
TMP_DIR="${TMP_DIR:-/tmp}"

# List actions instead of performing them. Set with --dry-run.
DRY_RUN=false

# How often to log a progress line during the upload loop: one INFO line per this
# many repos processed, plus a final line for the remaining partial batch. Set to
# 0 to disable progress lines entirely. Env-only (no flag); must be a
# non-negative integer.
PROGRESS_EVERY="${PROGRESS_EVERY:-100}"

usage() {
  cat <<EOF
Usage: backup_git_to_s3.sh [options]

  -s, --source DIR       Root of the bare-repo tree (repos at <DIR>/<owner>/<repo>.git).
                         Default: $SOURCE_DIR
  -b, --bucket NAME      Destination S3 bucket name (no s3://). Required.
  -p, --prefix PREFIX    Key prefix under the bucket. Default: $PREFIX
  -m, --marker PATH      Marker file recording the last successful run. Pins an
                         explicit path; overrides the derived default below.
      --marker-dir DIR   Directory for the auto-derived marker. The marker's name
                         is hashed from (source, bucket, prefix) so each distinct
                         job gets its own. Ignored if --marker is set.
                         Default: $MARKER_DIR
  -c, --storage-class C  S3 storage class. Default: $STORAGE_CLASS
  -t, --tmp-dir DIR      Directory for staging tarballs. Default: $TMP_DIR
      --dry-run          List what would be uploaded; make no changes.
  -h, --help             Show this help and exit.

Environment variables mirror the flags (SOURCE_DIR, BUCKET, PREFIX, MARKER,
MARKER_DIR, STORAGE_CLASS, TMP_DIR); the flag wins if both are given.
PROGRESS_EVERY (env-only, default 100) logs a progress line every N repos
processed; set to 0 to disable.

Examples:
  backup_git_to_s3.sh -s /data/git/repositories -b uw-git-backups
  backup_git_to_s3.sh -b uw-git-backups --dry-run
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--source)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      SOURCE_DIR="$2"; shift 2 ;;
    --source=*)
      SOURCE_DIR="${1#*=}"; shift ;;
    -b|--bucket)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      BUCKET="$2"; shift 2 ;;
    --bucket=*)
      BUCKET="${1#*=}"; shift ;;
    -p|--prefix)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      PREFIX="$2"; shift 2 ;;
    --prefix=*)
      PREFIX="${1#*=}"; shift ;;
    -m|--marker)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      MARKER="$2"; shift 2 ;;
    --marker=*)
      MARKER="${1#*=}"; shift ;;
    --marker-dir)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      MARKER_DIR="$2"; shift 2 ;;
    --marker-dir=*)
      MARKER_DIR="${1#*=}"; shift ;;
    -c|--storage-class)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      STORAGE_CLASS="$2"; shift 2 ;;
    --storage-class=*)
      STORAGE_CLASS="${1#*=}"; shift ;;
    -t|--tmp-dir)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      TMP_DIR="$2"; shift 2 ;;
    --tmp-dir=*)
      TMP_DIR="${1#*=}"; shift ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- logging --------------------------------------------------------------

# Emit one timestamped line to stdout so the systemd journal captures it.
# Format: "2026-09-15T12:34:56Z [INFO ] message".
#   log <LEVEL> <message...>
log() {
  local level="$1"; shift
  printf '%s [%-5s] %s\n' "$(date -u +%FT%TZ)" "$level" "$*"
}

# --- normalize prefix -----------------------------------------------------

# Strip leading and trailing slashes and collapse any internal runs of them, so
# "dcs/repos", "/dcs/repos/", and "dcs//repos" all yield the same clean prefix
# and the key stays "<prefix>/<owner>/<repo>.tar.gz" with single separators.
# An empty prefix is allowed (repos go straight under the bucket); we guard the
# empty case when building the key so we never emit a leading slash.
PREFIX="${PREFIX#"${PREFIX%%[!/]*}"}"   # trim leading slashes
PREFIX="${PREFIX%"${PREFIX##*[!/]}"}"   # trim trailing slashes
while [[ "$PREFIX" == *//* ]]; do       # collapse internal runs to single /
  PREFIX="${PREFIX//\/\///}"
done

# Drop a trailing slash from the source so "/path" and "/path/" name the same
# job (and so the ${repo#"$SOURCE_DIR"/} stripping below stays correct).
SOURCE_DIR="${SOURCE_DIR%/}"

# --- preflight ------------------------------------------------------------

[ -n "$BUCKET" ] || { echo "Error: bucket is required (-b/--bucket or \$BUCKET)." >&2; usage >&2; exit 2; }

case "$PROGRESS_EVERY" in
  ''|*[!0-9]*) echo "Error: PROGRESS_EVERY must be a non-negative integer: $PROGRESS_EVERY" >&2; exit 2 ;;
esac

# Derive the marker path from the job identity (source, bucket, prefix) unless an
# explicit --marker/$MARKER was given. The hash means each distinct job gets its
# own marker under MARKER_DIR, and a new bucket/prefix cleanly starts a full run.
if [ -z "$MARKER" ]; then
  if ! command -v sha256sum >/dev/null 2>&1; then
    log ERROR "Sha256sum not found; needed to derive the marker path. Pass -m/--marker to set one explicitly."
    exit 1
  fi
  # NUL-separate the fields so no combination of values can collide, then take a
  # short slice of the digest — ample to keep a handful of jobs distinct.
  job_hash="$(printf '%s\0' "$SOURCE_DIR" "$BUCKET" "$PREFIX" | sha256sum | cut -c1-16)"
  MARKER="$MARKER_DIR/$job_hash.marker"
  log INFO "Derived marker path: $MARKER (from source+bucket+prefix)"
fi

if [ ! -d "$SOURCE_DIR" ]; then
  log ERROR "Source dir does not exist: $SOURCE_DIR"
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  log ERROR "AWS CLI not found on PATH"
  exit 1
fi

# The marker's parent dir is where we stage the temp marker and where the final
# one lands. Create it if missing (the default path won't exist on a fresh host,
# so requiring it up front would break an out-of-the-box run); only fail if we
# can neither create it nor write to it.
MARKER_PARENT="$(dirname -- "$MARKER")"
if [ ! -d "$MARKER_PARENT" ]; then
  if mkdir -p -- "$MARKER_PARENT" 2>/dev/null; then
    log INFO "Created marker parent dir: $MARKER_PARENT"
  else
    log ERROR "Marker parent dir does not exist and could not be created: $MARKER_PARENT"
    exit 1
  fi
fi
if [ ! -w "$MARKER_PARENT" ]; then
  log ERROR "Marker parent dir not writable: $MARKER_PARENT"
  exit 1
fi

if [ ! -d "$TMP_DIR" ]; then
  log ERROR "Temp dir does not exist: $TMP_DIR"
  exit 1
fi
if [ ! -w "$TMP_DIR" ]; then
  log ERROR "Temp dir not writable: $TMP_DIR"
  exit 1
fi

# --- temp workspace + cleanup trap ----------------------------------------

# One private workdir per run under TMP_DIR; the trap removes it (and any
# tarball still inside) on any exit, so failures never leak staged archives.
WORK_DIR="$(mktemp -d "$TMP_DIR/git-s3-backup.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# --- find changed repos ---------------------------------------------------

log INFO "Arguments: source=$SOURCE_DIR bucket=$BUCKET prefix=$PREFIX marker=$MARKER storage-class=$STORAGE_CLASS dry-run=$DRY_RUN"

# find -newer needs an existing reference file; on the first run there is no
# marker, so we drop the predicate and every repo matches.
find_args=(-mindepth 2 -maxdepth 2 -type d -name '*.git')
if [ -e "$MARKER" ]; then
  find_args+=(-newer "$MARKER")
  log INFO "Marker exists; selecting repos changed since $(date -u -r "$MARKER" +%FT%TZ)"
else
  log INFO "No marker; treating all repos as changed (first run)"
fi

# Read NUL-delimited paths into an array so owners/repos with spaces or odd
# characters survive intact.
changed=()
while IFS= read -r -d '' repo; do
  changed+=("$repo")
done < <(find "$SOURCE_DIR" "${find_args[@]}" -print0)

count=${#changed[@]}
log INFO "Changed repos: $count"

if [ "$count" -eq 0 ]; then
  log INFO "Nothing to do; leaving marker untouched"
  exit 0
fi

# --- upload loop ----------------------------------------------------------

failures=0
uploaded=0
processed=0

# Log a progress line every PROGRESS_EVERY repos processed (0 disables). Called
# after each repo so the running counts reflect the repo just handled.
progress_tick() {
  [ "$PROGRESS_EVERY" -gt 0 ] || return 0
  (( processed % PROGRESS_EVERY == 0 )) || return 0
  log INFO "Progress: $processed/$count repos processed ($uploaded uploaded, $failures failed)"
}

for repo in "${changed[@]}"; do
  # Derive owner/repo from the path so the S3 key mirrors the tree.
  # ${repo#$SOURCE_DIR/} strips the source root; then drop the .git suffix.
  rel="${repo#"$SOURCE_DIR"/}"          # <owner>/<repo>.git
  rel_no_git="${rel%.git}"               # <owner>/<repo>
  key="${PREFIX:+$PREFIX/}$rel_no_git.tar.gz"   # skip prefix segment when empty
  s3_uri="s3://$BUCKET/$key"

  if [ "$DRY_RUN" = true ]; then
    log INFO "[dry-run] Would upload $repo -> $s3_uri"
    uploaded=$((uploaded + 1))
  else
    tarball="$WORK_DIR/repo.tar.gz"

    # tar from the source root with the relative path so the archive contains
    # "<owner>/<repo>.git/..." rather than absolute paths. -C avoids leading-slash
    # warnings and keeps archives portable.
    if ! tar -czf "$tarball" -C "$SOURCE_DIR" -- "$rel" 2>>"$WORK_DIR/tar.err"; then
      log ERROR "Tar failed for $repo: $(tail -n1 "$WORK_DIR/tar.err" 2>/dev/null)"
      rm -f "$tarball"
      failures=$((failures + 1))
    elif ! aws s3 cp "$tarball" "$s3_uri" --storage-class "$STORAGE_CLASS" >/dev/null 2>>"$WORK_DIR/aws.err"; then
      log ERROR "Upload failed for $repo -> $s3_uri: $(tail -n1 "$WORK_DIR/aws.err" 2>/dev/null)"
      rm -f "$tarball"
      failures=$((failures + 1))
    else
      rm -f "$tarball"
      uploaded=$((uploaded + 1))
    fi
  fi

  processed=$((processed + 1))
  progress_tick
done

# Final line for the trailing partial batch (skipped if the last tick already
# landed exactly on a PROGRESS_EVERY boundary, to avoid a duplicate).
if [ "$PROGRESS_EVERY" -gt 0 ] && (( processed % PROGRESS_EVERY != 0 )); then
  log INFO "Progress: $processed/$count repos processed ($uploaded uploaded, $failures failed)"
fi

# --- marker update + summary ----------------------------------------------

if [ "$DRY_RUN" = true ]; then
  log INFO "Dry-run complete: $uploaded repo(s) would be uploaded; marker not touched"
  exit 0
fi

if [ "$failures" -gt 0 ]; then
  log ERROR "Done with failures: uploaded=$uploaded failed=$failures of $count; marker NOT advanced (will retry next run)"
  exit 1
fi

# All uploads succeeded. Stage a temp marker and move it into place atomically
# so the recorded timestamp only ever advances on a fully successful run.
tmp_marker="$(mktemp "$MARKER_PARENT/.$(basename -- "$MARKER").XXXXXX")"
mv -f "$tmp_marker" "$MARKER"
log INFO "Done: uploaded=$uploaded of $count; marker advanced to $(date -u -r "$MARKER" +%FT%TZ)"
