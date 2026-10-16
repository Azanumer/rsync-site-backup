# rsync-site-backup

rsnapshot-style hardlink-rotation backups for website files — one script, no
daemon. Daily, weekly, and monthly snapshots where unchanged files are
hard-linked, so keeping 30 daily snapshots of a 5 GB site costs roughly
5 GB plus one day of changes. Works locally or over SSH, safe to run from cron.

## Layout

Inside the destination:

```
daily.0  daily.1 … daily.6      (rotated; daily.0 is newest)
weekly.0 … weekly.3            (taken on Mondays)
monthly.0 … monthly.5          (taken on the 1st)
```

## Usage

```bash
./backup-site.sh \
    --source /var/www/mysite \
    --dest backuphost:/backups/mysite \
    --exclude 'wp-content/cache/*' \
    --exclude '*.log' \
    --to admin@example.com
```

Cron (every night at 2:30, SSH key auth to the backup host):

```
30 2 * * * /opt/bin/backup-site.sh --source /var/www/mysite \
    --dest backuphost:/backups/mysite --exclude '*.log' \
    --to admin@example.com --logfile /var/log/sitebackup.log
```

## Options

| Option | What it does |
|---|---|
| `--source DIR` | Directory to back up (absolute path, required) |
| `--dest DEST` | `/local/path` or `[user@]host:/path` (required) |
| `--daily/--weekly/--monthly N` | Snapshots to keep (defaults 7 / 4 / 6) |
| `--exclude PATTERN` | rsync exclude, repeatable |
| `--exclude-file FILE` | rsync `--exclude-from` file |
| `--force-weekly`, `--force-monthly` | Take that snapshot now instead of waiting |
| `--pre-hook CMD`, `--post-hook CMD` | Run before / after (backup aborts if pre-hook fails) |
| `--to EMAIL` | Mail a summary on failure (`--mail-always` also on success) |
| `--lockfile PATH` | Prevent overlapping runs (default `/var/lock/rsync-site-backup.lock`) |
| `--logfile PATH` | Append the run log to a file |
| `--dry-run` | Show the plan, change nothing |

## Notes

- The first run is a full copy; later runs transfer only changed files and
  hard-link everything else via `--link-dest`.
- Remote destinations need passwordless SSH (`ssh -o BatchMode=yes`); the
  rotation commands run over the same SSH connection.
- A `flock` lock prevents two runs from rotating at the same time; a stuck
  lock means a previous run is still alive (or was killed — check first).
- Pair with database dumps (e.g. a `mysqldump` cron or `mysql-backup-s3`)
  for a complete site backup.

MIT licensed.
