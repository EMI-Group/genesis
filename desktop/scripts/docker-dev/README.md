# Genesis Docker

This directory provides a Docker image and Compose configuration for running a development or test instance of Genesis. The image builds the Genesis release from source on `elixir:otp-29` and serves the dashboard on port `9999`.

Do not use this configuration as a public production deployment. The image includes a shared development `SECRET_KEY_BASE` by default.

## Requirements

- Docker Engine or Docker Desktop
- Docker Compose v2 (`docker compose`)

## Build the image

Run the build from the Genesis repository root so Docker can access the complete source tree:

```bash
docker build -f desktop/scripts/docker-dev/Dockerfile -t genesis:local .
```

The resulting image is named `genesis:local`. `desktop/scripts/docker-dev/Dockerfile.dockerignore` excludes local build outputs, dependencies, editor files, and runtime data from the build context.

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
docker build \
  --build-arg NODE_VERSION=22 \
  --build-arg PYTHON_VERSION=3.13 \
  --build-arg RUST_TOOLCHAIN=1.89.0 \
  -f desktop/scripts/docker-dev/Dockerfile \
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

Do not mount a directory over `/app`. The application source and compiled release are stored there. Mounting over the complete directory prevents the container from starting.

## Configuration

The Compose file publishes Genesis as `9999:9999`. The following environment variables can be changed in `docker-compose.yaml`:

- `PORT`: HTTP port inside the container. Update the container side of the port mapping at the same time.
- `PHX_HOST`: Hostname or IP address used to open Genesis. Set this when accessing the dashboard from another machine.
- `SECRET_KEY_BASE`: Overrides the shared development value included in the image.

The Compose file uses `genesis:local`. Change the `image` value if the image is pushed to a registry under another name.

## File permissions

Genesis runs as the non-root `genesis` user with UID/GID `1000:1000`. Its home directory is `/app`.

Docker Desktop normally handles bind-mount permissions automatically. On native Linux, make sure `config`, `data`, and `workspace` are writable by UID/GID `1000:1000` before starting the container.
