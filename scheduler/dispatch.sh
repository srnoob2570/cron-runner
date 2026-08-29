#!/bin/sh
# Dispatch one GitHub Actions workflow: dispatch.sh WORKFLOW [REF]
# Repo comes from GH_REPO, auth from GH_TOKEN; both inherited from the
# service environment. A failed dispatch (network blip, rate limit) is
# logged with GitHub's response and retried on the next cron tick.
set -eu

WORKFLOW="${1:?missing workflow argument, e.g. update.yml}"
REF="${2:-main}"
: "${GH_REPO:?GH_REPO not set}"
: "${GH_TOKEN:?GH_TOKEN not set}"

case "$WORKFLOW" in
    */*) echo "FATAL: '${WORKFLOW}' looks like a repo — old syntax dispatch.sh OWNER/REPO WORKFLOW REF is gone. Use dispatch.sh WORKFLOW [REF]; the repo comes from GH_REPO." >&2; exit 1 ;;
esac

http_code="$(curl -sS -o /tmp/dispatch.out -w '%{http_code}' --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${GH_REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "{\"ref\":\"${REF}\"}")" || http_code=000

case "$http_code" in
    204) echo "$(date -u +%FT%TZ) dispatch OK ${GH_REPO}/${WORKFLOW}@${REF} (204)" ;;
    *)   echo "$(date -u +%FT%TZ) dispatch FAILED ${GH_REPO}/${WORKFLOW}@${REF} http=${http_code} body=$(head -c 300 /tmp/dispatch.out 2>/dev/null | tr '\n' ' ') (retries next cron tick)" ;;
esac