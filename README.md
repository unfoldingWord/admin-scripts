# System Maintenance & Cleanup Tools

A collection of lightweight, single-purpose Bash utility scripts to simplify system administration.

## Scripts Overview

| Script Name | Description |
| --- | --- |
| `find_old_files.sh` | Locates or deletes files that haven't been modified since a configurable time. |

---

## `find_old_files.sh`

Scans a targeted directory for files exceeding a specific modification age. By default, it runs safely in verification mode, but it can purge files instantly when triggered with the delete flag.

### Flags

* **`-a` / `--age**`: The modification age threshold in days (e.g., `180` for 6 months). Defaults to `365` days.
* **`-d` / `--delete**`: Switches the script from scan/verification mode to active deletion mode.
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
4. **KISS**: No walls of text, no unnecessary fluff.
