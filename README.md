# System Maintenance & Cleanup Tools

A collection of practical, single-purpose Bash utility scripts to simplify system administration.

## Scripts Overview

| Script Name | Description |
| --- | --- |
| `aws-overview.sh` | Inventories AWS resources across all enabled regions, to stdout or split into per-region files. |
| `find_old_files.sh` | Locates or deletes files that haven't been modified since a configurable time. |

---

## `aws-overview.sh`

Inventories AWS resources across all enabled regions using the AWS CLI. Covers global services (S3, IAM, Route 53, CloudFront) plus a wide range of per-region resources (EC2, VPC networking, RDS, Lambda, load balancers, DynamoDB, KMS, ACM, and more). By default it prints a readable summary to stdout; in split mode it writes region-first files with a summary index and one JSON detail file per resource. Progress logs go to stderr, so they never pollute the report.

The region-independent services are scanned under a pseudo-region named `global`. It is treated as just another region: included by default, but when you pass `-r` it runs only if you list it explicitly.

**Requires:** AWS CLI v2, `jq`, and `column` (util-linux). Assumes credentials are available (e.g. an IAM instance role).

### Flags

* **`-o` / `--outdir <dir>`**: Split output into region-first files under `<dir>` (one directory per region, including `global`). Omit to print everything to stdout.
* **`-r` / `--regions "<list>"`**: Space-separated regions to scan (e.g. `"us-east-1 eu-west-1"`). Defaults to `global` plus all enabled regions. `global` is a region here (S3, IAM, Route 53, CloudFront) and runs only if listed, e.g. `-r "global us-west-2"`.
* **`-l` / `--log-level <level>`**: Log verbosity: `DEBUG`, `INFO`, `WARN`, or `ERROR` (default `INFO`). Logs go to stderr with timestamps and levels.
* **`-h` / `--help`**: Show help and exit.

You can also set the `REGIONS` and `LOG_LEVEL` environment variables instead of `--regions` / `--log-level` (the flag wins if both are given).

### Usage Examples

**Print an overview of everything to the screen:**

```bash
./aws-overview.sh

```

**Save the whole run to one file:**

```bash
./aws-overview.sh > report.txt

```

**Split output into per-region files for the global services plus one region:**

```bash
./aws-overview.sh -o out -r "global us-west-2"

```

**Limit the scan to specific regions (no global section):**

```bash
./aws-overview.sh -r "us-east-1 eu-west-1"

```

**Run with verbose logging:**

```bash
./aws-overview.sh --log-level DEBUG

```

---

## `find_old_files.sh`

Scans a targeted directory for files exceeding a specific modification age. By default, it runs safely in verification mode, but it can purge files instantly when triggered with the delete flag.

### Flags

* **`-a` / `--age`**: The modification age threshold in days (e.g., `180` for 6 months). Defaults to `365` days.
* **`-d` / `--delete`**: Switches the script from scan/verification mode to active deletion mode.
* **`[path]`**: The target directory path (positional argument). Defaults to the current directory (`.`) if omitted.

### Usage Examples

**Scan the current directory for files older than a year:**

```bash
./find_old_files.sh

```

**Scan a specific folder for files older than 6 months (180 days):**

```bash
./find_old_files.sh /path/to/folder --age 180

```

**Delete files older than 30 days:**

```bash
./find_old_files.sh /path/to/folder --age 30 --delete

```

---

## Adding New Scripts

To keep things clean as this repo grows, stick to this simple layout for any new script:

1. Add a single line for the script to the **Scripts Overview** index table.
2. Create a clean section with a brief description.
3. List the flags and a few real-world examples.
4. **Keep it sorted**: List scripts alphabetically, both in the index table and in their sections.
5. **KISS**: No walls of text, no unnecessary fluff.
