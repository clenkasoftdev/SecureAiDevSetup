# Phase 0: Prepare the Windows host

**Goal:** make sure the machine itself is trustworthy before anything is installed on it: current firmware, a working TPM, an encrypted disk, a supported Windows version, and current Secure Boot certificates.

**Time:** 2 - 4 hours, mostly waiting for encryption and the Windows upgrade.
**Run where:** Windows PowerShell (Administrator), firmware (BIOS/UEFI) setup, Windows Settings.

## Why this phase exists

Phases 1 - 4 isolate code inside WSL and containers. None of that helps if:
- the disk can be read by whoever holds the laptop, or
- the operating system or firmware no longer receives security fixes.

Do this phase first. The phase 1 backups then land on an already-encrypted disk.

## Order

```
1. Inventory the host      edition, Windows version, firmware, TPM, Secure Boot, encryption
2. Firmware (BIOS) update  before encryption: firmware updates change what BitLocker checks at boot
3. Enable the TPM          BitLocker uses it to unlock without a boot password
4. BitLocker               encrypt the entire drive
5. Windows upgrade         after encryption has finished; Secure Boot certificates follow
```

Problems along the way are covered in [Troubleshooting](#troubleshooting).

---

## Step 1: Inventory the host

```powershell
PS (Admin)> (Get-CimInstance Win32_OperatingSystem).Caption
PS (Admin)> (Get-CimInstance Win32_OperatingSystem).BuildNumber
PS (Admin)> Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model
PS (Admin)> (Get-CimInstance Win32_Processor).Name
PS (Admin)> Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion, ReleaseDate
PS (Admin)> Get-Tpm | Select-Object TpmPresent, TpmReady
PS (Admin)> Confirm-SecureBootUEFI
PS (Admin)> manage-bde -status C:
```

Also note the date of the last **quality update** in Settings → Windows Update → **Update history**.

Record the results in your notes outside this repo. What they decide:

| Result | Action |
|---|---|
| Edition **Pro / Enterprise / Education** | Continue |
| Build **26100** (24H2), **26200** (25H2) or **26300** (26H2) | Supported: skip the upgrade part of Step 5 |
| Build **22631** (23H2) or lower, or last quality update months ago | Out of support: upgrade in Step 5 |
| `TpmPresent` / `TpmReady` False | Step 3 |
| `Confirm-SecureBootUEFI` False | Enable Secure Boot in firmware during Step 3 |
| `Protection Status: Protection Off` | Step 4 |

The `Model` value is the machine type. Use it on the manufacturer's support site to find the BIOS downloads. For example, Lenovo type 20L8 is a ThinkPad T480s.

## Step 2: Update the firmware

1. On the manufacturer's support page for your model, open the BIOS/UEFI download (Lenovo: *"BIOS Update (Utility & Bootable CD) for Windows 11, 10 (64-bit)"*), and compare its version with `SMBIOSBIOSVersion`. If they match, go to Step 3.
2. Download the Windows utility (`.exe`) and verify it. The signature is the stronger check: the hash comes from the same website as the file.

   ```powershell
   PS> $file = Get-ChildItem "$env:USERPROFILE\Downloads\<installer-name>*.exe" | Select-Object -First 1
   PS> (Get-FileHash $file.FullName -Algorithm SHA256).Hash -eq "<SHA-256 from the vendor page>".ToUpper()
   PS> Get-AuthenticodeSignature $file.FullName | Select-Object Status, @{n='Signer';e={$_.SignerCertificate.Subject}}
   ```

   Expect `True`, then `Valid` with the vendor in the signer.
3. With the charger plugged in, run the utility and let it reboot.
4. Re-run the `Win32_BIOS` query to confirm the new version.

## Step 3: Enable the TPM

1. Restart into firmware setup:
   ```powershell
   PS (Admin)> shutdown /r /fw /t 0
   ```
2. Enable the TPM. The menu name depends on the vendor:

   | Vendor / CPU | Setting |
   |---|---|
   | Lenovo ThinkPad | **Security → Security Chip → Security Chip: Enabled** (Discrete TPM) |
   | Intel firmware TPM | Intel PTT / Platform Trust Technology |
   | AMD firmware TPM | AMD fTPM / Firmware TPM |

   Leave "Clear Security Chip" / "Clear TPM" alone.
3. Save and exit with **F10**. If the next boot asks you to confirm a TPM change, accept it.
4. Verify:
   ```powershell
   PS (Admin)> Get-Tpm | Select-Object TpmPresent, TpmReady
   ```

> **Checkpoint:** both `True`. `tpm.msc` shows "The TPM is ready for use", with Specification Version 2.0.

## Step 4: Turn on BitLocker

1. Control Panel → **BitLocker Drive Encryption** → **Turn on BitLocker** for C:
2. Back up the recovery key to your **Microsoft account and** a second place (password manager or printed), **never on C:**.
3. Choose **Encrypt entire drive**. Previously deleted data, such as old distros and credentials, still sits in free space, and this covers it.
4. Choose **New encryption mode** (XTS-AES).
5. Tick **Run BitLocker system check**, then restart.

Encryption runs in the background (about an hour for 500 GB). Verify when it finishes:

```powershell
PS (Admin)> manage-bde -status C:
PS (Admin)> manage-bde -protectors -get C:
```

> **Checkpoint:** `Fully Encrypted`, `100,0%`, `Protection On`. The key protectors are **TPM** and **Numerical Password**, and the password matches the key you stored.

## Step 5: Upgrade Windows and update Secure Boot certificates

**5a. Upgrade.** Make sure you have:
- the charger plugged in
- at least **40 GB free on C:** (`Get-PSDrive C`). Setup builds the new Windows on C: itself.

Then:
1. Install all pending monthly updates: Settings → **Windows Update** → **Check for updates**, until it says "You're up to date".
2. Turn on **"Get the latest updates as soon as they're available"**, check again, and install **"Feature update to Windows 11"** when it appears.
3. If no feature update is offered, use the [Windows 11 Installation Assistant](https://www.microsoft.com/software-download/windows11). It upgrades in place to the newest release and keeps your files, apps and settings.

Allow 60–90 minutes, with several restarts.

**5b. Verify and update:**

```powershell
PS> winver                           # 24H2 (26100.x), 25H2 (26200.x) or 26H2 (26300.x)
PS (Admin)> manage-bde -status C:    # Protection On
PS> wsl --version                    # still works
```

Run **Windows Update** again until it says you're up to date.

**5c. Secure Boot 2023 certificates.** Microsoft's original 2011 Secure Boot certificates expired in 2026. Windows Update installs the 2023 replacements on supported versions, usually with the first cumulative updates after the upgrade. BitLocker may ask for the recovery key once when this applies.

```powershell
PS (Admin)> [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'
PS (Admin)> Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' | Select-Object UEFICA2023Status, UEFICA2023Error
```

> **Checkpoint:** `True`, and status **Updated**. The error value is `0` or empty: Windows only writes it on failure.

**5d. Clean up.** After a few days without problems, remove **Previous Windows installation(s)** under Settings → System → Storage → Temporary files. That frees 20 GB+, and ends the 10-day rollback option.

## Phase 0 done: checklist

| Check | Expected |
|---|---|
| Edition | Pro, Enterprise or Education |
| Firmware | Latest version from the vendor |
| TPM | `TpmPresent` and `TpmReady` True |
| Secure Boot | `Confirm-SecureBootUEFI` True |
| BitLocker | Fully Encrypted, Protection On, recovery key stored in two places |
| Windows | 24H2 / 25H2 / 26H2, up to date |
| Secure Boot certificates | 2023 CA in db, status Updated |

**Next:** Phase 1, `01-reset`.

---

## Troubleshooting

### Firmware and TPM

**`shutdown /r /fw /t 0` fails with error 203** ("could not find the environment option"). The firmware doesn't accept boot-to-setup requests from Windows. Use **Start → Power → Restart** instead (not Shut down: Fast Startup skips the key prompt), and tap the setup key at the logo:
- Lenovo ThinkPad: **F1**, or **Enter** then **F1**
- Dell: **F2**
- HP: **F10**
- Others: usually **F2** or **Del**

**`Get-Tpm` shows `TpmPresent: True` but `TpmReady: False`.** Open `tpm.msc` → **Prepare the TPM…**, then restart.

**Antivirus blocks the BIOS download.** Check Windows Security → Virus & threat protection → **Protection history**. If the file passes the hash and signature checks in Step 2, allow that one file from there. Don't disable antivirus.

**The newest BIOS is years old.** The vendor has stopped issuing firmware fixes for the model. The runbook still works, but plan to replace the machine eventually.

### Edition

**Windows Home.** Full BitLocker isn't available. Use Settings → Privacy & security → **Device encryption** if it's offered, or upgrade to Pro.

### Windows upgrade

**"You're up to date", but still on 23H2.** That message only covers monthly updates for your current version. If the feature update isn't offered even with the "latest updates" toggle on, check for a policy pinning the version:

```powershell
PS> Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue | Select-Object TargetReleaseVersion, TargetReleaseVersionInfo, ProductVersion, DeferFeatureUpdatesPeriodInDays
```

No output means no pin: use the Installation Assistant. If a version is pinned, find out where the setting came from before removing it.

**The upgrade ran, but `winver` shows the old version and Update history has no error.** Setup failed and rolled back. Read its log:

```powershell
PS (Admin)> Get-Content 'C:\$WINDOWS.~BT\Sources\Panther\setuperr.log' -Tail 30
```

Look at the last error before *"Execution phase … exiting"*. Earlier errors about dynamic update downloads, Bluetooth migration or file compression are normal.

| Code | Cause | Fix |
|---|---|---|
| `0x80070070` / `ERROR_DISK_FULL` | Not enough space on C: | Free space (see below), clean up, retry |
| `0xC1900107` | A previous attempt is pending cleanup | Restart, clean up, retry |
| Other | | Run Microsoft's [SetupDiag](https://learn.microsoft.com/windows/deployment/upgrade/setupdiag) and read `SetupDiagResults.log` |

To clean up before retrying: Settings → System → Storage → Temporary files → **Temporary Windows installation files** and **Windows Setup temporary files** → **Remove files**. Don't delete `C:\$WINDOWS.~BT` by hand.

**Not enough space on C:.** The installer's own estimate can be too low. On the reference machine it asked for 10 GB and failed with 23 GB free.
- An SD card or USB drive offered as extra space doesn't solve it: the new Windows is built on C:.
- Free space on C: instead. Doing phase 1 Steps 1–6 first (removing old WSL distros and Docker Desktop) usually frees the most. Settings → System → Storage → **Cleanup recommendations** helps too.
- If you did use an SD card or USB drive during setup, format it afterwards: it holds unencrypted setup files.

**The Installation Assistant keeps failing.** Use the ISO from the same page: **Download Windows 11 Disk Image (ISO) for x64 devices**. Check its SHA-256 against Microsoft's published list, mount it, run `setup.exe`, and choose **"Keep personal files and apps"**.

### Secure Boot certificates

**The `Windows UEFI CA 2023` check stays `False` after a few days of updates.** Trigger the update manually (Microsoft KB5068202):

```powershell
PS (Admin)> manage-bde -protectors -disable C: -RebootCount 3
PS (Admin)> reg add HKLM\SYSTEM\CurrentControlSet\Control\Secureboot /v AvailableUpdates /t REG_DWORD /d 0x5944 /f
PS (Admin)> Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"
PS (Admin)> Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' -Name AvailableUpdates
```

When `AvailableUpdates` reads `0x4100` (16640), restart. Run the task again, then restart once more, and re-check 5c. The first command only pauses BitLocker's boot check for 3 restarts; the disk stays encrypted.

This isn't a blocker for phases 1–4.

**`UEFICA2023Error` is non-zero.** Check Event Viewer → Windows Logs → System, source **TPM-WMI**. On out-of-support models, the KEK step can fail for lack of a vendor-signed key, while the database update still succeeds.

### PowerShell

| Message | Cause | Fix |
|---|---|---|
| *"A positional parameter cannot be found that accepts argument…"* | A pipe `\|` was lost when copying | Copy the whole line, including `\|` |
| `Get-WindowsOptionalFeature`: *"Class not registered"* ("Klasse nicht registriert") | DISM cmdlets fail in PowerShell 7 | Use `dism.exe`, e.g. `dism /online /get-featureinfo /featurename:VirtualMachinePlatform` |
| `Get-WindowsOptionalFeature`: *"Cannot convert System.Object[]…"* | `-FeatureName` takes one name per call | Query one feature at a time |
| BitLocker asks for the recovery key after a firmware or Secure Boot change | TPM measurements changed | Enter the key. Before planned firmware changes: `manage-bde -protectors -disable C: -RebootCount 1` |
