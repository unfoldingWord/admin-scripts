# `aws-overview.sh`

Inventories AWS resources across all enabled regions using the AWS CLI. Covers global services (S3, IAM, Route 53, CloudFront) plus a wide range of per-region resources (EC2, VPC networking, RDS, Lambda, load balancers, DynamoDB, KMS, ACM, and more). By default it prints a readable summary to stdout; in split mode it writes region-first files with a summary index and one JSON detail file per resource. Progress logs go to stderr, so they never pollute the report.

The region-independent services are scanned under a pseudo-region named `global`. It is treated as just another region: included by default, but when you pass `-r` it runs only if you list it explicitly.

**Requires:** AWS CLI v2, `jq`, and `column` (util-linux). Assumes credentials are available (e.g. an IAM instance role).

## Flags

* **`-o` / `--outdir <dir>`**: Split output into region-first files under `<dir>` (one directory per region, including `global`). Omit to print everything to stdout.
* **`-r` / `--regions "<list>"`**: Space-separated regions to scan (e.g. `"us-east-1 eu-west-1"`). Defaults to `global` plus all enabled regions. `global` is a region here (S3, IAM, Route 53, CloudFront) and runs only if listed, e.g. `-r "global us-west-2"`.
* **`-l` / `--log-level <level>`**: Log verbosity: `DEBUG`, `INFO`, `WARN`, or `ERROR` (default `INFO`). Logs go to stderr with timestamps and levels.
* **`-h` / `--help`**: Show help and exit.

You can also set the `REGIONS` and `LOG_LEVEL` environment variables instead of `--regions` / `--log-level` (the flag wins if both are given).

## Usage Examples

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
