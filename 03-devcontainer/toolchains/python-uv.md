# Recipe: Python with uv

uv manages Python versions, virtual environments and packages. Both uv and Python are installed into the image, so nothing is downloaded while you work except packages from PyPI.

## Why Python is installed at build time

uv downloads Python builds from GitHub release assets. Those are served from a CDN that isn't covered by GitHub's published IP ranges, so `uv python install` fails behind the firewall. The recipe installs Python during the build, then tells uv never to download Python again.

## Pin

```bash
$ docker pull ghcr.io/astral-sh/uv:latest
$ docker run --rm ghcr.io/astral-sh/uv:latest --version        # e.g. uv 0.x.y
$ docker pull ghcr.io/astral-sh/uv:<that version>
$ docker image inspect ghcr.io/astral-sh/uv:<that version> --format '{{index .RepoDigests 0}}'
```

Choose the Python version for the project, for example `3.13` or `3.14`.

## [A] Build stage

```dockerfile
# uv, from Astral's official image (pinned)
FROM ghcr.io/astral-sh/uv:<version>@sha256:<digest> AS uv
```

## [C] Root install

```dockerfile
# uv
COPY --from=uv /uv /uvx /usr/local/bin/
```

## [D] User install

```dockerfile
# Python, installed by uv at build time; no Python downloads afterwards
ARG PYTHON_VERSION=3.13
RUN uv python install "$PYTHON_VERSION" && uv python list --only-installed
ENV UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_LINK_MODE=copy \
    PATH=/home/node/.local/bin:$PATH
```

| Setting | Effect |
|---|---|
| `UV_PYTHON_DOWNLOADS=never` | uv uses the installed Python and never tries to fetch another; the attempt would be blocked anyway |
| `UV_PYTHON_PREFERENCE=only-managed` | Ignore any Debian system Python; use the one installed above |
| `UV_LINK_MODE=copy` | The uv cache and `/workspace` are on different filesystems, so hard links fail; copying avoids the warning |

## [E] Allowlist

```text
# PyPI
pypi.org
files.pythonhosted.org
```

Add private indexes too, for example an Azure Artifacts feed at `pkgs.dev.azure.com`.

## [F] Editor

```jsonc
"extensions": ["ms-python.python"]
```

## Verify

```bash
node $ uv --version
node $ uv python list --only-installed           # the version from [D]
node $ cd /tmp && uv init demo && cd demo
node $ uv add requests                           # PyPI through the firewall
node $ uv run python -c "import requests, sys; print(sys.version, requests.__version__)"
```

## Troubleshooting

**`uv` asks to download Python, or fails with "No interpreter found".** The project asks for a Python version that isn't installed, for example through `requires-python` or `.python-version`. Change `PYTHON_VERSION` in [D] to match, then rebuild.

**`uv add` fails with a connection error.** Check `pypi.org` and `files.pythonhosted.org` are in the allowlist and the container was rebuilt. If they are, the CDN moved: `sudo /usr/local/bin/init-firewall.sh`.

**The VS Code Python extension can't find an interpreter.** Run `uv venv` in the project, then Command Palette → **Python: Select Interpreter** → `.venv/bin/python`.
