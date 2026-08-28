#!/usr/bin/env bash
# cronrunner — dedicated GitHub Actions runner entrypoint.
#
# Registration model: the runner registers ONCE and stays registered.
#   - First boot or container recreation from image: mint a registration
#     token and register (persistent, NOT ephemeral) with --replace, so the
#     name is reclaimed and GitHub keeps a single runner entry.
#   - Plain restarts reuse the on-disk registration: zero API calls, the
#     runner is online again in seconds.
#   - Shutdown NEVER deregisters; registration survives restarts.
#
# State reset (the security story): RUNNER_MAX_LIFETIME (seconds, default
# 24h, 0 = disabled) stops the listener once the lifetime expires AND the
# runner is idle. The container exits and `restart: always` recreates it
# from the image — wiping everything not persisted (work dir, caches,
# anything a job installed) — while keeping the registration (fresh
# --replace registration under the same name).
#
# Secret hygiene:
#   - GH_TOKEN is required only to (re-)register. It is unset before the
#     listener starts; a non-exported copy is kept for the registration API
#     calls only (shell vars are not inherited by job processes).
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

# Recognizable runner names: PREFIX-HOSTNAME (e.g. cronrunner-runner-1).
# Set RUNNER_NAME to override entirely.
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-cronrunner}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX}-$(hostname)}"

GH_TOKEN_LOCAL="${GH_TOKEN:-}"   # non-exported: visible to api()/mint_token only
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
        --arg prefix "${RUNNER_NAME_PREFIX}-" '
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

# ── Registration (only when needed) ─────────────────────────────────────────
if [ -f .runner ]; then
    echo "[entrypoint] reusing existing registration for ${RUNNER_NAME} (no API calls)"
else
    if [ -z "${GH_TOKEN_LOCAL}" ]; then
        echo "[entrypoint] FATAL: GH_TOKEN required to register the runner (first boot or recreated container)" >&2
        exit 1
    fi
    sweep zombies
    TOKEN="$(mint_token "/runners/registration-token")" || {
        echo "[entrypoint] FATAL: could not mint registration token" >&2
        exit 1
    }
    echo "[entrypoint] registration token minted (expires in 1h)"

    CONFIG_ARGS=(
        --unattended
        --url "${RUNNER_URL}"
        --token "${TOKEN}"
        --name "${RUNNER_NAME}"
        --disableupdate
        --replace
        --work "_work"
    )
    [ -n "${RUNNER_LABELS:-}" ] && CONFIG_ARGS+=(--labels "${RUNNER_LABELS}")

    ./config.sh "${CONFIG_ARGS[@]}"
    unset TOKEN RUNNER_URL CONFIG_ARGS
    echo "[entrypoint] registered as ${RUNNER_NAME} (dedicated)"
fi

# ── Run + lifetime watchdog ─────────────────────────────────────────────────
LIFETIME="${RUNNER_MAX_LIFETIME:-86400}"

echo "[entrypoint] starting Runner.Listener as ${RUNNER_NAME} (PID $$)"
./run.sh &
RUNNER_PID=$!
trap 'kill -TERM "${RUNNER_PID}" 2>/dev/null || true' TERM INT

# idle check: Runner.Worker exists only while a job is running (comm is
# truncated to 15 chars, so the exact name match still works).
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
        kill -TERM "${RUNNER_PID}" 2>/dev/null || true
    ) &
    WATCHDOG_PID=$!
fi

wait "${RUNNER_PID}"; RC=$?
[ "${RC}" -gt 128 ] && wait "${RUNNER_PID}" 2>/dev/null   # trap interrupted wait
if [ -n "${WATCHDOG_PID:-}" ]; then                       # stop a pending reset
    kill "${WATCHDOG_PID}" 2>/dev/null || true
fi
echo "[entrypoint] runner exited (rc=${RC}); restart:always recreates the container"
exit "${RC}"