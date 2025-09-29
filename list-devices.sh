#!/usr/bin/env bash
# list-devnodes.sh — lists USB and non-USB devices with their /dev nodes and key metadata
# Works on Raspberry Pi (Linux) with udev. No extra packages required.

set -euo pipefail

# Utility: safe readlink basename
bn() { basename "$(readlink -f "$1" 2>/dev/null || echo "$1")"; }

# Utility: extract a prop from a udevadm --query=property blob
get_prop() {
  # $1 = blob, $2 = key
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{ $1=""; sub(/^=/,""); print; exit }'
}

printf "%-28s %-14s %-14s %-10s %-20s %-24s %s\n" \
  "DEVNODE" "SUBSYSTEM" "DRIVER" "BUS" "VENDOR:MODEL" "SERIAL" "ID_PATH"
printf "%-28s %-14s %-14s %-10s %-20s %-24s %s\n" \
  "----------------------------" "------------" "------------" "--------" "--------------------" "------------------------" "-----------------------------"

# Iterate over all kernel devices that expose a /dev node via uevent (DEVNAME)
# This avoids pseudo devices like /dev/null which lack a backing kernel device with uevent.
while IFS= read -r -d '' uevent; do
  devdir="$(dirname "$uevent")"
  # Pull DEVNAME from uevent (faster than spawning udevadm for this)
  devname="$(grep -m1 '^DEVNAME=' "$uevent" | cut -d= -f2 || true)"
  [[ -n "$devname" ]] || continue

  devnode="/dev/$devname"
  [[ -e "$devnode" ]] || continue  # Skip if node doesn't exist (very rare race)

  # Full udev property set for this device
  props="$(udevadm info --query=property --path="$devdir" 2>/dev/null || true)"

  subsystem="$(get_prop "$props" SUBSYSTEM)"
  [[ -n "$subsystem" ]] || subsystem="$(bn "$devdir/subsystem")"

  # Driver is on the *device* (not the class)
  driver="$(bn "$devdir/device/driver")"
  [[ "$driver" == "." ]] && driver=""  # normalize missing

  # Determine bus: prefer ID_BUS from udev, else infer from ancestry
  id_bus="$(get_prop "$props" ID_BUS)"
  if [[ -z "$id_bus" ]]; then
    # If any parent in the chain is on the usb bus, call it usb; else use the device's own bus if present
    if [[ -e "$devdir/device/subsystem" ]]; then
      devbus="$(bn "$devdir/device/subsystem")"
    else
      devbus=""
    fi
    if [[ -z "$devbus" ]]; then
      # heuristics via sysfs path
      sysfs_path="$(udevadm info -q path --path="$devdir" 2>/dev/null || echo "")"
      [[ "$sysfs_path" =~ /usb ]] && devbus="usb"
    fi
    bus="$devbus"
  else
    bus="$id_bus"
  fi
  [[ -n "$bus" ]] || bus="(n/a)"

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
    vendormodel="${vendormodel#:}"   # trim leading colon if vendor empty
    vendormodel="${vendormodel%:}"   # trim trailing colon if model empty
  fi

  printf "%-28s %-14s %-14s %-10s %-20s %-24s %s\n" \
    "$devnode" \
    "${subsystem:-"(n/a)"}" \
    "${driver:-"(n/a)"}" \
    "$bus" \
    "${vendormodel:-"-"}" \
    "${serial:-"-"}" \
    "${id_path:-"-"}"

done < <(find /sys/class -mindepth 2 -maxdepth 2 -type f -name uevent -print0 | sort -z)

# Hints: common filters you might want
#   | grep -i usb
#   | grep -E '/dev/(sd|mmcblk|tty|ttyUSB|ttyACM|i2c-|spidev|video|hidraw|input/event)'
