#!/usr/bin/env bash
set -euo pipefail

# macOS 外置物理磁盘安全擦除脚本。
# 默认：精确定位目标后，对整块磁盘执行 1 遍 /dev/urandom 覆写，并显示 Unicode 进度条。
#
# 用法：
#   脚本 --list
#   脚本 "/Volumes/卷名"
#   TARGET_NAME='External USB 3.0' 脚本
#   TARGET_NAME='External USB 3.0' 脚本 /dev/disk4
#
# 可选环境变量：
#   PASSES=1                 覆写遍数，默认 1
#   SOURCE=/dev/urandom      覆写源，默认 /dev/urandom
#   TARGET_NAME='...'        精确匹配当前媒体名/卷名
#   ALLOW_SSD=1              明确接受 SSD 普通覆写不能保证清除旧块的限制

TARGET_ARGUMENT="${1:-}"
TARGET_DEVICE=""
TARGET_PATH=""
TARGET_NAME="${TARGET_NAME:-}"
PASSES="${PASSES:-1}"
SOURCE="${SOURCE:-/dev/urandom}"
BLOCK_SIZE=$((16 * 1024 * 1024))
progress_file=""

usage() {
  cat >&2 <<'EOF'
用法：
  secure_wipe_macos.sh --list
  secure_wipe_macos.sh "/Volumes/卷名"
  TARGET_NAME='精确媒体名或卷名' secure_wipe_macos.sh
  TARGET_NAME='精确媒体名或卷名' secure_wipe_macos.sh /dev/diskN

说明：
  --list 只列出外置物理磁盘，不会修改数据。
  直接使用 /dev/diskN 时，必须同时设置 TARGET_NAME 进行身份核对。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -z "$progress_file" ]] || rm -f "$progress_file"
}

trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || die "此脚本只支持 macOS。"
command -v diskutil >/dev/null 2>&1 || die "找不到 diskutil。"

