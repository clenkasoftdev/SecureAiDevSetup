# Recipe: Azure CLI

## Debian 13 isn't supported yet

Microsoft's Azure CLI repository has packages for Debian 11 and 12 and Ubuntu, not yet for Debian 13 (trixie). Its installation guide says to use the package of an earlier release in that case. The recipe uses the **Debian 12 (bookworm)** package. It bundles its own Python, so it runs on Debian 13. Switch `AZ_DIST` to `trixie` once Microsoft publishes it.

## Pin

```bash
$ docker run --rm node:24-trixie bash -c '
    apt-get update -qq && apt-get install -y -qq curl gnupg >/dev/null &&
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg &&
    echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main" > /etc/apt/sources.list.d/azure-cli.list &&
    apt-get update -qq && apt-cache madison azure-cli | head -5'
```

Pick the newest version, for example `2.xx.0-1~bookworm`.

## [C] Root install

```dockerfile
# Azure CLI, from Microsoft's repository (Debian 12 package; pinned)
ARG AZ_DIST=bookworm
ARG AZ_VERSION=<version from the pin step, e.g. 2.xx.0-1~bookworm>
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && gpg --show-keys --with-colons /etc/apt/keyrings/microsoft.gpg | grep -q '^fpr:::::::::BC528686B50D79E339D3721CEB3E94ADBE1229CF:' \
    && chmod go+r /etc/apt/keyrings/microsoft.gpg \
    && printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-by: /etc/apt/keyrings/microsoft.gpg\n' \
         "$AZ_DIST" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/azure-cli.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends "azure-cli=${AZ_VERSION}" \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV AZURE_CORE_COLLECT_TELEMETRY=false
```

The `grep` line stops the build unless the downloaded key has Microsoft's published fingerprint `BC52 8686 B50D 79E3 39D3 721C EB3E 94AD BE12 29CF`.

## [E] Allowlist

Sign-in and Azure Resource Manager:

```text
# Azure sign-in and management
login.microsoftonline.com
management.azure.com
graph.microsoft.com
```

Add the endpoints of the services you work with, for example `<vault>.vault.azure.net` or `<account>.blob.core.windows.net`. List each host: wildcards aren't supported.

## [F] Editor

Optional:

```jsonc
"extensions": ["ms-vscode.azurecli"]
```

## Sign in

Use the device code flow: the browser runs on Windows, and the CLI runs in the container.

```bash
node $ az login --use-device-code
```

Open the URL shown, in your Windows browser, and enter the code.

The token is stored in `~/.azure` inside the container, and it's gone after a rebuild.

**Security:** while you're signed in, anything in the container, including the agent, can use that identity against the allowed Azure endpoints. Sign in with an identity that has only the permissions this repo needs. Sign out (`az logout`) before running the agent unattended, unless the task needs Azure.

## Verify

```bash
node $ az version --output table
node $ az login --use-device-code
node $ az account show --output table
```

## Troubleshooting

**The build fails at the `grep` line.** The downloaded key doesn't match Microsoft's fingerprint. Don't bypass it: check the key URL, and Microsoft's documentation for a key change.

**`az login` hangs or fails to connect.** Its host isn't allowed. The error names it: often a tenant-specific `login.microsoftonline.com` path, which is covered, or `aadcdn.msftauth.net` for sign-in assets. Add it and rebuild.

**`apt-get install azure-cli=…` says the version isn't found.** Repeat the pin step and use a listed version.
