---
name: secure-disk-wipe
description: Safely identify and irreversibly overwrite a user-selected external physical disk on macOS. Use only for explicit disk-erasure requests; locate the current device, show identity details, require two confirmations, and run the bundled overwrite script with a live Unicode progress bar and percentage.
---

# Secure Disk Wipe

This skill is for an explicitly requested destructive erase of an external physical disk on macOS. It is not a general formatting skill. Do not start a wipe from a vague request such as “clean this up”; first establish which disk the user means.

The executable helper is `scripts/secure_wipe_macos.sh`. It is intentionally generic rather than Toshiba-specific.

## Required workflow

1. Identify the target using the strongest available identity: an exact `/Volumes/...` path, exact media/volume name, or a user-provided current `/dev/diskN` plus `TARGET_NAME`. Never trust a stale `/dev/diskN` by itself; macOS can renumber disks after reconnecting them.
2. Before any destructive action, run the helper in inventory mode:

   ```bash
   bash /path/to/secure-disk-wipe/scripts/secure_wipe_macos.sh --list
   ```

   Only external physical disks are candidates. If the name matches zero disks or multiple disks, stop and resolve the ambiguity.
3. Run the helper with the selected target. The helper re-resolves the current device, checks that it is external and physical, and prints the device, raw device, media name, volume name, capacity, protocol, location, SMART status, and solid-state status before asking for confirmation.
4. Make the user verify that preflight summary. The helper then requires both exact confirmations immediately before unmounting and writing: `ERASE /dev/diskN` and `I UNDERSTAND`. Do not bypass, pre-fill, or weaken either confirmation.
5. Run long wipes under `caffeinate -dimsu` so system sleep does not interrupt them. The default is one `/dev/urandom` pass. For an ordinary HDD, one full pass is generally the practical default; do not claim that three passes are required.
6. The helper draws the live Unicode bar, percentage, and bytes written. Preserve that output when giving the user the script or running it. A completed 100.00% bar is not enough by itself: success also requires the script’s final “擦除完成” message.
7. If the device disappears or `dd` reports `Device not configured`, an I/O error, or any other write failure, stop. Report the actual bytes/percentage reached and state that the entire disk was not confirmed erased. Do not automatically retry, switch disks, or claim success.
8. SSD/flash media is blocked by default because ordinary overwrite cannot guarantee removal of data from remapped flash blocks. If the device reports `Solid State: Yes`, recommend the manufacturer Secure Erase/Sanitize workflow. Continue only if the user explicitly accepts that limitation and sets `ALLOW_SSD=1`; retain both confirmations and the warning.
9. Formatting is separate. Do not run `diskutil eraseDisk` after wiping unless the user explicitly asks to format the now-empty disk.

## Invocation examples

For a mounted volume:

```bash
caffeinate -dimsu sudo bash scripts/secure_wipe_macos.sh "/Volumes/TOSHIBA External USB 3.0 Media"
```

For an exact media name:

```bash
caffeinate -dimsu sudo env TARGET_NAME='External USB 3.0' bash scripts/secure_wipe_macos.sh
```

For a current device number, always pair it with the current exact media name:

```bash
caffeinate -dimsu sudo env TARGET_NAME='External USB 3.0' bash scripts/secure_wipe_macos.sh /dev/disk4
```

Do not hard-code `/dev/disk4` or any other disk number into a reusable instruction. Obtain it from the current inventory immediately before running the helper.

## Output handling

When the user asks for “the script”, provide or copy the bundled helper as an executable artifact and link to it; do not paste the entire source unless they ask for the code. When the user asks to execute the wipe, use the helper after the inventory and confirmations, and return the final result with the exact target and completion/failure status.
