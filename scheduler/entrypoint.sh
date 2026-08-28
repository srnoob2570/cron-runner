#!/bin/sh
# cron-runner scheduler bootstrap. Schedules come from the CRONTAB env var
# (pipe-separated entries, the PaaS path) or a file mounted at
# /etc/crontabs/root (docker compose path).
#
# The cron daemon is supercronic, not busybox crond: busybox crond spawns
# jobs with vfork() and runs libc code (setuid/setgroups) before execve,
# which on musl can deadlock permanently and silently — crond frozen in D
# state, no logs, container still Up. supercronic is a static Go binary that
# spawns jobs via clone+execve with no libc in the vfork window, so it is
# immune to that bug class. It also logs every job run to stdout and
# handles SIGTERM/SIGINT gracefully.
set -eu

CRON_DIR=/etc/crontabs
CRON_FILE=$CRON_DIR/root

if [ -n "${CRONTAB:-}" ]; then
    CRON_DIR=/tmp/crontabs
    CRON_FILE=$CRON_DIR/root
    mkdir -p "$CRON_DIR"
    printf '%s\n' "$CRONTAB" | tr '|' '\n' > "$CRON_FILE"
elif [ ! -f "$CRON_FILE" ]; then
    echo "FATAL: no schedule. Set the CRONTAB env var or mount a file at $CRON_FILE." >&2
    exit 1
fi

apk add --no-cache curl >/dev/null

# Install supercronic, pinned by version + sha256 digest per architecture.
# Fails hard on any mismatch or download error; restart:always retries.
SUPERCRONIC_VERSION=v0.2.49
case "$(uname -m)" in
    x86_64)
        SUPERCRONIC_ARCH=amd64
        SUPERCRONIC_SHA256=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1
        ;;
    aarch64|arm64)
        SUPERCRONIC_ARCH=arm64
        SUPERCRONIC_SHA256=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5
        ;;
    *)
        echo "FATAL: unsupported architecture $(uname -m)" >&2
        exit 1
        ;;
esac

SUPERCRONIC=/usr/local/bin/supercronic
mkdir -p /usr/local/bin
curl -sSfL --max-time 120 -o "$SUPERCRONIC" \
    "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${SUPERCRONIC_ARCH}"
echo "${SUPERCRONIC_SHA256}  ${SUPERCRONIC}" | sha256sum -c -
chmod +x "$SUPERCRONIC"

# Dispatch immediately on boot; only */N and * entries are due at boot time.
# (supercronic never runs missed or initial jobs on startup, so this keeps
# the boot-dispatch behavior.)
while read -r min hr dom mon dow cmd rest; do
    case "$min" in '#'*) continue ;; esac
    [ -z "${cmd:-}" ] && continue
    case "$min" in
        '*/'*|'*') "$cmd" $rest || true ;;
    esac
done < "$CRON_FILE"

exec "$SUPERCRONIC" "$CRON_FILE"