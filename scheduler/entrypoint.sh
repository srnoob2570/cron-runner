#!/bin/sh
# cron-runner scheduler entrypoint: run the crontab, that's all.
set -eu

CRON_FILE=/etc/crontabs/root

if [ ! -f "$CRON_FILE" ]; then
    echo "FATAL: no schedule. Mount your crontab at ${CRON_FILE} (see crontab.example)." >&2
    exit 1
fi

exec /usr/local/bin/supercronic "$CRON_FILE"