#!/usr/bin/env bash
set -euo pipefail

# Dependency installer/checker for picam_h264
# By default the script will attempt to install missing required dependencies
# using apt-get. Use --check to only verify availability.

print_usage() {
  cat <<'USAGE'
Usage: ./dep.sh [--check]

Checks for the commands required by picam.sh and optionally installs the
missing ones via apt-get. Run without arguments as root (or with sudo) to
perform installation, or use --check to only report the status.
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  print_usage
  exit 0
fi

CHECK_ONLY=0
if [[ ${1:-} == "--check" ]]; then
  CHECK_ONLY=1
fi

have_command() {
  command -v "$1" >/dev/null 2>&1
}

ensure_command_or_package() {
  local cmd="$1"
  local pkg="$2"
  if have_command "$cmd"; then
    echo "[OK] $cmd"
    return 0
  fi

  if (( CHECK_ONLY )); then
    echo "[MISSING] $cmd (install package: $pkg)"
    return 1
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "[NEEDS INSTALL] $cmd (run: sudo apt-get install -y $pkg)"
    return 1
  fi

  missing_packages["$pkg"]=1
  missing_commands+=("$cmd")
  return 0
}

declare -A missing_packages=()
missing_commands=()

# Required dependencies (command -> package)
declare -A required_cmds=(
  [libcamera-vid]="libcamera-apps"
  [ffmpeg]="ffmpeg"
  [awk]="gawk"
  [ps]="procps"
  [stdbuf]="coreutils"
)

# Optional dependencies (command -> package)
declare -A optional_cmds=(
  [whiptail]="whiptail"
)

echo "Checking required commands..."
required_missing=0
for cmd in "${!required_cmds[@]}"; do
  pkg="${required_cmds[$cmd]}"
  if ! ensure_command_or_package "$cmd" "$pkg"; then
    required_missing=1
  fi
  done

if (( required_missing )) && (( CHECK_ONLY )); then
  exit 1
fi

echo

echo "Checking optional commands (recommended)..."
for cmd in "${!optional_cmds[@]}"; do
  pkg="${optional_cmds[$cmd]}"
  if have_command "$cmd"; then
    echo "[OK] $cmd"
  else
    if (( CHECK_ONLY )); then
      echo "[OPTIONAL MISSING] $cmd (install package: $pkg)"
    else
      echo "[OPTIONAL] $cmd not found (install package: $pkg)"
      if [[ $EUID -eq 0 ]]; then
        missing_packages["$pkg"]=1
      fi
    fi
  fi
  done

if (( CHECK_ONLY )); then
  echo
  echo "Check completed."
  exit 0
fi

if [[ ${#missing_packages[@]} -eq 0 ]]; then
  echo
  echo "All dependencies are already installed."
  exit 0
fi

echo

echo "Installing missing packages..."
if ! have_command apt-get; then
  echo "apt-get is not available. Install the following packages manually: ${!missing_packages[*]}" >&2
  exit 1
fi

apt_updated=0
for pkg in "${!missing_packages[@]}"; do
  if (( ! apt_updated )); then
    apt-get update
    apt_updated=1
  fi
  apt-get install -y "$pkg"
  done

echo

echo "Dependency installation complete."

# Re-run checks to display final status
echo
echo "Verifying commands after installation..."
status=0
for cmd in "${!required_cmds[@]}"; do
  if have_command "$cmd"; then
    echo "[OK] $cmd"
  else
    echo "[MISSING] $cmd"
    status=1
  fi
  done
for cmd in "${!optional_cmds[@]}"; do
  if have_command "$cmd"; then
    echo "[OK] $cmd"
  else
    echo "[OPTIONAL MISSING] $cmd"
  fi
  done

exit "$status"
