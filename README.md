# System Maintenance & Cleanup Tools

A collection of practical, single-purpose utility scripts to simplify system administration.

Each script has its own page under [`docs/`](docs/) with a description, flags, and examples. Every script is also self-documenting — run it with `--help`.

## Scripts

| Script | Description | Docs |
| --- | --- | --- |
| `aws-overview.sh` | Inventories AWS resources across all enabled regions, to stdout or split into per-region files. | [docs](docs/aws-overview.md) |
| `backup_git_to_s3.sh` | Incrementally archives changed bare git repos to S3, one `tar.gz` per repo. | [docs](docs/backup_git_to_s3.md) |
| `find_grafana_usage.py` | Finds Grafana panels and alert rules by datasource type, query regex, panel type, or folder (migration worklists & audits). | [docs](docs/find_grafana_usage.md) |
| `find_old_files.sh` | Locates or deletes files that haven't been modified since a configurable time. | [docs](docs/find_old_files.md) |
| `openbao_healthcheck.sh` | End-to-end smoke test of an OpenBao/Vault server: health, userpass login, KV read/write, and policy listing. | [docs](docs/openbao_healthcheck.md) |

## Adding New Scripts

To keep the front page short as this repo grows:

1. Add one row to the **Scripts** table above, linking to the script's doc page.
2. Create `docs/<script>.md` with a brief description, its flags, and a few real-world examples.
3. Keep the script self-documenting: a `--help`/usage block is the source of truth for flags; the doc page mirrors it.
4. **Keep it sorted**: list scripts alphabetically in the table.
5. **KISS**: no walls of text, no unnecessary fluff.
