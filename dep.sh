#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Options:
  --check               Only verify dependencies and exit with the result
  --require-whiptail    Treat whiptail as a mandatory dependency
  -h, --help            Show this help message and exit
USAGE
}

CHECK_ONLY=0
REQUIRE_WHIPTAIL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --require-whiptail)
      REQUIRE_WHIPTAIL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "${SCRIPT_NAME}: Unexpected argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

REQUIRED_COMMANDS=(
  libcamera-vid
  ffmpeg
  awk
  ps
  stdbuf
)

OPTIONAL_COMMANDS=(
  whiptail
  v4l2-ctl
)

declare -A COMMAND_PACKAGES=(
  [libcamera-vid]="libcamera-apps"
  [rpicam-vid]="libcamera-apps"
  [ffmpeg]="ffmpeg"
  [awk]="gawk"
  [ps]="procps"
  [stdbuf]="coreutils"
  [whiptail]="whiptail"
  [v4l2-ctl]="v4l-utils"
)

# Check if either libcamera-vid or rpicam-vid is available
check_camera_command() {
  if command -v libcamera-vid >/dev/null 2>&1; then
    return 0
  elif command -v rpicam-vid >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

build_required_list() {
  local -n _out="$1"
  _out=("${REQUIRED_COMMANDS[@]}")
  if [[ "$REQUIRE_WHIPTAIL" -eq 1 ]]; then
    _out+=("whiptail")
  fi
}

build_optional_list() {
  local -n _out="$1"
  _out=()
  for cmd in "${OPTIONAL_COMMANDS[@]}"; do
    if [[ "$REQUIRE_WHIPTAIL" -eq 1 && "$cmd" == "whiptail" ]]; then
      continue
    fi
    _out+=("$cmd")
  done
}

maybe_sudo() {
  if [[ $EUID -eq 0 ]]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "${SCRIPT_NAME}: Cannot install packages automatically (sudo unavailable)." >&2
    return 1
  fi
}

update_and_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "${SCRIPT_NAME}: apt-get is required to install packages automatically." >&2
    return 1
  fi

  if [[ $EUID -eq 0 ]]; then
    apt-get update
    apt-get install -y "$@"
  else
    maybe_sudo apt-get update
    maybe_sudo apt-get install -y "$@"
  fi
}

check_commands() {
  local -n _required="$1"
  local -n _optional="$2"

  local missing=()

  echo "Checking required commands..."
  for cmd in "${_required[@]}"; do
    if [[ "$cmd" == "libcamera-vid" ]]; then
      if check_camera_command; then
        if command -v libcamera-vid >/dev/null 2>&1; then
          echo "[OK] libcamera-vid"
        else
          echo "[OK] rpicam-vid (replaces libcamera-vid)"
        fi
      else
        local pkg="${COMMAND_PACKAGES[$cmd]:-}"
        if [[ -n "$pkg" ]]; then
          echo "[MISSING] libcamera-vid or rpicam-vid (install package: $pkg)"
        else
          echo "[MISSING] libcamera-vid or rpicam-vid"
        fi
        missing+=("$cmd")
      fi
    elif command -v "$cmd" >/dev/null 2>&1; then
      echo "[OK] $cmd"
    else
      local pkg="${COMMAND_PACKAGES[$cmd]:-}"
      if [[ -n "$pkg" ]]; then
        echo "[MISSING] $cmd (install package: $pkg)"
      else
        echo "[MISSING] $cmd"
      fi
      missing+=("$cmd")
    fi
  done

  if [[ ${#_optional[@]} -gt 0 ]]; then
    echo
    echo "Checking optional commands..."
    for cmd in "${_optional[@]}"; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo "[OK] $cmd"
      else
        local pkg="${COMMAND_PACKAGES[$cmd]:-}"
        if [[ -n "$pkg" ]]; then
          echo "[OPTIONAL MISSING] $cmd (install package: $pkg)"
        else
          echo "[OPTIONAL MISSING] $cmd"
        fi
      fi
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    return 1
  fi
  return 0
}

required_commands=()
optional_commands=()
build_required_list required_commands
build_optional_list optional_commands

if check_commands required_commands optional_commands; then
  exit 0
fi

if (( CHECK_ONLY )); then
  exit 1
fi

dedup_packages=()
declare -A seen=()
missing_without_package=()

for cmd in "${required_commands[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 && continue
  pkg="${COMMAND_PACKAGES[$cmd]:-}"
  if [[ -n "$pkg" ]]; then
    if [[ -z "${seen[$pkg]+x}" ]]; then
      dedup_packages+=("$pkg")
      seen[$pkg]=1
    fi
  else
    missing_without_package+=("$cmd")
  fi
done

if [[ ${#missing_without_package[@]} -gt 0 ]]; then
  echo "${SCRIPT_NAME}: Missing required commands without known packages: ${missing_without_package[*]}" >&2
  exit 1
fi

if [[ ${#dedup_packages[@]} -eq 0 ]]; then
  echo "${SCRIPT_NAME}: Required commands are missing but no packages were identified." >&2
  exit 1
fi

echo "Installing packages: ${dedup_packages[*]}"
if ! update_and_install "${dedup_packages[@]}"; then
  echo "${SCRIPT_NAME}: Package installation failed." >&2
  exit 1
fi

hash -r 2>/dev/null || true

if check_commands required_commands optional_commands; then
  exit 0
fi

echo "${SCRIPT_NAME}: Dependencies remain missing after installation." >&2
exit 1
