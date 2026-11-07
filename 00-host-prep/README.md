# Phase 0: Prepare the Windows host

**Goal:** make sure the machine itself is trustworthy before anything is installed on it: current firmware, a working TPM, an encrypted disk, and a Windows version that still receives security updates.

**Time:** 2–4 hours, mostly waiting for encryption and the Windows upgrade.
**Run where:** Windows PowerShell, firmware (BIOS/UEFI) setup, Windows Settings.

## Why this phase exists

Phases 1–4 isolate code inside WSL and containers. None of that helps if:
- the disk can be read by whoever holds the laptop, or
- the operating system or firmware no longer receives security fixes.

Do this phase first. The phase 1 backups (`wsl-rescue`) then land on an already-encrypted disk.

## Order matters

```
1. Inventory the host      what machine, edition, Windows version, firmware
2. Firmware (BIOS) update  before encryption: firmware updates are a common BitLocker recovery trigger
3. Enable the TPM          BitLocker needs it to unlock without a boot password
4. BitLocker               encrypt the entire drive
5. Windows upgrade         once encryption has finished
```

## Steps

1. [Inventory the host](#step-1-inventory-the-host)
2. [Update the firmware](#step-2-update-the-firmware)
3. [Enable the TPM](#step-3-enable-the-tpm)
4. [Turn on BitLocker](#step-4-turn-on-bitlocker)
5. [Upgrade Windows to a supported version](#step-5-upgrade-windows-to-a-supported-version)

---

## Step 1: Inventory the host

In an **Administrator** PowerShell window:

```powershell
PS (Admin)> (Get-CimInstance Win32_OperatingSystem).Caption                 # edition
PS (Admin)> (Get-CimInstance Win32_OperatingSystem).BuildNumber             # Windows version
PS (Admin)> Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model
PS (Admin)> (Get-CimInstance Win32_Processor).Name
PS (Admin)> Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion, ReleaseDate
PS (Admin)> Get-Tpm | Select-Object TpmPresent, TpmReady
PS (Admin)> manage-bde -status C:
```

Record the results in your notes **outside this repo**.

What each result decides:

| Result | Meaning | Action |
|---|---|---|
| Edition **Home** | No full BitLocker; only "Device encryption" if the hardware supports it | Use Device encryption, or upgrade to Pro |
| Edition **Pro / Enterprise / Education** | Full BitLocker available | Continue |
| Build **22631** (23H2) or lower | Out of security support (Home/Pro since Nov 2025, Enterprise/Education since Nov 2026) | Upgrade in Step 5 |
| Build **26100** (24H2) / **26200** (25H2) | Supported | Keep it updated |
| `TpmPresent` / `TpmReady` **False** | TPM is disabled in firmware (common) or missing | Step 3 |
| `Protection Status: Protection Off` | Disk is not encrypted | Step 4 |

> **Model lookup:** the `Model` value is the machine type. Search the manufacturer's support site with it. For example, Lenovo type **20L8** is a ThinkPad T480s. The support page lists the BIOS downloads and the end-of-support status.

## Step 2: Update the firmware

Do this **before** BitLocker. Firmware updates change the measurements the TPM checks at boot, which can make BitLocker demand its recovery key.

**2a. Find the latest version.** On the manufacturer's support page for your model, find the BIOS/UEFI download (Lenovo: *"BIOS Update (Utility & Bootable CD) for Windows 11, 10 (64-bit)"*). Compare its version with `SMBIOSBIOSVersion` from Step 1.

- **Same version:** you're current. Skip to Step 3.
- **Newer:** download the **Windows utility** (`.exe`), not the bootable `.iso`.

If the newest BIOS is years old, the manufacturer has stopped issuing firmware fixes for the model. Everything in this runbook still works, but new firmware-level vulnerabilities won't be patched. Plan to replace the machine eventually.

**2b. Verify the download before running it.** Two checks: the hash proves the file wasn't corrupted or swapped; the signature proves who made it.

```powershell
PS> $file = Get-ChildItem "$env:USERPROFILE\Downloads\<installer-name>*.exe" | Select-Object -First 1

# 1. Hash: compare with the SHA-256 shown on the download page
PS> $expected = "<SHA-256 from the vendor page>"
PS> (Get-FileHash $file.FullName -Algorithm SHA256).Hash -eq $expected.Trim().ToUpper()   # must be True

# 2. Signature: must be Valid and signed by the vendor
PS> Get-AuthenticodeSignature $file.FullName |
      Select-Object Status, @{n='Signer';e={$_.SignerCertificate.Subject}}
```

Run the file only if the hash is `True` **and** the signature is `Valid`, with the vendor's name in the signer. The hash and the file come from the same website, so the signature is the stronger check.

**If antivirus blocks the download:** don't disable antivirus. Check Windows Security → Virus & threat protection → **Protection history**. If the blocked file passes both checks above, allow that one file from there.

**2c. Install.**
1. Plug in the charger. Firmware tools refuse to run on battery.
2. Run the utility and let it reboot. Don't interrupt it.
3. Afterwards, re-run the `Win32_BIOS` query from Step 1 to confirm the new version.

## Step 3: Enable the TPM

Windows 11 hardware has a TPM 2.0, but it's often switched off in the firmware.

**3a. Enter firmware setup.** The quick way, from an Administrator window:

```powershell
PS (Admin)> shutdown /r /fw /t 0     # restart now, straight into BIOS/UEFI setup
```

This restarts immediately, so save your work first. If it fails with **error 203** ("could not find the environment option"), the firmware doesn't support this request from Windows. Use the keyboard instead:

1. Choose **Start → Power → Restart**. Use Restart, not Shut down: with Fast Startup, a shut-down machine skips the key prompt.
2. At the manufacturer logo, tap the setup key repeatedly:
   - **Lenovo ThinkPad:** **F1**, or **Enter** then **F1**
   - **Dell:** F2
   - **HP:** F10
   - **Others:** usually F2 or Del

**3b. Enable it.** Common names for the setting:

| Vendor / CPU | Menu path / name |
|---|---|
| Lenovo ThinkPad | **Security → Security Chip → Security Chip: Enabled.** Choose **Discrete TPM** if there's a selection. |
| Intel firmware TPM | "Intel PTT" / "Platform Trust Technology" |
| AMD firmware TPM | "AMD fTPM" / "Firmware TPM" |

Don't use "Clear Security Chip" / "Clear TPM". It isn't needed, and it destroys keys stored in the TPM.

Save and exit (usually **F10**). If the next boot asks to confirm a TPM change, accept it (ThinkPad: **F1**).

**3c. Verify:**

```powershell
PS (Admin)> Get-Tpm | Select-Object TpmPresent, TpmReady
```

> **Checkpoint:** both are `True`. `tpm.msc` shows **"The TPM is ready for use"**, with **Specification Version 2.0**.
>
> If `TpmPresent` is `True` but `TpmReady` is `False`: open `tpm.msc` → **Prepare the TPM…**, then restart.

## Step 4: Turn on BitLocker

**4a. Turn it on.** Control Panel → **BitLocker Drive Encryption** → **Turn on BitLocker** for C:, and choose:

1. **Back up the recovery key** to your Microsoft account **and** to a second place: your password manager, or printed. **Never on C: itself.** Without the key, a BitLocker recovery prompt means the data is gone.
2. **Encrypt entire drive**, not "used disk space only". Data deleted earlier (old distros, old credentials) still sits in free space, and this covers it.
3. **New encryption mode** (XTS-AES).
4. Tick **Run BitLocker system check**, then restart when asked.

The command-line equivalent, in an Administrator window:

```powershell
PS (Admin)> manage-bde -on C: -EncryptionMethod XtsAes256 -RecoveryPassword
```

It prints a 48-digit recovery password. **Store it before restarting.**

**4b. Wait for encryption to finish.** It runs in the background: roughly an hour for a 500 GB SSD. You can work meanwhile.

```powershell
PS (Admin)> manage-bde -status C:
PS (Admin)> manage-bde -protectors -get C:
```

> **Checkpoint:**
> - `Conversion Status: Fully Encrypted`, `Percentage Encrypted: 100,0%`
> - `Protection Status: Protection On`
> - Key protectors: **TPM** and **Numerical Password**, and the Numerical Password matches the recovery key you stored.

## Step 5: Upgrade Windows to a supported version

Start only after Step 4 shows **Fully Encrypted**.

**5a. Prepare:**
- charger plugged in
- at least **30 GB free** (`Get-PSDrive C`)
- recovery key at hand

Windows suspends BitLocker for the upgrade's restarts and resumes it automatically.

**5b. Install the monthly updates first:** Settings → **Windows Update** → **Check for updates**. Install, restart, and repeat until it says **"You're up to date."**

"You're up to date" only means no more monthly updates for your *current* version. It does **not** mean you're on a supported version. Check Step 1's build number.

**5c. Get the feature update (24H2 / 25H2).** Try these in order:

1. **Turn on "Get the latest updates as soon as they're available"** on the Windows Update page, then check again. If **"Feature update to Windows 11, version 25H2"** appears, choose **Download and install**.

2. **Check for a policy pinning the version.** Old tweaks or former management tools can leave one behind:

   ```powershell
   PS> Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue |
         Select-Object TargetReleaseVersion, TargetReleaseVersionInfo, ProductVersion, DeferFeatureUpdatesPeriodInDays
   ```

   No output means no pin. If it shows a pinned version or a deferral, find out where it came from before removing it.

3. **Use the Installation Assistant.** Microsoft rolls feature updates out gradually, so the offer may simply not have reached you yet. Go to [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11) → **Windows 11 Installation Assistant** → **Download Now**. Verify the file with `Get-AuthenticodeSignature`: the signer must be **Microsoft Corporation**. Then run it. It's an in-place upgrade that keeps your files, apps and settings.

Expect 60–90 minutes with several restarts. Don't unplug or close the lid.

**5d. Verify:**

```powershell
PS> winver                                                   # Version 25H2 (build 26200.x) or 24H2 (26100.x)
PS (Admin)> manage-bde -status C:                            # still Protection On
PS> wsl --version                                            # still works
```

Then run **Windows Update** once more for the new version's cumulative updates.

## Phase 0 done: final checklist

| Check | Command / place | Expected |
|---|---|---|
| Edition | `(Get-CimInstance Win32_OperatingSystem).Caption` | Pro, Enterprise or Education |
| Firmware current | `Get-CimInstance Win32_BIOS` vs vendor page | Latest version |
| TPM | `Get-Tpm` | `TpmPresent` and `TpmReady` True |
| Disk encrypted | `manage-bde -status C:` | Fully Encrypted, Protection On |
| Recovery key | Microsoft account + second place | Stored, matches `manage-bde -protectors -get C:` |
| Windows supported | `winver` | 24H2 (26100) or 25H2 (26200), up to date |

**Next:** Phase 1, `01-reset`: back up and remove the old WSL distros.

## Troubleshooting notes

| Symptom | Cause | Fix |
|---|---|---|
| `shutdown /r /fw /t 0` → error **203** | Firmware doesn't expose "boot to setup" to Windows | Restart and press the vendor's setup key (Step 3a) |
| `Get-Tpm` → `False, False` on Windows 11 hardware | TPM disabled in firmware | Step 3b |
| `Get-WindowsOptionalFeature` → **"Class not registered"** ("Klasse nicht registriert") | DISM cmdlets fail in PowerShell 7 | Use `dism.exe`, e.g. `dism /online /get-featureinfo /featurename:VirtualMachinePlatform` |
| `Get-WindowsOptionalFeature` → "Cannot convert System.Object[]…" | `-FeatureName` accepts one name per call | Query one feature at a time, or use `dism` |
| Windows Update "up to date" but still on 23H2 | Feature update not offered (staged rollout, toggle off, or policy) | Step 5c |
| BitLocker asks for the recovery key after a firmware change | TPM measurements changed | Enter the key. Next time, suspend BitLocker first: `manage-bde -protectors -disable C: -RebootCount 1` |