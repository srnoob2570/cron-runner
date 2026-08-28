#!/bin/sh
# Dispatch one GitHub Actions workflow: dispatch.sh OWNER/REPO WORKFLOW REF
set -eu

REPO="${1:?missing repo argument}"
WORKFLOW="${2:?missing workflow argument}"
REF="${3:-main}"

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

http_code="$(curl -sS -o /tmp/dispatch.out -w '%{http_code}' --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${OWNER}/${NAME}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "{\"ref\":\"${REF}\"}" || echo 000)"

case "$http_code" in
    204) echo "$(date -u +%FT%TZ) dispatch OK ${REPO}/${WORKFLOW}@${REF} (204)" ;;
    *)   echo "$(date -u +%FT%TZ) dispatch FAILED ${REPO}/${WORKFLOW}@${REF} http=${http_code} (retries next cron tick)" ;;
esac