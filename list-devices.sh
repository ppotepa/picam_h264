#!/usr/bin/env bash
# list-devices.sh — list USB and non-USB devices with their /dev nodes + metadata
# Works on Raspberry Pi OS / any udev-based Linux. No extra packages required.
# Usage: ./list-devices.sh [--video|--usb|--all]

set -euo pipefail

# Default filter mode
FILTER_MODE="all"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --video)
      FILTER_MODE="video"
      shift
      ;;
    --usb)
      FILTER_MODE="usb"
      shift
      ;;
    --all)
      FILTER_MODE="all"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--video|--usb|--all]"
      echo "  --video  Show only video devices (/dev/video*)"
      echo "  --usb    Show only USB-connected devices"
      echo "  --all    Show all devices (default)"
      echo ""
      echo "Examples:"
      echo "  $0 --video    # Show camera/video devices"
      echo "  $0 --usb      # Show USB devices"
      echo "  $0 | grep -i camera  # Search for camera-related devices"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# ===== helpers =====
bn() { basename "$(readlink -f "$1" 2>/dev/null || echo "$1")"; }

get_prop() {
  # $1 = blob, $2 = KEY
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{ $1=""; sub(/^=/,""); print; exit }'
}

print_header() {
  printf "%-28s %-14s %-14s %-10s %-24s %-24s %s\n" \
    "DEVNODE" "SUBSYSTEM" "DRIVER" "BUS" "VENDOR:MODEL" "SERIAL" "ID_PATH"
  printf "%-28s %-14s %-14s %-10s %-24s %-24s %s\n" \
    "----------------------------" "------------" "------------" "--------" \
    "------------------------" "------------------------" "-----------------------------"
}

should_show_device() {
  local devnode="$1" props="$2"
  
  case "$FILTER_MODE" in
    video)
      # Show video devices
      [[ "$devnode" =~ ^/dev/video[0-9]+$ ]] && return 0
      # Also show related camera/media devices
      [[ "$devnode" =~ ^/dev/media[0-9]+$ ]] && return 0
      return 1
      ;;
    usb)
      # Show USB-connected devices
      echo "$props" | grep -q "ID_BUS=usb\|ID_PATH=.*usb" && return 0
      return 1
      ;;
    all)
      return 0
      ;;
  esac
  return 1
}

emit_row() {
  local devnode="$1" devdir="$2"

  # Prefer udevadm by *name* (fast, robust), fall back to *path*
  local props=""
  props="$(udevadm info --query=property --name="$devnode" 2>/dev/null || true)"
  if [[ -z "$props" && -n "$devdir" ]]; then
    props="$(udevadm info --query=property --path="$devdir" 2>/dev/null || true)"
  fi
  
  # Apply filtering
  if ! should_show_device "$devnode" "$props"; then
    return 0
  fi

  # Subsystem and driver
  local subsystem driver bus vendor model serial id_path vendormodel sysdev
  subsystem="$(get_prop "$props" SUBSYSTEM)"
  if [[ -z "$subsystem" && -n "$devdir" && -e "$devdir/subsystem" ]]; then
    subsystem="$(bn "$devdir/subsystem")"
  fi

  driver="$(get_prop "$props" DRIVER)"
  if [[ -z "$driver" && -n "$devdir" && -e "$devdir/device/driver" ]]; then
    driver="$(bn "$devdir/device/driver")"
  fi

  # Bus
  bus="$(get_prop "$props" ID_BUS)"
  if [[ -z "$bus" && -n "$devdir" ]]; then
    if [[ -e "$devdir/device/subsystem" ]]; then
      bus="$(bn "$devdir/device/subsystem")"
    fi
    [[ -z "$bus" && "$devdir" =~ /usb/ ]] && bus="usb"
  fi
  [[ -n "$bus" ]] || bus="(n/a)"

  # Identity
  vendor="$(get_prop "$props" ID_VENDOR_FROM_DATABASE)"
  [[ -n "$vendor" ]] || vendor="$(get_prop "$props" ID_VENDOR)"
  model="$(get_prop "$props" ID_MODEL_FROM_DATABASE)"
  [[ -n "$model" ]] || model="$(get_prop "$props" ID_MODEL)"
  serial="$(get_prop "$props" ID_SERIAL_SHORT)"
  [[ -n "$serial" ]] || serial="$(get_prop "$props" ID_SERIAL)"
  id_path="$(get_prop "$props" ID_PATH)"

  vendormodel=""
  if [[ -n "$vendor" || -n "$model" ]]; then
    vendormodel="${vendor:+$vendor}:${model:+$model}"
    vendormodel="${vendormodel#:}"
    vendormodel="${vendormodel%:}"
  else
    vendormodel="-"
  fi
  [[ -n "$serial" ]] || serial="-"
  [[ -n "$id_path" ]] || id_path="-"

  printf "%-28s %-14s %-14s %-10s %-24s %-24s %s\n" \
    "$devnode" "${subsystem:-"(n/a)"}" "${driver:-"(n/a)"}" "$bus" \
    "$vendormodel" "$serial" "$id_path"
}

