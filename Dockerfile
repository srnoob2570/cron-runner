# cronrunner runner image — a GitHub Actions runner with NO Docker inside,
# NO docker socket, NO host volumes, NO privileged mode.
# Jobs run directly in this container (shell + JS actions).
ARG RUNNER_VERSION=2.337.0
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# ----- Optional toolchains (enable at build time) ---------------------------
#   docker build --build-arg BUN_VERSION=1.4.0 --build-arg NODE_VERSION=22 .
# Baked-in toolchains make the matching setup-* actions a cache hit and keep
# jobs fully offline-friendly for those runtimes.
ARG BUN_VERSION=none
ARG NODE_VERSION=none

USER root

# git (checkout/commit/push steps), curl+unzip (toolchain installs), jq (token mint).
# NOTE: deliberately NOT installing docker CLI/daemon or gh — the runner has no
# docker identity and no GitHub identity beyond its short-lived registration token.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl unzip jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Strip ALL docker binaries shipped by the official image (CLI, daemon, helpers,
# buildx plugin): nothing in this container may talk to any docker daemon.
RUN rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-init /usr/bin/docker-proxy \
        /usr/local/lib/docker/cli-plugins/docker-buildx \
    && rmdir --ignore-fail-on-non-empty /usr/local/lib/docker/cli-plugins /usr/local/lib/docker 2>/dev/null || true

# Optional: Bun (pinned)
RUN set -eux; \
    if [ "${BUN_VERSION}" != "none" ]; then \
        arch="$(dpkg --print-architecture)"; \
        case "$arch" in amd64) target=x64;; arm64) target=aarch64;; *) echo "unsupported arch $arch" >&2; exit 1;; esac; \
        curl -fsSL -o /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${target}.zip"; \
        unzip -q /tmp/bun.zip -d /tmp/bun; \
        install -m 0755 "/tmp/bun/bun-linux-${target}/bun" /usr/local/bin/bun; \
        ln -sf bun /usr/local/bin/bunx; \
        rm -rf /tmp/bun /tmp/bun.zip; \
    fi

# Optional: Node.js (pinned, official tarballs)
RUN set -eux; \
    if [ "${NODE_VERSION}" != "none" ]; then \
        arch="$(dpkg --print-architecture)"; \
        case "$arch" in amd64) narch=x64;; arm64) narch=arm64;; *) echo "unsupported arch $arch" >&2; exit 1;; esac; \
        curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.xz"; \
        mkdir -p /usr/local/lib/nodejs; \
        tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs --strip-components=1; \
        ln -sf /usr/local/lib/nodejs/bin/node /usr/local/bin/node; \
        ln -sf /usr/local/lib/nodejs/bin/npm /usr/local/bin/npm; \
        ln -sf /usr/local/lib/nodejs/bin/npx /usr/local/bin/npx; \
        ln -sf /usr/local/lib/nodejs/bin/corepack /usr/local/bin/corepack; \
        rm -f /tmp/node.tar.xz; \
    fi

COPY --chmod=0755 runner/entrypoint.sh /usr/local/bin/entrypoint.sh

# Sanity gates baked into the image: fail the build if docker or gh sneak in.
RUN ! command -v docker >/dev/null 2>&1 \
    && ! command -v dockerd >/dev/null 2>&1 \
    && ! command -v gh >/dev/null 2>&1 \
    && git --version

USER runner
WORKDIR /home/runner
ENV RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]