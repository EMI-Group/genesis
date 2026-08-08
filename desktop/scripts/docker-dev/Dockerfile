# Genesis Docker (dev/test only) — mix release, foreground logs on stdout.
#
# Build from this directory:
#   docker build --build-arg GENESIS_VERSION=v0.9.2 -t genesis:local .
#
# The image runs as the non-root genesis account by default.

FROM elixir:otp-29

ARG GENESIS_VERSION=v0.9.2
ARG NODE_VERSION=lts-latest
ARG PYTHON_VERSION=3.12
ARG RUST_TOOLCHAIN=stable

LABEL org.opencontainers.image.source="https://github.com/EMI-Group/genesis" \
      org.opencontainers.image.version="${GENESIS_VERSION}"

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    HOME=/app \
    FNM_DIR=/app/.local/share/fnm \
    CARGO_HOME=/app/.cargo \
    RUSTUP_HOME=/app/.rustup \
    UV_PYTHON_INSTALL_DIR=/app/.local/share/uv/python \
    PATH=/app/.local/share/fnm/aliases/default/bin:/app/.local/bin:/app/.cargo/bin:${PATH} \
    PORT=9999 \
    PHX_SERVER=true \
    PHX_HOST=localhost \
    SECRET_KEY_BASE=GenesisDockerLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        coreutils \
        curl \
        gdb \
        git \
        jq \
        lld \
        llvm \
        ninja-build \
        pkg-config \
        ripgrep \
        unzip \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 genesis \
    && useradd --no-log-init --uid 1000 --gid genesis --no-create-home \
        --home-dir "${HOME}" --shell /bin/bash genesis \
    && install -d -o genesis -g genesis \
        /app \
        "${HOME}/.config/genesis" \
        "${HOME}/.local/bin" \
        "${HOME}/.local/share/genesis" \
        "${FNM_DIR}" \
        "${UV_PYTHON_INSTALL_DIR}" \
        "${HOME}/workspace" \
    && chown -R genesis:genesis "${HOME}"

WORKDIR /app
USER genesis:genesis
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN curl -fsSL https://fnm.vercel.app/install \
        | bash -s -- --install-dir "${HOME}/.local/bin" --skip-shell \
    && fnm install "${NODE_VERSION}" --progress never \
    && fnm default "${NODE_VERSION}" \
    && node --version

RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_UNMANAGED_INSTALL="${HOME}/.local/bin" sh \
    && uv python install "${PYTHON_VERSION}" --default \
    && python --version

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile default --default-toolchain "${RUST_TOOLCHAIN}" \
    && rustc --version

RUN git clone \
        --branch "${GENESIS_VERSION}" \
        --depth 1 \
        --single-branch \
        https://github.com/EMI-Group/genesis.git \
        /app/genesis

WORKDIR /app/genesis

RUN mix local.hex --force \
    && mix local.rebar --force \
    && mix deps.get --only prod \
    && mix assets.setup \
    && mix assets.deploy \
    && mix release genesis

WORKDIR /app/workspace

EXPOSE 9999

HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
    CMD curl --fail --silent --show-error "http://127.0.0.1:${PORT:-9999}/" >/dev/null || exit 1

CMD ["/app/genesis/_build/prod/rel/genesis/bin/genesis", "start"]
