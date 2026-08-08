# Genesis Docker

This directory provides a self-contained Docker and Compose configuration for running a development or test instance of Genesis. BuildKit fetches a tagged Genesis revision from GitHub, the image builds the release on `elixir:otp-29`, and the resulting container serves the dashboard on port `9999`.

Do not use this configuration as a public production deployment. The image includes a shared development `SECRET_KEY_BASE` by default.

## Requirements

- Docker Engine or Docker Desktop
- Docker Compose v2 (`docker compose`)
- An authenticated GitHub CLI (`gh`) session with read access to `EMI-Group/genesis`

## Build and start Genesis

Choose a working directory, create the persistent directories, and copy in the Dockerfile and Compose file:

```bash
run_dir="/path/to/your/run-directory"

mkdir -p "${run_dir}"/{config,data,workspace}

cp desktop/scripts/docker-dev/{Dockerfile,docker-compose.yaml} \
  "${run_dir}/"

cd "${run_dir}"
GIT_AUTH_TOKEN="$(gh auth token)" docker compose up --build -d
```

The command obtains the token from the local [GitHub CLI](https://cli.github.com/) session. Compose passes it to BuildKit as the predefined `GIT_AUTH_TOKEN` build secret. The token is used only to fetch the private Git source; it is not exposed to Dockerfile instructions, passed to the running container, or stored in the image. If GitHub CLI is unavailable, populate `GIT_AUTH_TOKEN` through your normal secret manager before building. Do not put the token in `.env` or pass it as a build argument.

`GENESIS_VERSION` must be a complete Git tag from the [Genesis repository](https://github.com/EMI-Group/genesis/tags), including the `v` prefix. It defaults to `v0.9.2`. BuildKit resolves that tag as a remote Git input and does not copy source files from the local checkout. The repository metadata under `.git` is not included in the image.

Compose builds the image as `genesis:local`. Open `http://localhost:9999` and follow the setup page to configure an LLM provider.

Check container status and follow the application logs with:

```bash
docker compose ps
docker compose logs -f
```

Stop Genesis with:

```bash
docker compose down
```

## Included development tools

The image includes language runtimes and native build tools for projects opened in the Genesis workspace:

| Environment | Default | Manager |
|-------------|---------|---------|
| Node.js | Latest LTS | Latest `fnm` available at build time |
| Python | 3.12 | Latest `uv` available at build time |
| Rust | Stable toolchain | `rustup` |
| C/C++ | GCC/G++, Clang/LLVM, LLD, CMake, Ninja, GDB, and pkg-config | Debian packages |

Set environment variables when building to select different source and language versions:

```bash
GIT_AUTH_TOKEN="$(gh auth token)" \
GENESIS_VERSION=v0.9.2 \
NODE_VERSION=22 \
PYTHON_VERSION=3.13 \
RUST_TOOLCHAIN=1.89.0 \
docker compose build
```

Each image build downloads the latest `fnm` and `uv` releases. Versions installed interactively with `fnm`, `uv`, or `rustup` remain inside that container only; use build arguments when a language version must survive container recreation.

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

The Compose file builds and tags the image as `genesis:local`. Change the `image` value if the image should use another local or registry name.

## File permissions

Genesis runs as the non-root `genesis` user with UID/GID `1000:1000`. Its home directory is `/app`.

Docker Desktop normally handles bind-mount permissions automatically. On native Linux, make sure `config`, `data`, and `workspace` are writable by UID/GID `1000:1000` before starting the container.
