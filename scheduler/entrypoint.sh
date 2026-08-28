#!/bin/sh
# cron-runner scheduler bootstrap.
#
# Schedules come from (first match wins):
#   1. $CRONTAB env var — pipe-separated entries, e.g.
#        CRONTAB='*/10 * * * * /scheduler/dispatch.sh workflow owner/repo wf.yml main'
#      This is the PaaS/Dokploy path: no bind mounts, one env var in the UI.
#   2. A crontab file mounted at /etc/crontabs/root (docker-compose local path).
set -eu

CRON_DIR=/etc/crontabs
CRON_FILE=$CRON_DIR/root

if [ -n "${CRONTAB:-}" ]; then
    # One entry per pipe; pipes are illegal in cron fields, so this is unambiguous.
    # busybox crond reads files named after the user in its -c dir, so the env
    # crontab must land at <dir>/root. /tmp is a tmpfs mount — nothing touches
    # the container filesystem proper.
    CRON_DIR=/tmp/crontabs
    CRON_FILE=$CRON_DIR/root
    mkdir -p "$CRON_DIR"
    printf '%s\n' "$CRONTAB" | tr '|' '\n' > "$CRON_FILE"
elif [ ! -f "$CRON_FILE" ]; then
    echo "FATAL: no schedule. Set the CRONTAB env var or mount a file at $CRON_FILE." >&2
    exit 1
fi

# Alpine ships no curl; dispatch.sh needs it for the REST API.
apk add --no-cache curl >/dev/null

# Dispatch immediately on boot so a scheduler restart doesn't wait for the first
# tick. Only patterns that are due at boot time (*/N and *) fire; others wait.
# Crontab line format: <5 cron fields> <command> <args...>
while read -r min hr dom mon dow cmd rest; do
    case "$min" in '#'*) continue ;; esac
    [ -z "${cmd:-}" ] && continue
    case "$min" in
        '*/'*|'*') "$cmd" $rest || true ;;
    esac
done < "$CRON_FILE"

exec crond -f -l 2 -c "$(dirname "$CRON_FILE")"