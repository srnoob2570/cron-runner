#!/usr/bin/env bash
# cron-runner — dedicated GitHub Actions runner entrypoint.
#
# Fresh registration per container: on first boot the previous registration
# (if any) is deleted and a new one is created under the same name. Deleting
# the entry also drops any session an unclean shutdown left behind, so the
# listener never enters GitHub's 4-minute session-conflict retry loop.
# Within a container's lifetime, listener exits with rc=5 (SessionConflict)
# re-register and restart immediately instead of waiting out the lease.
#
# RUNNER_MAX_LIFETIME (seconds, default 24h, 0 = off) stops the listener while
# idle so `restart: always` recreates the container from the image, wiping
# non-persisted state.
set -uo pipefail

API="https://api.github.com"
SCOPE="${RUNNER_SCOPE:-repo}"   # repo | org

case "${SCOPE}" in
    repo)
        : "${GH_REPO:?GH_REPO required when RUNNER_SCOPE=repo, e.g. owner/repo}"
        API_BASE="${API}/repos/${GH_REPO}/actions"
        RUNNER_URL="https://github.com/${GH_REPO}"
        ;;
    org)
        : "${GH_ORG:?GH_ORG required when RUNNER_SCOPE=org}"
        API_BASE="${API}/orgs/${GH_ORG}/actions"
        RUNNER_URL="https://github.com/${GH_ORG}"
        ;;
    *) echo "[entrypoint] FATAL: RUNNER_SCOPE must be 'repo' or 'org'" >&2; exit 1 ;;
esac

# Runner name = the prefix itself, stable across recreations (--replace
# reclaims it). Override with RUNNER_NAME; use distinct prefixes per pool.
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-cron-runner}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX}}"

GH_TOKEN_LOCAL="${GH_TOKEN:-}"   # non-exported: jobs never see the PAT
unset GH_TOKEN GH_REPO GH_ORG
export RUNNER_NAME

api() { # api METHOD PATH -> response body on stdout
    curl -fsSL --max-time 30 -X "$1" \
        -H "Authorization: Bearer ${GH_TOKEN_LOCAL}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API_BASE}${2}"
}

mint_token() { # mint_token ENDPOINT -> token on stdout
    local attempt token
    for attempt in 1 2 3 4 5; do
        token="$(api POST "$1" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)"
        [ -n "${token:-}" ] && { printf '%s' "$token"; return 0; }
        echo "[entrypoint] token mint attempt ${attempt} failed, retrying in 10s" >&2
        sleep 10
    done
    return 1
}

sweep() { # sweep zombies — delete offline leftover runners with our prefix
    local ids id
    ids="$(api GET "/runners?per_page=100" 2>/dev/null | jq -r \
        --arg prefix "${RUNNER_NAME_PREFIX}" '
        .runners[]?
        | select((.name | startswith($prefix)) and .status == "offline")
        | .id' 2>/dev/null)" || ids=""
    for id in ${ids}; do
        if api DELETE "/runners/${id}" >/dev/null 2>&1; then
            echo "[entrypoint] deregistered leftover runner id ${id}"
        else
            echo "[entrypoint] WARN: could not delete runner id ${id} (will retry next cycle)" >&2
        fi
    done
}

register() { # register/re-claim the runner name with --replace (idempotent)
    if [ -z "${GH_TOKEN_LOCAL}" ]; then
        echo "[entrypoint] FATAL: GH_TOKEN required to register the runner" >&2
        exit 1
    fi
    sweep zombies
    local TOKEN
    TOKEN="$(mint_token "/runners/registration-token")" || {
        echo "[entrypoint] FATAL: could not mint registration token" >&2
        exit 1
    }
    echo "[entrypoint] registration token minted (expires in 1h)"
    local CONFIG_ARGS=(
        --unattended
        --url "${RUNNER_URL}"
        --token "${TOKEN}"
        --name "${RUNNER_NAME}"
        --disableupdate
        --replace
        --work "_work"
    )
    [ -n "${RUNNER_LABELS:-}" ] && CONFIG_ARGS+=(--labels "${RUNNER_LABELS}")
    if ! ./config.sh "${CONFIG_ARGS[@]}"; then
        echo "[entrypoint] FATAL: config.sh failed" >&2
        exit 1
    fi
    unset TOKEN CONFIG_ARGS
    echo "[entrypoint] registered as ${RUNNER_NAME} (dedicated)"
}

# Wipe the previous generation's registration. Two halves, both required:
# the API delete drops the agent entry (and any session an unclean shutdown
# left behind), the local rm clears .runner/.credentials — config.sh refuses
# to reconfigure while those exist, --replace alone does not help.
clear_previous() {
    [ -f .runner ] || return 0
    local ID
    ID="$(jq -r '.agentId // empty' .runner 2>/dev/null || true)"
    if [ -n "${ID}" ]; then
        api DELETE "/runners/${ID}" >/dev/null 2>&1 || true   # 404 = already gone
        echo "[entrypoint] removed previous registration (agent id ${ID})"
    fi
    rm -f .runner .credentials .credentials_rsaparams
}

if [ ! -f /tmp/.registered ]; then
    clear_previous
    register
    touch /tmp/.registered
fi

# Run + lifetime watchdog.
LIFETIME="${RUNNER_MAX_LIFETIME:-86400}"

run_listener() {
    echo "[entrypoint] starting Runner.Listener as ${RUNNER_NAME} (PID $$)"
    ./run.sh &
    RUNNER_PID=$!
    trap 'kill -TERM "${RUNNER_PID}" 2>/dev/null || true' TERM INT
    wait "${RUNNER_PID}"; RC=$?
    if [ "${RC}" -gt 128 ]; then                       # trap interrupted wait
        wait "${RUNNER_PID}"; RC=$?
    fi
    if [ -n "${WATCHDOG_PID:-}" ]; then                # stop a pending reset
        kill "${WATCHDOG_PID}" 2>/dev/null || true
    fi
    return "${RC}"
}

# idle check: Runner.Worker exists only while a job runs (comm truncated
# to 15 chars, so the exact name match still works).
idle() {
    local d
    for d in /proc/[0-9]*/comm; do
        [ "$(cat "$d" 2>/dev/null)" = "Runner.Worker" ] && return 1
    done
    return 0
}

if [ "${LIFETIME}" -gt 0 ] 2>/dev/null; then
    (
        sleep "${LIFETIME}"
        until idle; do sleep 30; done   # never reset mid-job
        echo "[entrypoint] lifetime reached and runner idle; stopping for a clean reset"
        kill -TERM "${RUNNER_PID:-}" 2>/dev/null || true
    ) &
    WATCHDOG_PID=$!
fi

run_listener
RC=$?

# rc=5 (SessionConflict) means an orphaned session still holds the runner
# entry (e.g. GitHub-side race right after a recreate). Don't wait for the
# session lease: re-register with --replace and restart immediately.
if [ "${RC}" -eq 5 ]; then
    echo "[entrypoint] session conflict; re-registering with --replace"
    register
    touch /tmp/.registered
    run_listener
    RC=$?
fi

echo "[entrypoint] runner exited (rc=${RC}); restart:always recreates the container"
exit "${RC}"