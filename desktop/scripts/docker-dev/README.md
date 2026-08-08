# Genesis Docker

This directory provides a Docker image and Compose configuration for running a development or test instance of Genesis. BuildKit fetches a tagged Genesis revision from GitHub, the image builds the release on `elixir:otp-29`, and the resulting container serves the dashboard on port `9999`.

Do not use this configuration as a public production deployment. The image includes a shared development `SECRET_KEY_BASE` by default.

## Requirements

- Docker Engine or Docker Desktop
- Docker Compose v2 (`docker compose`)
- An authenticated GitHub CLI (`gh`) session with read access to `EMI-Group/genesis`

## Build the image

Build the image from this directory:

```bash
GIT_AUTH_TOKEN="$(gh auth token)" docker build \
  --secret id=GIT_AUTH_TOKEN \
  --build-arg GENESIS_VERSION=v0.9.2 \
  -t genesis:local .
```

The command obtains the token from the local [GitHub CLI](https://cli.github.com/) session. BuildKit uses `GIT_AUTH_TOKEN` only to fetch the private Git source; the token is not exposed to Dockerfile instructions or stored in the image. If GitHub CLI is unavailable, populate `GIT_AUTH_TOKEN` through your normal secret manager before running the build. Do not pass it as a build argument.

`GENESIS_VERSION` must be a complete Git tag from the [Genesis repository](https://github.com/EMI-Group/genesis/tags), including the `v` prefix. It defaults to `v0.9.2`. BuildKit resolves that tag as a remote Git input and does not copy source files from the local checkout. The repository metadata under `.git` is not included in the image.

The resulting image is named `genesis:local`.

## Included development tools

The image includes language runtimes and native build tools for projects opened in the Genesis workspace:

| Environment | Default | Manager |
|-------------|---------|---------|
| Node.js | Latest LTS | Latest `fnm` available at build time |
| Python | 3.12 | Latest `uv` available at build time |
| Rust | Stable toolchain | `rustup` |
| C/C++ | GCC/G++, Clang/LLVM, LLD, CMake, Ninja, GDB, and pkg-config | Debian packages |

Use build arguments to select different language versions:

```bash
GIT_AUTH_TOKEN="$(gh auth token)" docker build \
  --secret id=GIT_AUTH_TOKEN \
  --build-arg GENESIS_VERSION=v0.9.2 \
  --build-arg NODE_VERSION=22 \
  --build-arg PYTHON_VERSION=3.13 \
  --build-arg RUST_TOOLCHAIN=1.89.0 \
  -t genesis:local .
```

Each image build downloads the latest `fnm` and `uv` releases. Versions installed interactively with `fnm`, `uv`, or `rustup` remain inside that container only; use build arguments when a language version must survive container recreation.

## Start Genesis

Create a directory for the Compose file and persistent data:

```bash
mkdir -p "$HOME/genesis-run/config" \
  "$HOME/genesis-run/data" \
  "$HOME/genesis-run/workspace"

cp desktop/scripts/docker-dev/docker-compose.yaml "$HOME/genesis-run/"
cd "$HOME/genesis-run"
docker compose up -d
```

Open `http://localhost:9999` and follow the setup page to configure an LLM provider.

Check container status and follow the application logs with:

```bash
docker compose ps
docker compose logs -f
```

Stop Genesis with:

```bash
docker compose down
```

## Persistent directories

Paths in the Compose file are relative to the directory containing `docker-compose.yaml`.

| Host directory | Container path | Contents |
|----------------|----------------|----------|
| `./config` | `/app/.config/genesis` | Genesis configuration and credentials |
| `./data` | `/app/.local/share/genesis` | SQLite database, logs, and runtime data |
| `./workspace` | `/app/workspace` | Projects available to Genesis agents |

Do not mount a directory over `/app`. The application source and compiled release are stored under `/app/genesis`. Mounting over the complete directory prevents the container from starting.

## Configuration

The Compose file publishes Genesis as `9999:9999`. The following environment variables can be changed in `docker-compose.yaml`:

- `PORT`: HTTP port inside the container. Update the container side of the port mapping at the same time.
- `PHX_HOST`: Hostname or IP address used to open Genesis. Set this when accessing the dashboard from another machine.
- `SECRET_KEY_BASE`: Overrides the shared development value included in the image.

The Compose file uses `genesis:local`. Change the `image` value if the image is pushed to a registry under another name.

## File permissions

Genesis runs as the non-root `genesis` user with UID/GID `1000:1000`. Its home directory is `/app`.

Docker Desktop normally handles bind-mount permissions automatically. On native Linux, make sure `config`, `data`, and `workspace` are writable by UID/GID `1000:1000` before starting the container.
