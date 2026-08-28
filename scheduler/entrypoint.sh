#!/bin/sh
# cronrunner scheduler bootstrap.
# The crontab file is bind-mounted at /etc/crontabs/root (see docker-compose.yml).
set -eu

if [ ! -f /etc/crontabs/root ]; then
    echo "FATAL: no crontab mounted. Create one: cp crontab.example crontab" >&2
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
done < /etc/crontabs/root

exec crond -f -l 2