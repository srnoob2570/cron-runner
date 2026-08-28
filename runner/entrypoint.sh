#!/usr/bin/env bash
# cronrunner — ephemeral GitHub Actions runner entrypoint.
#
# Lifecycle:
#   boot:
#     1. Sweep offline leftover runners with our prefix (crash/SIGKILL zombies).
#     2. Mint a 1h registration token with GH_TOKEN.
#     3. config.sh --ephemeral (one job, then auto-deregister + local wipe).
#   shutdown (ALWAYS runs after run.sh exits):
#     4. config.sh remove with a fresh remove-token (if still configured).
#     5. Verify via API: nothing may remain registered under our exact name.
#   The exit code propagates; `restart: always` recreates the container with
#   a fresh name and token.
#
# Secret hygiene:
#   - GH_TOKEN/GH_REPO/GH_ORG are unset before the runner starts. A
#     non-exported copy is kept ONLY for the shutdown cleanup (shell vars are
#     not inherited by job processes, so jobs never see the PAT).
#   - Registration/remove tokens are single-use and expire after 1h.
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN required to mint a registration token}"

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

# Recognizable runner names: PREFIX-HOSTNAME (e.g. cronrunner-8e3544346ab8).
# Set RUNNER_NAME to override entirely.
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-cronrunner}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX}-$(hostname)}"

GH_TOKEN_LOCAL="$GH_TOKEN"   # non-exported: visible to api()/cleanup only
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

sweep() { # sweep exact|zombies — delete matching GitHub-side runners
    local mode="$1" ids id
    ids="$(api GET "/runners?per_page=100" 2>/dev/null | jq -r \
        --arg name "${RUNNER_NAME}" --arg prefix "${RUNNER_NAME_PREFIX}-" --arg mode "$mode" '
        .runners[]?
        | select(($mode == "exact" and .name == $name)
              or ($mode == "zombies" and (.name | startswith($prefix)) and .status == "offline"))
        | .id' 2>/dev/null)" || ids=""
    for id in ${ids}; do
        if api DELETE "/runners/${id}" >/dev/null 2>&1; then
            echo "[entrypoint] deregistered leftover runner id ${id}"
        else
            echo "[entrypoint] WARN: could not delete runner id ${id} (will retry next cycle)" >&2
        fi
    done
}

# 1. Heal zombies left by a crashed/killed container (offline + our prefix).
sweep zombies

# 2. Mint registration token.
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
    --ephemeral
    --disableupdate
    --replace
    --work "_work"
)
[ -n "${RUNNER_LABELS:-}" ] && CONFIG_ARGS+=(--labels "${RUNNER_LABELS}")

./config.sh "${CONFIG_ARGS[@]}"
unset TOKEN RUNNER_URL CONFIG_ARGS

cleanup() { # $1 = run.sh exit code — enforce deregistration, no zombies left
    local rc="$1" remove_token
    echo "[entrypoint] runner exited (rc=${rc}); enforcing deregistration"
    if [ -f .runner ]; then   # still configured -> ephemeral exit didn't clean up
        remove_token="$(mint_token "/runners/remove-token" || true)"
        if [ -n "${remove_token:-}" ] && ./config.sh remove --token "${remove_token}" >/dev/null 2>&1; then
            echo "[entrypoint] config.sh remove OK"
        else
            echo "[entrypoint] WARN: config.sh remove failed; sweeping by name instead" >&2
        fi
    fi
    sweep exact   # verify: nothing may remain registered under our name
    echo "[entrypoint] deregistration verified; restart:always recreates the container"
}

echo "[entrypoint] starting ephemeral Runner.Listener as ${RUNNER_NAME} (PID $$)"
./run.sh &
RUNNER_PID=$!
trap 'kill -TERM "${RUNNER_PID}" 2>/dev/null || true' TERM INT
wait "${RUNNER_PID}"; RC=$?
[ "${RC}" -gt 128 ] && wait "${RUNNER_PID}" 2>/dev/null   # trap interrupted wait
cleanup "${RC}"
exit "${RC}"