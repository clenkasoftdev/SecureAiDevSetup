# Recipe: Azure DevOps (Git over HTTPS with Entra tokens)

**Requires:** the [Azure CLI recipe](azure-cli.md) in the same image.

Git authenticates to Azure Repos with a **short-lived Microsoft Entra access token** from the Azure CLI, not with a personal access token (PAT) or an SSH key.

## Design

```
git push ─► git-credential-azdo ─► az account get-access-token (Azure DevOps audience)
                                     │ short-lived token, refreshed by az from your sign-in
                                     ▼
                          https://dev.azure.com/<org>/…   (through the SNI filter, port 443)
```

| Decision | Why |
|---|---|
| **HTTPS, not SSH** | Azure DevOps accepts only RSA keys for SSH, and SSH needs port 22, which the firewall allows only to GitHub. HTTPS goes through the name filter like everything else. |
| **Entra token, not a PAT** | Microsoft is retiring global PATs (they stop working on 27 January 2027) and recommends short-lived Entra authentication. A token from `az` lasts about an hour, and nothing long-lived sits in the container. |
| **Small helper script, not Git Credential Manager** | No extra runtime, no credential store to configure in a container. The helper answers only for Azure DevOps hosts, and only with what `az` provides. |
| **Sign-in per container** | Each repo's container signs in separately, with the identity for that organization: yours for Clenkasoft, a guest account for a client's tenant. The sign-in is gone after a rebuild. |

## Files

Copy the helper next to the repo's `Dockerfile`:

```bash
$ cp ~/src/SecureAiDevSetup/03-devcontainer/toolchains/git-credential-azdo <repo>/.devcontainer/
```

## [C] Root install

After the Azure CLI recipe's block:

```dockerfile
# Azure DevOps: Git credentials from short-lived Entra tokens (no PAT)
COPY git-credential-azdo /usr/local/bin/git-credential-azdo
RUN chmod 0755 /usr/local/bin/git-credential-azdo \
    && git config --system credential.https://dev.azure.com.helper /usr/local/bin/git-credential-azdo \
    && git config --system credential.https://dev.azure.com.useHttpPath true
```

## [D] User install (optional)

The `azure-devops` extension for `az`, for pull requests, pipelines and work items from the terminal (`az repos pr create`, …). Pin the version:

```dockerfile
ARG AZ_DEVOPS_EXT_VERSION=<version>
RUN az extension add --name azure-devops --version "$AZ_DEVOPS_EXT_VERSION" --yes
```

To find the current version, build without the `--version` part once, then run `az extension show --name azure-devops --query version` in the container.

## [E] Allowlist

Add these to the Azure CLI recipe's entries:

```text
# Azure DevOps
dev.azure.com
vssps.dev.azure.com
.visualstudio.com
```

`.visualstudio.com` covers older organization URLs (`<org>.visualstudio.com`) and Azure DevOps's own download hosts.

For **Azure Artifacts** feeds (private NuGet, PyPI or npm), also add:

```text
pkgs.dev.azure.com
```

The SNI filter sees `dev.azure.com`, not which organization a request goes to: that's in the URL path, inside the encrypted connection. So the boundary between organizations is the **sign-in**, not the allowlist. A container signed in to one tenant can only act in that tenant.

## Sign in and use

```bash
node $ az login --use-device-code --allow-no-subscriptions --tenant <tenant-id-or-domain>
node $ git clone https://dev.azure.com/<org>/<project>/_git/<repo>
```

- `--tenant` picks the right directory: your own (for example `clenkasoft.com`), or the client's tenant when you're their guest.
- `--allow-no-subscriptions` lets you sign in when the account has Azure DevOps access but no Azure subscription.

Set the default organization for the `az devops` extension:

```bash
node $ az devops configure --defaults organization=https://dev.azure.com/<org> project=<project>
```

## Verify

```bash
node $ az account show --query user.name --output tsv              # the identity you expect
node $ git ls-remote https://dev.azure.com/<org>/<project>/_git/<repo> | head -3
node $ printf 'protocol=https\nhost=dev.azure.com\n\n' | git credential fill | grep -c password=   # 1
```

> **Checkpoint:** `git ls-remote` lists the repo's branches without asking for a password.

## Clients

Use the same recipe in each client repo's container, with:
- their organization URL
- their tenant in `az login --tenant …`
- only the hosts they need in that repo's allowlist

Never sign in to two tenants in the same container.

## Troubleshooting

**Git asks for a username or password.** The helper isn't configured, or `az` isn't signed in.
- Check the helper: `git config --system --get credential.https://dev.azure.com.helper`.
- Check the sign-in: `az account show`. Then run `az login --use-device-code` again.

**`TF400813: The user … is not authorized` or HTTP 401.** You're signed in with an identity that has no access to that organization, or to the wrong tenant. Check `az account show --query tenantId`, and sign in again with `--tenant`.

**`az login` reports that device code sign-in is blocked.** The tenant's Conditional Access policy forbids the device code flow. Common in client tenants. Ask the tenant admin, or sign in through the browser instead: `az login`, then open the forwarded port VS Code offers.

**Push fails after about an hour.** The token expired and `az` couldn't refresh it, for example because the session was revoked. Run `az login --use-device-code` again.

**Requests are refused by the proxy.** `grep 'allowed=0' /var/log/egress-proxy/access.log | tail` names the host. Add it and rebuild.
