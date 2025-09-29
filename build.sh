#!/usr/bin/env bash
# build.sh — compile picam_bench.c and ensure runtime deps on Raspberry Pi OS / Debian
# Usage:
# ./build.sh # auto-install deps (apt) if needed, then build
# SKIP_INSTALL=1 ./build.sh # just build, do not install anything  
# VERBOSE=1 ./build.sh # show compiler command

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/picam.c"
OUT="${SCRIPT_DIR}/picam"

: "${SKIP_INSTALL:=0}"
: "${VERBOSE:=0}"

die() {
    echo "build.sh: $*" >&2
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

maybe_sudo() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_install() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    echo ">>> Installing packages: ${pkgs[*]}"
    maybe_sudo apt-get update -y
    maybe_sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

ensure_deps() {
    [[ "${SKIP_INSTALL}" -eq 1 ]] && return 0

    # Build toolchain
    local need_pkgs=()
    have gcc || need_pkgs+=("build-essential" "gcc")
    
    # Header: linux/videodev2.h comes from linux-libc-dev
    [[ -f /usr/include/linux/videodev2.h ]] || need_pkgs+=("linux-libc-dev")

    # Runtime tools orchestrated by the C binary
    have ffmpeg || need_pkgs+=("ffmpeg")
    have v4l2-ctl || need_pkgs+=("v4l-utils")
    
    # Camera apps for CSI path (either name works on Pi OS Bookworm)
    if ! have rpicam-vid && ! have libcamera-vid; then
        need_pkgs+=("libcamera-apps")
    fi

    # Optional but nice for preview windows on minimal images
    if ! dpkg -s fonts-dejavu-core >/dev/null 2>&1; then
        need_pkgs+=("fonts-dejavu-core")
    fi

    # Install if anything missing
    if [[ ${#need_pkgs[@]} -gt 0 ]]; then
        apt_install "${need_pkgs[@]}"
    fi
}

check_runtime() {
    echo ">>> Runtime checks"
    have ffmpeg || die "ffmpeg not found after install"
    have v4l2-ctl || echo "  [WARN] v4l2-ctl not found (USB probing will be less rich)"

    # Check ffmpeg SDL output device availability (used for preview)
    if ffmpeg -hide_banner -devices 2>/dev/null | grep -E '^[ D].* \bsdl\b' >/dev/null; then
        echo "  [OK] ffmpeg has SDL output device"
    else
        echo "  [WARN] ffmpeg SDL output device not detected."
        echo "        Preview may fail with \"Requested output device 'sdl' not available\"."
        echo "        Workarounds:"
        echo "          - install an ffmpeg build with SDL output device enabled, or"
        echo "          - modify the code to fall back to ffplay if -f sdl is unavailable."
    fi

    if have rpicam-vid || have libcamera-vid; then
        echo "  [OK] rpicam/libcamera apps present for CSI path"
    else
        echo "  [WARN] rpicam-vid/libcamera-vid not found (CSI path will not work)"
    fi
}

compile() {
    [[ -f "${SRC}" ]] || die "Source file not found: ${SRC}"

    local CFLAGS=(-O2 -pipe -Wall -Wextra -Wno-unused-parameter -pthread -D_GNU_SOURCE)
    local LDFLAGS=(-pthread)

    if [[ "${VERBOSE}" -eq 1 ]]; then
        echo ">>> gcc ${CFLAGS[*]} -o \"${OUT}\" \"${SRC}\" ${LDFLAGS[*]}"
    fi

    gcc "${CFLAGS[@]}" -o "${OUT}" "${SRC}" "${LDFLAGS[@]}"
    strip -s "${OUT}" || true

    echo ">>> Built: ${OUT}"
}

post_build_smoke() {
    echo ">>> Quick smoke test: list cameras"
    if ! "${OUT}" --list-cameras; then
        echo "  [WARN] list-cameras returned an error. If this is a headless system with no cameras attached, this is expected."
    fi

    echo
    echo "Run examples:"
    echo "  ${OUT} --list-cameras"
    echo "  ${OUT} --no-menu --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000"
    echo "  ${OUT} --source /dev/video0 --encode hardware --resolution 1280x720 --fps 30 --bitrate 4000000 --no-overlay"
}

main() {
    ensure_deps
    check_runtime
    compile
    post_build_smoke
}

main "$@"