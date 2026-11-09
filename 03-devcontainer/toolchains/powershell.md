# Recipe: PowerShell 7.6 LTS

Installed from Microsoft's package repository for Debian 13, pinned to an exact version.

## Pin

Find the available versions in a throwaway container:

```bash
$ docker run --rm node:24-trixie bash -c '
    apt-get update -qq && apt-get install -y -qq wget >/dev/null &&
    wget -q https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb &&
    dpkg -i packages-microsoft-prod.deb >/dev/null && apt-get update -qq &&
    apt-cache madison powershell | head -5'
```

Pick the newest **7.6.x** line (the LTS release), for example `7.6.6-1.deb`.

## [C] Root install

```dockerfile
# PowerShell, from Microsoft's Debian 13 repository (pinned)
ARG PWSH_VERSION=<version from the pin step, e.g. 7.6.6-1.deb>
RUN curl -fsSL -o /tmp/packages-microsoft-prod.deb https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends "powershell=${PWSH_VERSION}" \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off
```

`packages-microsoft-prod.deb` is Microsoft's documented way to register its repository and signing key.

**Modules:** install the ones you need at build time, in [D], so they don't have to come from the PowerShell Gallery while you work:

```dockerfile
RUN pwsh -NoProfile -Command "Install-PSResource -Name <Module> -Version <x.y.z> -TrustRepository -Scope CurrentUser"
```

## [E] Allowlist

Nothing, if all modules are installed at build time. To install modules while you work, the PowerShell Gallery needs:

```text
www.powershellgallery.com
```

The gallery redirects package downloads to a CDN host. If installs fail, the error names that host: add it as well.

## [F] Editor

```jsonc
"extensions": ["ms-vscode.powershell"]
```

## Verify

```bash
node $ pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'   # 7.6.x
node $ pwsh -NoProfile -Command 'Get-PSResource | Select-Object Name, Version'
```

## Troubleshooting

**`apt-get install powershell=…` says the version isn't found.** Microsoft removed or replaced that build. Repeat the pin step and use a version it lists.

**PowerShell fails to start with an ICU error.** Add `libicu76` to [B]. It usually comes in as a dependency, but the .NET recipe adds it explicitly for the same reason.
