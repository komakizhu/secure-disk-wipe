# Secure Disk Wipe

A macOS Codex Skill and standalone Bash helper for safely identifying and irreversibly overwriting an external physical disk.

## Features

- Lists and re-resolves external physical disks instead of trusting stale `/dev/diskN` numbers.
- Matches an exact volume path, media name, or volume name.
- Shows the target device, raw device, media/volume names, capacity, protocol, location, SMART status, and solid-state status.
- Requires two typed confirmations immediately before unmounting and writing.
- Displays a live Unicode progress bar, percentage, and bytes written.
- Blocks SSD/flash media by default because ordinary overwrite cannot guarantee removal from remapped flash blocks.
- Stops on device disappearance or I/O errors and reports that the full disk was not confirmed erased.

## Install as a Codex Skill

Copy this repository to the local Codex skills directory as `secure-disk-wipe`. The Skill instructions are in [`SKILL.md`](SKILL.md), and the executable helper is [`scripts/secure_wipe_macos.sh`](scripts/secure_wipe_macos.sh).

## Read-only inventory

```bash
bash scripts/secure_wipe_macos.sh --list
```

## Wipe a mounted external volume

```bash
caffeinate -dimsu sudo bash scripts/secure_wipe_macos.sh "/Volumes/Your Volume"
```

## Wipe by exact media name

```bash
caffeinate -dimsu sudo env TARGET_NAME='External USB 3.0' \
  bash scripts/secure_wipe_macos.sh
```

The helper re-checks the current device immediately before confirmation. Do not use a bare `/dev/diskN`; pair a current device number with `TARGET_NAME` when the disk has no readable volume.

## Important safety notes

This operation destroys every partition and all data on the selected physical disk. It is irreversible. Verify the preflight summary and type both confirmation phrases carefully.

For a normal magnetic HDD, one complete overwrite pass is the practical default. Three passes are not generally required. For SSDs or flash media, use the manufacturer's Secure Erase or Sanitize feature instead; `ALLOW_SSD=1` only exists for users who explicitly accept the limitation.

Formatting is a separate action and is not performed automatically after wiping.
