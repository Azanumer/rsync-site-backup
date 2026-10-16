#!/usr/bin/env bash
#
# backup-site.sh — rsnapshot-style hardlink-rotation backups of website files.
#
# Keeps daily/weekly/monthly snapshots where unchanged files are hard-linked,
# so 30 daily snapshots of a 5 GB site cost ~5 GB + one day of changes.
# Works locally or over SSH (rsync -e ssh); safe to run from cron.
#
# Layout inside DEST:
#   daily.0  daily.1 ... daily.6      (rotated, daily.0 = newest)
#   weekly.0 weekly.1 ... weekly.3     (taken on Mondays, or --force-weekly)
#   monthly.0 monthly.1 ... monthly.5  (taken on the 1st, or --force-monthly)
#
# Example:
#   ./backup-site.sh --source /var/www/mysite --dest backuphost:/backups/mysite \
#       --exclude 'wp-content/cache/*' --exclude '*.log' \
#       --to admin@example.com
#
set -euo pipefail

SOURCE=""
DEST=""
DAILY_KEEP=7
WEEKLY_KEEP=4
MONTHLY_KEEP=6
MAIL_TO=""
FROM_ADDR="sitebackup@$(hostname -f 2>/dev/null || hostname)"
LOCKFILE="/var/lock/rsync-site-backup.lock"
LOGFILE=""
DRY_RUN=0
FORCE_WEEKLY=0
FORCE_MONTHLY=0
PRE_HOOK=""
POST_HOOK=""
EXCLUDES=()

usage() {
    cat <<'EOF'
Usage: backup-site.sh --source DIR --dest DEST [options]

Required:
  --source DIR        directory to back up (absolute path)
  --dest DEST         backup base: /local/path or [user@]host:/path (absolute)

Options:
  --daily N           keep N daily snapshots (default 7)
  --weekly N          keep N weekly snapshots (default 4)
  --monthly N         keep N monthly snapshots (default 6)
  --exclude PATTERN   rsync exclude (repeatable), e.g. --exclude '*.log'
  --exclude-file F    rsync --exclude-from file
  --force-weekly      take a weekly snapshot now (normally only on Mondays)
  --force-monthly     take a monthly snapshot now (normally only on the 1st)
  --pre-hook CMD      command run before the backup (aborts on failure)
  --post-hook CMD     command run after a successful backup
  --to EMAIL          mail a summary on failure (or always with --mail-always)
  --mail-always       mail the summary even on success
  --from EMAIL        sender address (default sitebackup@<hostname>)
  --lockfile PATH     lock file (default /var/lock/rsync-site-backup.lock)
  --logfile PATH      append the run log here as well as stdout
  --dry-run           show what would happen, change nothing
  -h, --help          this help
EOF
}

EXCLUDE_FILE=""
MAIL_ALWAYS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --source)      SOURCE="$2"; shift 2 ;;
        --dest)        DEST="$2"; shift 2 ;;
        --daily)       DAILY_KEEP="$2"; shift 2 ;;
        --weekly)      WEEKLY_KEEP="$2"; shift 2 ;;
        --monthly)     MONTHLY_KEEP="$2"; shift 2 ;;
        --exclude)     EXCLUDES+=(--exclude="$2"); shift 2 ;;
        --exclude-file) EXCLUDE_FILE="$2"; shift 2 ;;
        --force-weekly)  FORCE_WEEKLY=1; shift ;;
        --force-monthly) FORCE_MONTHLY=1; shift ;;
        --pre-hook)    PRE_HOOK="$2"; shift 2 ;;
        --post-hook)   POST_HOOK="$2"; shift 2 ;;
        --to)          MAIL_TO="$2"; shift 2 ;;
        --mail-always) MAIL_ALWAYS=1; shift ;;
        --from)        FROM_ADDR="$2"; shift 2 ;;
        --lockfile)    LOCKFILE="$2"; shift 2 ;;
        --logfile)     LOGFILE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$SOURCE" ] || { echo "ERROR: --source is required" >&2; usage >&2; exit 1; }
