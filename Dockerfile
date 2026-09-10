# cron-runner runner image: GitHub Actions runner with NO docker binaries,
# no socket, no host volumes, no privileged mode.
ARG RUNNER_VERSION=2.337.0
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

USER root

# Deliberately no docker CLI/daemon and no gh.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl unzip jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Tauri release toolchain (termcard). The runner is dockerless and
# non-root with no sudo, so apt packages a workflow would install can
# only come from here. Bun itself rides in per-run via setup-bun into
# RUNNER_TOOL_CACHE (persisted on the cache mount by compose).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential file wget rpm \
        libwebkit2gtk-4.1-dev libxdo-dev libssl-dev \
        libayatana-appindicator3-dev librsvg2-dev \
    && rm -rf /var/lib/apt/lists/*

# Rust via rustup, minimal profile. RUSTUP_HOME stays in the image;
# compose redirects CARGO_HOME at runtime to the cache mount so the
# registry cache survives recreations.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:${PATH}
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
    && rustc --version

# Strip the docker binaries shipped by the official image.
RUN rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-init /usr/bin/docker-proxy \
    /usr/local/lib/docker/cli-plugins/docker-buildx \
    && rmdir --ignore-fail-on-non-empty /usr/local/lib/docker/cli-plugins /usr/local/lib/docker 2>/dev/null || true

COPY --chmod=0755 runner/entrypoint.sh /usr/local/bin/entrypoint.sh

# Seed the cache mount point with runner ownership: a named volume
# copies the image dir on first use, so no host-side chown is needed.
RUN mkdir -p /home/runner/.cache && chown runner:runner /home/runner/.cache

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