if [[ "$TARGET_ARGUMENT" == "--help" || "$TARGET_ARGUMENT" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$TARGET_ARGUMENT" == "--list" ]]; then
  diskutil list external physical
  exit 0
fi

if [[ "$TARGET_ARGUMENT" =~ ^/dev/disk[0-9]+$ ]]; then
  TARGET_DEVICE="$TARGET_ARGUMENT"
elif [[ "$TARGET_ARGUMENT" == /Volumes/* ]]; then
  TARGET_PATH="$TARGET_ARGUMENT"
  [[ -n "$TARGET_NAME" ]] || TARGET_NAME="$(basename "$TARGET_ARGUMENT")"
elif [[ -n "$TARGET_ARGUMENT" ]]; then
  [[ -n "$TARGET_NAME" ]] || TARGET_NAME="$TARGET_ARGUMENT"
fi

[[ -n "$TARGET_DEVICE" || -n "$TARGET_PATH" || -n "$TARGET_NAME" ]] || {
  usage
  die "必须指定目标卷路径、精确媒体名/卷名，或 /dev/diskN。"
}

[[ $EUID -eq 0 ]] || die "写入整块磁盘需要管理员权限，请使用 sudo。"
[[ -r "$SOURCE" ]] || die "覆写源不可读：$SOURCE"
[[ "$PASSES" =~ ^[1-9][0-9]*$ ]] || die "PASSES 必须是正整数。"

trimmed_value() {
  awk -v key="$1" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      prefix = key ":"
      if (index(line, prefix) == 1) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        print line
        exit
      }
    }
  '
}

external_disks=()
while IFS= read -r disk; do
  [[ -n "$disk" ]] && external_disks+=("$disk")
done < <(diskutil list external physical | awk '$1 ~ /^\/dev\/disk[0-9]+$/ { print $1 }')

is_external_physical_disk() {
  local wanted="$1"
  local disk
  for disk in "${external_disks[@]}"; do
    [[ "$disk" == "$wanted" ]] && return 0
  done
  return 1
}

resolve_physical_parent() {
  local identifier="$1"
  local info parent physical_store container_ref depth

  # 从卷/分区逐级向上追溯，直到找到当前 external physical 的整块磁盘。
  for ((depth = 0; depth < 8; depth++)); do
    if is_external_physical_disk "/dev/$identifier"; then
      printf '/dev/%s\n' "$identifier"
      return 0
    fi

    info="$(diskutil info "/dev/$identifier" 2>/dev/null || true)"
    physical_store="$(printf '%s\n' "$info" | trimmed_value 'APFS Physical Store' | awk '{ print $1 }')"
    if [[ "$physical_store" =~ ^disk[0-9]+s[0-9]+$ ]]; then
      identifier="$physical_store"
      continue
    fi

    container_ref="$(printf '%s\n' "$info" | trimmed_value 'APFS Container Reference' | awk '{ print $1 }')"
    if [[ "$container_ref" =~ ^disk[0-9]+$ ]]; then
      physical_store="$(diskutil apfs list 2>/dev/null \
        | awk -v container="$container_ref" '
            index($0, "APFS Container Reference: " container) { inside = 1; next }
            inside && /APFS Container Reference:/ { exit }
            inside && /Physical Store/ {
              for (i = 1; i <= NF; i++) {
                if ($i ~ /^disk[0-9]+s[0-9]+$/) { print $i; exit }
              }
            }
          }')"
      if [[ "$physical_store" =~ ^disk[0-9]+s[0-9]+$ ]]; then
        identifier="$physical_store"
        continue
      fi
    fi

    parent="$(printf '%s\n' "$info" | trimmed_value 'Part of Whole')"
    [[ "$parent" =~ ^disk[0-9]+(s[0-9]+)?$ ]] || return 1
    [[ "$parent" != "$identifier" ]] || return 1
    identifier="$parent"
  done

  return 1
}

matches=()

if [[ -n "$TARGET_DEVICE" ]]; then
  is_external_physical_disk "$TARGET_DEVICE" || die "指定设备不是当前识别到的外置物理磁盘：$TARGET_DEVICE"
  [[ -n "$TARGET_NAME" ]] || die "直接指定设备时必须同时设置 TARGET_NAME，用于防止 disk 编号变化后误擦别的盘。"
  direct_info="$(diskutil info "$TARGET_DEVICE")"
  direct_media_name="$(printf '%s\n' "$direct_info" | trimmed_value 'Device / Media Name')"
  direct_volume_name="$(printf '%s\n' "$direct_info" | trimmed_value 'Volume Name')"
  if [[ "$direct_media_name" != "$TARGET_NAME" && "$direct_volume_name" != "$TARGET_NAME" ]]; then
    die "设备身份不匹配，已停止：$TARGET_DEVICE 当前为「$direct_media_name」，目标应为「$TARGET_NAME」。"
  fi
  matches+=("$TARGET_DEVICE")
elif [[ -n "$TARGET_PATH" && -e "$TARGET_PATH" ]]; then
  volume_info="$(diskutil info "$TARGET_PATH" 2>/dev/null || true)"
  volume_identifier="$(printf '%s\n' "$volume_info" | trimmed_value 'Device Identifier')"
  if [[ "$volume_identifier" =~ ^disk[0-9]+(s[0-9]+)?$ ]]; then
    parent_disk="$(resolve_physical_parent "$volume_identifier" || true)"
    [[ -n "$parent_disk" ]] && matches+=("$parent_disk")
  fi
fi

if (( ${#matches[@]} == 0 )); then
  for disk in "${external_disks[@]}"; do
    info="$(diskutil info "$disk")"
    media_name="$(printf '%s\n' "$info" | trimmed_value 'Device / Media Name')"
    volume_name="$(printf '%s\n' "$info" | trimmed_value 'Volume Name')"
    if [[ "$media_name" == "$TARGET_NAME" || "$volume_name" == "$TARGET_NAME" ]]; then
      matches+=("$disk")
    fi
  done
fi

if (( ${#matches[@]} == 0 )); then
  printf '没有找到目标：%s\n\n' "${TARGET_PATH:-${TARGET_NAME:-$TARGET_DEVICE}}" >&2
  diskutil list external physical >&2 || true
  die "请确认硬盘已连接，并使用当前的精确媒体名/卷名。"
fi

(( ${#matches[@]} == 1 )) || die "名称匹配到多个磁盘，已停止：${matches[*]}"

DISK="${matches[0]}"
RAW_DISK="/dev/r${DISK#/dev/}"
INFO="$(diskutil info "$DISK")"
SIZE_BYTES="$(printf '%s\n' "$INFO" \
  | sed -n 's/^ *Disk Size:.*(\([0-9,]*\) Bytes).*/\1/p' \
  | tr -d ',' \
  | head -n 1)"
[[ "$SIZE_BYTES" =~ ^[0-9]+$ ]] || die "无法读取磁盘容量。"

device_location="$(printf '%s\n' "$INFO" | trimmed_value 'Device Location')"
[[ "$device_location" == "External" ]] || die "目标不是外置设备，已停止。"

media_name="$(printf '%s\n' "$INFO" | trimmed_value 'Device / Media Name')"
volume_name="$(printf '%s\n' "$INFO" | trimmed_value 'Volume Name')"
protocol="$(printf '%s\n' "$INFO" | trimmed_value 'Protocol')"
smart_status="$(printf '%s\n' "$INFO" | trimmed_value 'SMART Status')"
solid_state="$(printf '%s\n' "$INFO" | trimmed_value 'Solid State')"

if [[ "$solid_state" == "Yes" && "${ALLOW_SSD:-0}" != "1" ]]; then
  die "检测到这是固态介质。普通整盘覆写不能保证清除闪存旧块；请使用厂商 Secure Erase/Sanitize。若你仍要覆写，请先明确接受限制并设置 ALLOW_SSD=1。"
fi

printf '\n将要被擦除的设备：\n'
printf '  设备：%s\n' "$DISK"
printf '  原始设备：%s\n' "$RAW_DISK"
printf '  媒体名：%s\n' "${media_name:-（未知）}"
printf '  卷名：%s\n' "${volume_name:-（无或未知）}"
printf '  容量：%s bytes\n' "$SIZE_BYTES"
printf '  位置：%s\n' "${device_location:-（未知）}"
printf '  协议：%s\n' "${protocol:-（未知）}"
printf '  SMART：%s\n' "${smart_status:-（未知）}"
printf '  固态状态：%s\n' "${solid_state:-（未知）}"
printf '  覆写：%s 遍，来源：%s\n\n' "$PASSES" "$SOURCE"
diskutil list "$DISK"

if [[ "$solid_state" == "Yes" ]]; then
  printf '\n警告：这是 SSD/闪存设备，普通覆写不保证清除旧块。\n'
  read -r -p '若仍要继续，请输入 I ACCEPT SSD LIMITATIONS： ' ssd_confirmation
  [[ "$ssd_confirmation" == "I ACCEPT SSD LIMITATIONS" ]] || die "未接受 SSD 限制，未执行。"
fi

printf '\n这会删除该整块硬盘上的所有分区和数据，且不可撤销。\n'
confirm_phrase="ERASE $DISK"
read -r -p "请输入 $confirm_phrase 继续： " confirmation
[[ "$confirmation" == "$confirm_phrase" ]] || die "确认文本不正确，未执行。"
read -r -p '再次输入 I UNDERSTAND： ' confirmation2
[[ "$confirmation2" == "I UNDERSTAND" ]] || die "第二次确认不正确，未执行。"

printf '\n正在卸载 %s ...\n' "$DISK"
diskutil unmountDisk force "$DISK"
[[ -e "$RAW_DISK" ]] || die "找不到原始设备：$RAW_DISK"

draw_progress() {
  local written_bytes="$1"
  local bar_width=32
  local filled empty i bar percent

  (( written_bytes > SIZE_BYTES )) && written_bytes="$SIZE_BYTES"
  filled=$((written_bytes * bar_width / SIZE_BYTES))
  empty=$((bar_width - filled))
  bar=""

  for ((i = 0; i < filled; i++)); do bar="${bar}█"; done
  for ((i = 0; i < empty; i++)); do bar="${bar}░"; done

  percent="$(awk -v written="$written_bytes" -v total="$SIZE_BYTES" \
    'BEGIN { printf "%.2f", written * 100 / total }')"
  printf '\r[%s] %6s%%（已写入 %s / %s bytes）' \
    "$bar" "$percent" "$written_bytes" "$SIZE_BYTES"
}

read_progress_bytes() {
  local value
  value="$(awk '/bytes transferred/ { value = $1 } END { gsub(/,/, "", value); print value }' "$progress_file")"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

write_with_progress() {
  local pass="$1"
  local full_blocks=$((SIZE_BYTES / BLOCK_SIZE))
  local remainder=$((SIZE_BYTES % BLOCK_SIZE))
  local dd_pid dd_status written_bytes

  printf '\n第 %s/%s 遍：\n' "$pass" "$PASSES"
  progress_file="$(mktemp -t secure-wipe-progress.XXXXXX)"
  dd if="$SOURCE" of="$RAW_DISK" bs="$BLOCK_SIZE" count="$full_blocks" 2>"$progress_file" &
  dd_pid=$!

  while kill -0 "$dd_pid" 2>/dev/null; do
    kill -INFO "$dd_pid" 2>/dev/null || true
    written_bytes="$(read_progress_bytes)"
    draw_progress "$written_bytes"
    sleep 2
  done

  if wait "$dd_pid"; then
    dd_status=0
  else
    dd_status=$?
  fi

  written_bytes="$(read_progress_bytes)"
  draw_progress "$written_bytes"
  rm -f "$progress_file"
  progress_file=""

  if (( dd_status != 0 )); then
    printf '\n\n写入失败：第 %s 遍已写入约 %s / %s bytes。\n' \
      "$pass" "$written_bytes" "$SIZE_BYTES" >&2
    die "设备可能掉线或发生 I/O 错误；未确认整盘擦除，不自动重试。"
  fi

  if (( remainder > 0 )); then
    if ! dd if="$SOURCE" of="$RAW_DISK" bs="$remainder" count=1 2>/dev/null; then
      printf '\n\n写入失败：第 %s 遍在尾部块发生错误。\n' "$pass" >&2
      die "未确认整盘擦除，不自动重试。"
    fi
  fi

  draw_progress "$SIZE_BYTES"
  printf '\n'
}

for ((pass = 1; pass <= PASSES; pass++)); do
  write_with_progress "$pass"
done

sync
printf '\n擦除完成。尝试弹出设备：%s\n' "$DISK"
diskutil eject "$DISK" >/dev/null 2>&1 || true
printf '已完成整盘覆写；设备已弹出或保持未挂载。\n'