[ -n "$DEST" ]   || { echo "ERROR: --dest is required" >&2; usage >&2; exit 1; }
[ -d "$SOURCE" ] || { echo "ERROR: source '$SOURCE' is not a directory" >&2; exit 1; }
case "$SOURCE" in /*) ;; *) echo "ERROR: --source must be an absolute path" >&2; exit 1 ;; esac
case "$DEST" in /*|*:/*) ;; *) echo "ERROR: --dest must be absolute (or host:/abs/path)" >&2; exit 1 ;; esac
[ -n "$EXCLUDE_FILE" ] && EXCLUDES+=(--exclude-from="$EXCLUDE_FILE")

command -v rsync >/dev/null 2>&1 || { echo "ERROR: rsync not found in PATH" >&2; exit 1; }

START_TS=$(date +%s)
LOG_LINES=""

log() {
    local line="[$(date '+%F %T')] $*"
    echo "$line"
    LOG_LINES+="${line}"$'\n'
    if [ -n "$LOGFILE" ]; then
        echo "$line" >>"$LOGFILE"
    fi
    return 0
}

send_mail() { # send_mail <subject>
    [ -z "$MAIL_TO" ] && return 0
    if command -v mail >/dev/null 2>&1; then
        printf '%s' "$LOG_LINES" | mail -s "$1" -r "$FROM_ADDR" "$MAIL_TO" \
            || log "WARNING: failed to send summary mail"
    else
        log "WARNING: --to given but /usr/bin/mail not found"
    fi
}

fail() {
    log "ERROR: $*"
    local host; host="$(hostname -f 2>/dev/null || hostname)"
    send_mail "[sitebackup] FAILED on ${host}: ${SOURCE}"
    exit 1
}

# --- lock (skip locking entirely in dry-run) ---------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$LOCKFILE")"
    exec 9>"$LOCKFILE"
    flock -n 9 || fail "another backup is already running (lock $LOCKFILE)"
    log "Lock acquired: $LOCKFILE"
else
    log "DRY-RUN: no lock taken, nothing will be written"
fi

# --- helpers that work on local paths and host:/path alike -------------------
# For remote destinations we run rotation commands over ssh.
DEST_IS_REMOTE=0; SSH_HOST=""
case "$DEST" in
    *:*)
        DEST_IS_REMOTE=1
        SSH_HOST="${DEST%%:*}"
        REMOTE_PATH="${DEST#*:}"
        ;;
    *) REMOTE_PATH="$DEST" ;;
esac

remote_sh() { # remote_sh <shell-snippet> — runs locally or over ssh
    if [ "$DEST_IS_REMOTE" -eq 1 ]; then
        ssh -o BatchMode=yes "$SSH_HOST" "$1"
    else
        bash -c "$1"
    fi
}

# rotate <level> <keep>: daily.0 -> daily.1 ... drop daily.<keep>
rotate() {
    local level="$1" keep="$2" i
    log "Rotating $level (keep $keep)"
    [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN: would rotate $REMOTE_PATH/$level.*"; return 0; }
    remote_sh "
        set -e
        cd '$REMOTE_PATH' 2>/dev/null || exit 0
        if [ -d '$level.$((keep-1))' ]; then rm -rf '$level.$((keep-1))'; fi
        i=$((keep-2))
        while [ \$i -ge 0 ]; do
            if [ -d '$level.'\$i ]; then mv '$level.'\$i '$level.'\$((i+1)); fi
            i=\$((i-1))
        done
    " || fail "rotation of $level failed"
}

# snapshot_copy <from-level.0> <to-level> <keep>: cp -al clone, e.g. daily.0 -> weekly.0
snapshot_copy() {
    local from="$1" to_level="$2" keep="$3"
    log "Snapshotting $from -> $to_level.0"
    [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN: would cp -al $from to $REMOTE_PATH/$to_level.0"; return 0; }
    rotate "$to_level" "$keep"
    remote_sh "
        set -e
        cd '$REMOTE_PATH'
        mkdir -p '$to_level.0'
        cp -al '$from/.' '$to_level.0/'
    " || fail "snapshot copy $from -> $to_level.0 failed"
}

# --- pre-hook ------------------------------------------------------------------
if [ -n "$PRE_HOOK" ]; then
    log "Running pre-hook: $PRE_HOOK"
    [ "$DRY_RUN" -eq 1 ] || bash -c "$PRE_HOOK" || fail "pre-hook failed"
fi

# --- ensure destination base ---------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    remote_sh "mkdir -p '$REMOTE_PATH'" || fail "cannot create destination $DEST"
fi

# --- rotate dailies and rsync into daily.0 --------------------------------------
rotate daily "$DAILY_KEEP"

LINK_DEST_ARG=()
# remote_sh test for daily.1 existence (cheap, works for both local/remote)
if remote_sh "[ -d '$REMOTE_PATH/daily.1' ]" 2>/dev/null; then
    LINK_DEST_ARG=(--link-dest="$REMOTE_PATH/daily.1")
    log "Using --link-dest=$REMOTE_PATH/daily.1 (unchanged files hard-linked)"
fi

RSYNC_ARGS=(-a --delete --numeric-ids --stats "${EXCLUDES[@]}" "${LINK_DEST_ARG[@]}")
[ "$DRY_RUN" -eq 1 ] && RSYNC_ARGS+=(--dry-run)

log "Rsyncing $SOURCE/ -> $DEST/daily.0/"
RSYNC_OUT=""
if ! RSYNC_OUT="$(rsync "${RSYNC_ARGS[@]}" "$SOURCE/" "$DEST/daily.0/" 2>&1)"; then
    log "$RSYNC_OUT"
    fail "rsync exited non-zero"
fi
log "rsync stats:"
while IFS= read -r line; do log "  $line"; done <<<"$(printf '%s\n' "$RSYNC_OUT" | grep -E 'Number of|Total (file|transferred file) size|Total bytes')"

# --- weekly / monthly snapshots ------------------------------------------------
DOW="$(date +%u)"; DOM="$(date +%d)"
if [ "$FORCE_WEEKLY" -eq 1 ] || [ "$DOW" -eq 1 ]; then
    snapshot_copy "daily.0" "weekly" "$WEEKLY_KEEP"
else
    log "Skipping weekly snapshot (not Monday; use --force-weekly to override)"
fi
if [ "$FORCE_MONTHLY" -eq 1 ] || [ "$DOM" -eq 01 ]; then
    snapshot_copy "daily.0" "monthly" "$MONTHLY_KEEP"
else
    log "Skipping monthly snapshot (not the 1st; use --force-monthly to override)"
fi

# --- post-hook -------------------------------------------------------------------
if [ -n "$POST_HOOK" ]; then
    log "Running post-hook: $POST_HOOK"
    [ "$DRY_RUN" -eq 1 ] || bash -c "$POST_HOOK" || fail "post-hook failed"
fi

DURATION=$(( $(date +%s) - START_TS ))
log "Backup complete in ${DURATION}s: $SOURCE -> $DEST/daily.0"

if [ "$MAIL_ALWAYS" -eq 1 ]; then
    host="$(hostname -f 2>/dev/null || hostname)"
    send_mail "[sitebackup] OK on ${host}: ${SOURCE}"
fi
# lock released automatically when FD 9 closes at exit
