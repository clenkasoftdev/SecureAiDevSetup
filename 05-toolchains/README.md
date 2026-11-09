# Phase 5: Toolchains in the dev container

**Goal:** dev containers for real projects. A ready-made **.NET + Python (uv)** variant, plus recipes for adding .NET, Python + uv, PowerShell and Azure CLI to any repo's container.

**Time:** 30–45 minutes for the .NET + Python variant.
**Run where:** the `dev` distro (`$`), VS Code, and the dev container terminal (`node $`).
**Requires:** phases 3 and 4 complete.

## What's in this phase

```
03-devcontainer/
├─ template/.devcontainer/              base: Claude Code + firewall (phase 3)
├─ toolchains/                          one recipe per toolchain
│  ├─ README.md                         where recipes plug into the template
│  ├─ dotnet.md
│  ├─ python-uv.md
│  ├─ powershell.md
│  └─ azure-cli.md
└─ variants/dotnet-python/.devcontainer/   template + .NET + Python (uv), ready to copy
```

**Variants** are recipes already applied to the template, for combinations you use often. **Recipes** are for anything else: copy the template, and apply the recipes you need.

## Steps (.NET + Python variant)

1. [Pin the images](#step-1-pin-the-images)
2. [Create a test repo](#step-2-create-a-test-repo)
3. [Open it in the container](#step-3-open-it-in-the-container)
4. [Verify .NET](#step-4-verify-net)
5. [Verify Python and uv](#step-5-verify-python-and-uv)
6. [Use it for your repos](#step-6-use-it-for-your-repos)

Problems along the way are covered in [Troubleshooting](#troubleshooting).

---

## Step 1: Pin the images

The variant's `Dockerfile` pins three images by digest. Fill in all three in `03-devcontainer/variants/dotnet-python/.devcontainer/Dockerfile`:

| Placeholder | Get it with |
|---|---|
| `<node-digest>` | The same digest as the template's `FROM` line (phase 3, Step 2) |
| `<dotnet-sdk-digest>` | `docker image inspect mcr.microsoft.com/dotnet/sdk:10.0 --format '{{index .RepoDigests 0}}'` (phase 4) |
| `<uv-version>` and `<uv-digest>` | See below |

For uv:

```bash
$ docker pull ghcr.io/astral-sh/uv:latest
$ docker run --rm ghcr.io/astral-sh/uv:latest --version            # uv 0.x.y
$ docker pull ghcr.io/astral-sh/uv:0.x.y
$ docker image inspect ghcr.io/astral-sh/uv:0.x.y --format '{{index .RepoDigests 0}}'
```

The `FROM` line becomes, for example, `FROM ghcr.io/astral-sh/uv:0.x.y@sha256:… AS uv`.

`CLAUDE_CODE_VERSION` (2.1.319) and `PYTHON_VERSION` (3.13) are set in `devcontainer.json`.

Commit the pinned variant to the runbook repo.

## Step 2: Create a test repo

```bash
$ mkdir -p ~/src/polyglot-test && cd ~/src/polyglot-test
$ git init
$ cp -r ~/src/SecureAiDevSetup/03-devcontainer/variants/dotnet-python/.devcontainer .
$ chmod +x .devcontainer/init-firewall.sh
$ SUB=$(( $(grep "^$USER:" /etc/subuid | cut -d: -f2) + 999 ))
$ setfacl -R -m u:$SUB:rwX,d:u:$SUB:rwX,u:$USER:rwX,d:u:$USER:rwX .
```

## Step 3: Open it in the container

VS Code (**WSL: dev**) → **File → Open Folder** → `~/src/polyglot-test` → **Dev Containers: Reopen in Container**.

The first build takes several minutes: it pulls three images and installs Python. The log ends with **Firewall verification passed**.

```bash
node $ dotnet --version              # 10.0.x
node $ uv --version                  # the pinned uv version
node $ uv python list --only-installed   # cpython-3.13.x
```

> **Checkpoint:** all three print versions.

## Step 4: Verify .NET

```bash
node $ cd /workspace
node $ dotnet new console -n DotnetCheck -o dotnet-check
node $ dotnet add dotnet-check package Humanizer.Core       # NuGet through the firewall
node $ dotnet run --project dotnet-check
```

> **Checkpoint:** the package installs, and the app prints *"Hello, World!"*.

## Step 5: Verify Python and uv

```bash
node $ cd /workspace
node $ uv init python-check && cd python-check
node $ uv add httpx                                      # PyPI through the firewall
node $ uv run python -c "import httpx, sys; print(sys.version.split()[0], httpx.__version__)"
```

> **Checkpoint:** the package installs, and Python prints `3.13.x` and the httpx version.

Then remove the checks:

```bash
node $ cd /workspace && rm -rf dotnet-check python-check
```

## Step 6: Use it for your repos

For a repo that uses .NET and/or Python:

```bash
$ cd ~/src/<repo>
$ cp -r ~/src/SecureAiDevSetup/03-devcontainer/variants/dotnet-python/.devcontainer .
$ chmod +x .devcontainer/init-firewall.sh
$ SUB=$(( $(grep "^$USER:" /etc/subuid | cut -d: -f2) + 999 ))
$ setfacl -R -m u:$SUB:rwX,d:u:$SUB:rwX,u:$USER:rwX,d:u:$USER:rwX .
```

Then:
1. Set `PYTHON_VERSION` in `devcontainer.json` to what the project needs.
2. Add any private feeds or APIs to `allowed-domains.txt`.
3. Commit `.devcontainer/`.
4. **Reopen in Container**.

For other combinations, start from `template/.devcontainer/` and apply the recipes in `03-devcontainer/toolchains/`.

**Keeping it current:** monthly, update the four pins (three images and Claude Code) in the variant and the template, then rebuild your containers.

## Phase 5 done: checklist

| Check | Expected |
|---|---|
| Variant pinned | Three `@sha256:` digests and the uv version filled in |
| Container builds | Log ends with **Firewall verification passed** |
| .NET | `dotnet --version` 10.0.x; NuGet package added |
| Python + uv | Python 3.13 installed at build time; PyPI package added; `uv run` works |
| Recipes | `03-devcontainer/toolchains/` has .NET, Python + uv, PowerShell and Azure CLI |

---

## Troubleshooting

### Build

**`FROM ghcr.io/astral-sh/uv:…` fails with "not found".** The tag needs the exact version without a `v`, for example `0.9.5`, not `v0.9.5`. Check what `uv --version` printed in Step 1.

**`COPY --from=uv /uv /uvx` fails.** The `FROM … AS uv` line is missing or misspelled, or it comes after the main `FROM node…` line. Both toolchain stages must be at the top.

**`uv python install` fails during the build.** The build couldn't reach GitHub, where uv downloads Python from. This happens at build time, outside the firewall, so it's a network problem on the WSL side. Retry the build.

### Python and uv

**`uv` says no matching Python and downloads are disabled.** The project's `requires-python` or `.python-version` asks for a version that isn't installed. Set `PYTHON_VERSION` in `devcontainer.json` to match, then **Rebuild Container**.

**`uv add` fails to connect.** Check `pypi.org` and `files.pythonhosted.org` are in `allowed-domains.txt` and the container was rebuilt. If they are, the CDN moved: run `sudo /usr/local/bin/init-firewall.sh`.

**The Python extension doesn't find the environment.** In the project folder, run `uv sync` (or `uv venv`), then Command Palette → **Python: Select Interpreter** → `.venv/bin/python`.

### .NET

See phase 4's Troubleshooting: ICU, NuGet through the firewall, and the C# extension.
