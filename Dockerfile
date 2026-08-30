# cron-runner runner image: GitHub Actions runner with NO docker binaries,
# no socket, no host volumes, no privileged mode.
ARG RUNNER_VERSION=2.337.0
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

USER root

# Deliberately no docker CLI/daemon and no gh.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl unzip jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Strip the docker binaries shipped by the official image.
RUN rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-init /usr/bin/docker-proxy \
    /usr/local/lib/docker/cli-plugins/docker-buildx \
    && rmdir --ignore-fail-on-non-empty /usr/local/lib/docker/cli-plugins /usr/local/lib/docker 2>/dev/null || true

COPY --chmod=0755 runner/entrypoint.sh /usr/local/bin/entrypoint.sh

# Fail the build if docker or gh sneak back in.
RUN ! command -v docker >/dev/null 2>&1 \
    && ! command -v dockerd >/dev/null 2>&1 \
    && ! command -v gh >/dev/null 2>&1 \
    && git --version

USER runner
WORKDIR /home/runner
ENV RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