declare -A printed=()

print_header

# ===== Pass 1: sysfs class devices (FOLLOW SYMLINKS!) =====
# -L is crucial; /sys/class/*/* are symlinks into /sys/devices/...
while IFS= read -r -d '' uevent; do
  devdir="$(dirname "$uevent")"
  devname="$(grep -m1 '^DEVNAME=' "$uevent" | cut -d= -f2 || true)"
  [[ -n "$devname" ]] || continue
  devnode="/dev/$devname"
  [[ -e "$devnode" ]] || continue
  if [[ -z "${printed[$devnode]:-}" ]]; then
    emit_row "$devnode" "$devdir"
    printed[$devnode]=1
  fi
done < <(find -L /sys/class -mindepth 2 -maxdepth 2 -type f -name uevent -print0 2>/dev/null)

# ===== Pass 2: sweep /dev/* as a safety net (e.g., some pseudo-devs that still have udev info) =====
# Only include character/block devices, skip obvious pseudo/pts/shm.
while IFS= read -r -d '' devnode; do
  [[ -e "$devnode" ]] || continue
  [[ -c "$devnode" || -b "$devnode" ]] || continue
  case "$devnode" in
    /dev/null|/dev/zero|/dev/random|/dev/urandom|/dev/tty|/dev/pts/*|/dev/shm/*) continue ;;
  esac
  
  # Skip block devices when looking for video devices
  if [[ "$FILTER_MODE" == "video" && -b "$devnode" ]]; then
    continue
  fi
  
  [[ -z "${printed[$devnode]:-}" ]] || continue

  # Try to get sysfs path to pass to emit_row (optional)
  sys_path="$(udevadm info -q path --name="$devnode" 2>/dev/null || true)"
  if [[ -n "$sys_path" && -e "$sys_path" ]]; then
    emit_row "$devnode" "$sys_path"
  else
    emit_row "$devnode" ""
  fi
  printed[$devnode]=1
done < <(find /dev -maxdepth 1 -type c -o -type b -print0 2>/dev/null)

# Show summary for video devices if in video mode
if [[ "$FILTER_MODE" == "video" ]]; then
  echo ""
  echo "=== Video Device Summary ==="
  if ls /dev/video* >/dev/null 2>&1; then
    echo "Found video devices:"
    for video_dev in /dev/video*; do
      if [[ -c "$video_dev" ]]; then
        echo "  $video_dev"
        # Try to get device info
        if command -v v4l2-ctl >/dev/null 2>&1; then
          v4l2-ctl --device="$video_dev" --info 2>/dev/null | head -3 | sed 's/^/    /'
        fi
      fi
    done
  else
    echo "No video devices found."
    echo "Tips:"
    echo "  - Connect a USB camera and run again"
    echo "  - Check if CSI camera is enabled: sudo raspi-config -> Interface Options -> Camera"
    echo "  - For CSI cameras, use: libcamera-hello --list-cameras"
  fi
fi

# Hints:
#   ./list-devices.sh --video     # Show only camera/video devices  
#   ./list-devices.sh --usb       # Show only USB devices
#   ./list-devices.sh | grep -i camera  # Search for camera-related devices
