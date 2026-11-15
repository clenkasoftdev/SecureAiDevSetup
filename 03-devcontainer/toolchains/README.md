# Toolchain recipes

Each recipe adds one toolchain to a repo's copy of the phase 3 template. A recipe changes up to three files, at fixed places:

| Place | File | Where exactly |
|---|---|---|
| **[A] Build stage** | `Dockerfile` | At the very top, **before** `FROM node:24-trixie…` |
| **[B] Debian packages** | `Dockerfile` | Added to the `apt-get install` list |
| **[C] Root install** | `Dockerfile` | Just **before** `COPY init-firewall.sh …` (root is active there) |
| **[D] User install** | `Dockerfile` | At the very end, **after** the last `USER node` |
| **[E] Allowlist** | `allowed-domains.txt` | Appended |
| **[F] Editor and environment** | `devcontainer.json` | `extensions`, `settings`, `containerEnv` |

| Recipe | Adds | Installed from |
|---|---|---|
| [.NET](dotnet.md) | .NET 10 SDK | Microsoft's SDK container image, by digest |
| [Python + uv](python-uv.md) | uv and a Python version | uv's container image, by digest; Python by uv at build time |
| [PowerShell](powershell.md) | PowerShell 7.6 LTS | Microsoft's Debian 13 package repository, pinned version |
| [Azure CLI](azure-cli.md) | `az` | Microsoft's Azure CLI repository (Debian 12 package), pinned version |

## Rules every recipe follows

- **Install at build time.** Image builds run before the firewall exists. Everything a toolchain needs, including language versions, goes into the image.
- **Pin the version.** By digest for images, by exact version for packages.
- **Allow only what the toolchain fetches while you work**, such as package registries, and nothing it only needs during installation. Entries are server names: `host.example.com` for one host, `.example.com` for a domain and all its subdomains. Keep wildcards narrow.
- **No install scripts piped into a shell.**
- **Turn off telemetry and update checks.** They would be blocked anyway, and they slow the tools down while they wait.

Combine recipes freely. If two recipes add to the same place, add both blocks.
