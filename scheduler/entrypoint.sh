#!/bin/sh
# cron-runner scheduler bootstrap. Schedules come from the CRONTAB env var
# (pipe-separated entries, the PaaS path) or a file mounted at
# /etc/crontabs/root (docker compose path).
set -eu

CRON_DIR=/etc/crontabs
CRON_FILE=$CRON_DIR/root

if [ -n "${CRONTAB:-}" ]; then
    # busybox crond reads files named after the user in its -c dir.
    CRON_DIR=/tmp/crontabs
    CRON_FILE=$CRON_DIR/root
    mkdir -p "$CRON_DIR"
    printf '%s\n' "$CRONTAB" | tr '|' '\n' > "$CRON_FILE"
elif [ ! -f "$CRON_FILE" ]; then
    echo "FATAL: no schedule. Set the CRONTAB env var or mount a file at $CRON_FILE." >&2
    exit 1
fi

apk add --no-cache curl >/dev/null

# Dispatch immediately on boot; only */N and * entries are due at boot time.
while read -r min hr dom mon dow cmd rest; do
    case "$min" in '#'*) continue ;; esac
    [ -z "${cmd:-}" ] && continue
    case "$min" in
        '*/'*|'*') "$cmd" $rest || true ;;
    esac
done < "$CRON_FILE"

exec crond -f -l 2 -c "$(dirname "$CRON_FILE")"