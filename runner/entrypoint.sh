#!/usr/bin/env bash
# cronrunner — ephemeral GitHub Actions runner entrypoint.
#
# Lifecycle: mint a 1h registration token with GH_TOKEN -> `config.sh --ephemeral`
# (one job, then auto-deregister + local config wipe) -> exec run.sh.
# With `restart: always` the orchestrator recreates the container after each job,
# so every job runs in a freshly-registered, freshly-minted runner.
#
# Secret hygiene:
#   - GH_TOKEN / GH_REPO / GH_ORG are unset before the runner starts, so they
#     never reach job environment.
#   - The registration token is single-use and expires after 1h; it is only ever
#     passed to config.sh inside this container.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required to mint a registration token}"

API="https://api.github.com"
SCOPE="${RUNNER_SCOPE:-repo}"   # repo | org

case "${SCOPE}" in
    repo)
        : "${GH_REPO:?GH_REPO required when RUNNER_SCOPE=repo, e.g. owner/repo}"
        TOKEN_ENDPOINT="${API}/repos/${GH_REPO}/actions/runners/registration-token"
        RUNNER_URL="https://github.com/${GH_REPO}"
        ;;
    org)
        : "${GH_ORG:?GH_ORG required when RUNNER_SCOPE=org}"
        TOKEN_ENDPOINT="${API}/orgs/${GH_ORG}/actions/runners/registration-token"
        RUNNER_URL="https://github.com/${GH_ORG}"
        ;;
    *) echo "[entrypoint] FATAL: RUNNER_SCOPE must be 'repo' or 'org'" >&2; exit 1 ;;
esac

mint_token() {
    local attempt token
    for attempt in 1 2 3 4 5; do
        token="$(curl -fsSL --max-time 30 \
            -X POST \
            -H "Authorization: Bearer ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${TOKEN_ENDPOINT}" \
            | jq -r '.token // empty')" && [ -n "${token:-}" ] && printf '%s' "$token" && return 0
        echo "[entrypoint] token mint attempt ${attempt} failed, retrying in 10s" >&2
        sleep 10
    done
    echo "[entrypoint] FATAL: could not mint registration token" >&2
    return 1
}

TOKEN="$(mint_token)"
echo "[entrypoint] registration token minted (expires in 1h)"

# Destroy the GitHub identity BEFORE the runner (and any job) exists.
unset GH_TOKEN GH_REPO GH_ORG

CONFIG_ARGS=(
    --unattended
    --url "${RUNNER_URL}"
    --token "${TOKEN}"
    --ephemeral
    --disableupdate
    --work "_work"
)
[ -n "${RUNNER_NAME:-}" ]   && CONFIG_ARGS+=(--name "${RUNNER_NAME}")
[ -n "${RUNNER_LABELS:-}" ] && CONFIG_ARGS+=(--labels "${RUNNER_LABELS}")

./config.sh "${CONFIG_ARGS[@]}"
unset TOKEN RUNNER_URL TOKEN_ENDPOINT CONFIG_ARGS

echo "[entrypoint] starting ephemeral Runner.Listener (PID $$)"
exec ./run.sh