#!/usr/bin/env bash
# =============================================================================
# autocam_preview.sh — Auto-pick the fastest, working camera preview to screen
# =============================================================================
# Features:
#   • CLI + optional whiptail wizard
#   • Auto-detect camera formats (YUYV / MJPG / H264) and choose fastest path
#   • Prefers KMS (kmssink) → falls back to fbdevsink → autovideosink
#   • Fixes colorimetry negotiation for YUYV with typed (string)2:4:16:1
#   • Duration control via --duration, verbose logs, dependency bootstrap
#
# Examples:
#   sudo ./autocam_preview.sh --source /dev/video0 --resolution 640x480 --fps 30 --display auto --verbose
#   sudo ./autocam_preview.sh --menu               # wizard on local TTY
#   sudo ./autocam_preview.sh --install-deps       # install required packages
# =============================================================================

set -euo pipefail

# -------------------- Defaults --------------------
DEFAULT_METHOD="preview"
DEFAULT_RESOLUTION="640x480"
DEFAULT_FPS="30"
DEFAULT_DURATION="0"           # 0 = run until Ctrl+C
DEFAULT_SOURCE="auto"          # auto | /dev/videoN
DEFAULT_DISPLAY="auto"         # auto | kms | fb | auto-video
DEFAULT_VERBOSE=1

SCRIPT_NAME=$(basename "$0")
LOG_LEVEL=${LOG_LEVEL:-$DEFAULT_VERBOSE}  # 0=ERROR, 1=INFO, 2=DEBUG

# Flags / state
USE_MENU=0
SKIP_MENU=0
INSTALL_DEPS=0
DRY_RUN=0
KEEP_BACKLIGHT=0
NO_BLANK=0

# Runtime config
METHOD="$DEFAULT_METHOD"
RESOLUTION="$DEFAULT_RESOLUTION"
FPS="$DEFAULT_FPS"
DURATION="$DEFAULT_DURATION"
SOURCE="$DEFAULT_SOURCE"
DISPLAY_MODE="$DEFAULT_DISPLAY"

# -------------------- Logging --------------------
ts(){ date '+%H:%M:%S.%3N' 2>/dev/null || date '+%H:%M:%S'; }
_log(){ local lvl="$1"; shift; (( LOG_LEVEL>=lvl )) && echo "[$(ts)] $*"; }
logE(){ _log 0 "ERROR: $*"; }
logI(){ _log 1 "INFO : $*"; }
logD(){ _log 2 "DEBUG: $*"; }
die(){ logE "$*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# -------------------- Usage ----------------------
usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  -m, --method <name>         (reserved, default: ${DEFAULT_METHOD})
  -r, --resolution WxH        Video resolution (default: ${DEFAULT_RESOLUTION})
  -f, --fps <number>          Frame rate (default: ${DEFAULT_FPS})
  -d, --duration <seconds>    Duration (default: ${DEFAULT_DURATION}, 0=infinite)
  -s, --source <dev>          Camera source: auto | /dev/videoN (default: ${DEFAULT_SOURCE})
      --display <mode>        Display: auto | kms | fb | auto-video (default: ${DEFAULT_DISPLAY})
      --keep-backlight        Try to keep panel backlight on
      --no-blank              Disable TTY blanking (run on local TTY)
      --install-deps          apt-get required packages and exit
      --dry-run               Print chosen pipeline, don't execute
      --menu                  Force whiptail wizard
      --no-menu               Skip wizard even with no args
  -v, --verbose               Increase verbosity (repeat to add)
      --quiet                 Only errors
  -h, --help                  Show help and exit

Known-good:
  sudo ${SCRIPT_NAME} --source /dev/video0 --resolution 640x480 --fps 30 --display auto --verbose
EOF
}

# -------------------- Arg parsing ----------------
parse_args() {
  local parsed
  parsed=$(getopt -o m:r:f:d:s:vh --long method:,resolution:,fps:,duration:,source:,display:,keep-backlight,no-blank,install-deps,dry-run,menu,no-menu,verbose,quiet,help -- "$@") || {
    usage; exit 1; }
  eval set -- "$parsed"
  while true; do
    case "$1" in
      -m|--method)     METHOD="$2"; shift 2;;
      -r|--resolution) RESOLUTION="$2"; shift 2;;
      -f|--fps)        FPS="$2"; shift 2;;
      -d|--duration)   DURATION="$2"; shift 2;;
      -s|--source)     SOURCE="$2"; shift 2;;
         --display)    DISPLAY_MODE="$2"; shift 2;;
         --keep-backlight) KEEP_BACKLIGHT=1; shift;;
         --no-blank)   NO_BLANK=1; shift;;
         --install-deps) INSTALL_DEPS=1; shift;;
         --dry-run)    DRY_RUN=1; shift;;
         --menu)       USE_MENU=1; shift;;
         --no-menu)    SKIP_MENU=1; shift;;
      -v|--verbose)    LOG_LEVEL=$((LOG_LEVEL+1)); shift;;
         --quiet)      LOG_LEVEL=0; shift;;
      -h|--help)       usage; exit 0;;
      --) shift; break;;
      *) die "Unexpected arg: $1";;
    esac
  done
  [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]] || die "Bad --resolution '$RESOLUTION' (WxH)"
  [[ "$FPS" =~ ^[0-9]+$ ]] || die "Bad --fps '$FPS'"
  [[ "$DURATION" =~ ^[0-9]+$ ]] || die "Bad --duration '$DURATION'"
  case "$DISPLAY_MODE" in auto|kms|fb|auto-video) ;; *) die "Bad --display '$DISPLAY_MODE'";; esac
}

# -------------------- Deps -----------------------
APT_PKGS=( v4l-utils gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad )
check_deps() {
  local miss=()
  have v4l2-ctl || miss+=("v4l-utils")
  have gst-launch-1.0 || miss+=("gstreamer1.0-tools")
  have gst-inspect-1.0 || miss+=("gstreamer1.0-tools")
  if (( ${#miss[@]} > 0 )); then
    logI "Missing: ${miss[*]}"
    if (( INSTALL_DEPS==1 )); then
      have apt-get || die "apt-get not found; please install packages manually"
      sudo apt-get update
      sudo apt-get install -y "${APT_PKGS[@]}"
      return
    else
      die "Please install: ${APT_PKGS[*]}  (or rerun with --install-deps)"
    fi
  fi
}
gst_has(){ gst-inspect-1.0 "$1" >/dev/null 2>&1; }

# -------------------- Wizard ---------------------
show_menu() {
  if ! have whiptail; then
    die "whiptail not installed (apt-get install whiptail) or use CLI flags."
  fi
  # Device list
  local devs=()
  for d in /dev/video*; do
    [[ -c "$d" ]] || continue
    devs+=("$d" "$d")
  done
  [[ ${#devs[@]} -gt 0 ]] || devs=( "auto" "auto-detect" )
  SOURCE=$(whiptail --title "PiCam Preview" --menu "Select camera source" 20 70 10 "${devs[@]}" 3>&1 1>&2 2>&3) || exit 1
  RESOLUTION=$(whiptail --title "Resolution" --inputbox "WIDTHxHEIGHT" 8 60 "$RESOLUTION" 3>&1 1>&2 2>&3) || exit 1
  FPS=$(whiptail --title "FPS" --inputbox "Frames per second" 8 60 "$FPS" 3>&1 1>&2 2>&3) || exit 1
  DISPLAY_MODE=$(whiptail --title "Display" --menu "Display sink" 15 70 4 \
    "auto" "auto (kms→fb→auto-video)" \
    "kms" "Direct DRM/KMS (fastest, local TTY)" \
    "fb"  "Framebuffer (/dev/fb0)" \
    "auto-video" "Auto video sink (needs X/Wayland)" \
    3>&1 1>&2 2>&3) || exit 1
}

# -------------------- Helpers --------------------
parse_wh(){ [[ "$1" =~ ^([0-9]+)x([0-9]+)$ ]] && echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; }
is_tty(){ [[ -t 1 ]]; }
has_drm(){ [[ -e /dev/dri/card0 || -e /dev/dri/card1 ]]; }
has_fb(){ [[ -e /dev/fb0 ]]; }

unblank_and_backlight() {
  if (( NO_BLANK==1 )); then
    if is_tty; then
      logI "Disabling console blanking…"
      setterm -blank 0 -powersave off -powerdown 0 </dev/tty || true
      setterm -blank 0 -powersave off -powerdown 0 </dev/tty1 || true
    else
      logD "Not a TTY; skipping unblank."
    fi
  fi
  if (( KEEP_BACKLIGHT==1 )); then
    logI "Keeping backlight on…"
    for n in /sys/class/backlight/*/bl_power; do
      [ -e "$n" ] && echo 0 | sudo tee "$n" >/dev/null 2>&1 || true
    done
  fi
}

detect_device() {
  if [[ "$SOURCE" == "auto" ]]; then
    if ls /dev/video* >/dev/null 2>&1; then
      for d in /dev/video*; do [[ -c "$d" ]] && { echo "$d"; return; }; done
    fi
    die "No /dev/video* device found"
  else
    [[ -c "$SOURCE" ]] || die "Camera device not found: $SOURCE"
    echo "$SOURCE"
  fi
}

probe_formats() { v4l2-ctl -d "$1" --list-formats-ext 2>/dev/null || true; }

pick_source_kind() {
  local lst="$1"
  local has_h264=0 has_yuyv=0 has_mjpg=0
  grep -q "H264" <<<"$lst" && has_h264=1 || true
  grep -q "YUYV" <<<"$lst" && has_yuyv=1 || true
  grep -q "MJPG" <<<"$lst" && has_mjpg=1 || true
  # Prefer YUYV over MJPEG for CPU; use H264 if available (decode via v4l2h264dec)
  if (( has_yuyv==1 )); then echo "yuyv"; return; fi
  if (( has_h264==1 )); then echo "h264"; return; fi
  if (( has_mjpg==1 )); then echo "mjpg"; return; fi
  echo "none"
}

pick_sink_pref() {
  case "$DISPLAY_MODE" in
    kms) echo "kms";;
    fb)  echo "fb";;
    auto-video) echo "auto-video";;
    auto)
      if has_drm && gst_has kmssink; then echo "kms"; return; fi
      if has_fb  && gst_has fbdevsink; then echo "fb";  return; fi
      echo "auto-video";;
  esac
}

# -------------------- Pipelines (return as single-line strings) -------------------
build_pipeline_yuyv_kms() {
  local dev="$1" w="$2" h="$3" fps="$4"
  echo "gst-launch-1.0 v4l2src device=${dev} io-mode=mmap ! 'video/x-raw,format=YUY2,width=${w},height=${h},framerate=${fps}/1,colorimetry=(string)2:4:16:1,interlace-mode=progressive' ! v4l2convert ! 'video/x-raw,format=NV12' ! queue max-size-buffers=2 leaky=downstream ! kmssink sync=false"
}
build_pipeline_yuyv_kms_nocol() {
  local dev="$1" w="$2" h="$3" fps="$4"
  echo "gst-launch-1.0 v4l2src device=${dev} io-mode=mmap ! video/x-raw,format=YUY2,width=${w},height=${h},framerate=${fps}/1,interlace-mode=progressive ! videoconvert ! 'video/x-raw,format=NV12' ! queue max-size-buffers=2 leaky=downstream ! kmssink sync=false"
}
build_pipeline_yuyv_fb() {
  local dev="$1" w="$2" h="$3" fps="$4"
  echo "gst-launch-1.0 v4l2src device=${dev} io-mode=mmap ! 'video/x-raw,format=YUY2,width=${w},height=${h},framerate=${fps}/1,colorimetry=(string)2:4:16:1,interlace-mode=progressive' ! videoconvert ! videoscale ! 'video/x-raw,format=RGB16' ! queue max-size-buffers=2 leaky=downstream ! fbdevsink device=/dev/fb0 sync=false"
}
build_pipeline_mjpg_kms() {
  local dev="$1" w="$2" h="$3" fps="$4"
  echo "gst-launch-1.0 v4l2src device=${dev} io-mode=mmap ! image/jpeg,width=${w},height=${h},framerate=${fps}/1 ! jpegdec ! videoconvert ! 'video/x-raw,format=NV12' ! queue max-size-buffers=2 leaky=downstream ! kmssink sync=false"
}
build_pipeline_mjpg_fb() {
  local dev="$1" w="$2" h="$3" fps="$4"
  echo "gst-launch-1.0 v4l2src device=${dev} io-mode=mmap ! image/jpeg,width=${w},height=${h},framerate=${fps}/1 ! jpegdec ! videoconvert ! videoscale ! 'video/x-raw,format=RGB16' ! queue max-size-buffers=2 leaky=downstream ! fbdevsink device=/dev/fb0 sync=false"
}
build_pipeline_h264_kms() {
  local dev="$1" w="$2" h="$3" fps="$4"
  echo "gst-launch-1.0 v4l2src device=${dev} io-mode=dmabuf ! video/x-h264,stream-format=byte-stream,alignment=au,width=${w},height=${h},framerate=${fps}/1 ! h264parse ! v4l2h264dec capture-io-mode=dmabuf ! queue max-size-buffers=2 leaky=downstream ! kmssink sync=false"
}
build_pipeline_h264_fb() {
  local dev="$1" w="$2" h="$3" fps="$4"
  echo "gst-launch-1.0 v4l2src device=${dev} io-mode=dmabuf ! video/x-h264,stream-format=byte-stream,alignment=au,width=${w},height=${h},framerate=${fps}/1 ! h264parse ! v4l2h264dec capture-io-mode=dmabuf ! videoconvert ! videoscale ! 'video/x-raw,format=RGB16' ! queue max-size-buffers=2 leaky=downstream ! fbdevsink device=/dev/fb0 sync=false"
}
build_pipeline_any_autovideosink() {
  local dev="$1" w="$2" h="$3" fps="$4" kind="$5"
  case "$kind" in
    yuyv)
      echo "gst-launch-1.0 v4l2src device=${dev} io-mode=mmap ! video/x-raw,format=YUY2,width=${w},height=${h},framerate=${fps}/1 ! videoconvert ! queue max-size-buffers=2 leaky=downstream ! autovideosink sync=false"
      ;;
    mjpg)
      echo "gst-launch-1.0 v4l2src device=${dev} io-mode=mmap ! image/jpeg,width=${w},height=${h},framerate=${fps}/1 ! jpegdec ! videoconvert ! queue max-size-buffers=2 leaky=downstream ! autovideosink sync=false"
      ;;
    h264)
      echo "gst-launch-1.0 v4l2src device=${dev} io-mode=dmabuf ! video/x-h264,stream-format=byte-stream,alignment=au,width=${w},height=${h},framerate=${fps}/1 ! h264parse ! avdec_h264 ! videoconvert ! queue max-size-buffers=2 leaky=downstream ! autovideosink sync=false"
      ;;
  esac
}

run_pipeline() {
  local cmd="$1"
  logD "Pipeline:\n$cmd\n"
  if (( DRY_RUN==1 )); then
    logI "Dry-run: not executing."
    return 0
  fi
  local debug_level="0"
  (( LOG_LEVEL>=2 )) && debug_level="2"
  if (( DURATION>0 )) && have timeout; then
    GST_DEBUG=$debug_level timeout "${DURATION}s" bash -lc "$cmd"
  else
    GST_DEBUG=$debug_level bash -lc "$cmd"
  fi
}

run_with_fallbacks() {
  local dev="$1" w="$2" h="$3" fps="$4" kind="$5" sink="$6"
  local cmd rc=1

  case "$sink" in
    kms)
      if [[ "$kind" == "yuyv" ]]; then
        cmd=$(build_pipeline_yuyv_kms "$dev" "$w" "$h" "$fps");            run_pipeline "$cmd" && return 0 || rc=$?
        cmd=$(build_pipeline_yuyv_kms_nocol "$dev" "$w" "$h" "$fps");       run_pipeline "$cmd" && return 0 || rc=$?
        cmd=$(build_pipeline_mjpg_kms "$dev" "$w" "$h" "$fps");             run_pipeline "$cmd" && return 0 || rc=$?
      elif [[ "$kind" == "h264" ]]; then
        cmd=$(build_pipeline_h264_kms "$dev" "$w" "$h" "$fps");             run_pipeline "$cmd" && return 0 || rc=$?
      elif [[ "$kind" == "mjpg" ]]; then
        cmd=$(build_pipeline_mjpg_kms "$dev" "$w" "$h" "$fps");             run_pipeline "$cmd" && return 0 || rc=$?
      fi
      ;;
    fb)
      if [[ "$kind" == "yuyv" ]]; then
        cmd=$(build_pipeline_yuyv_fb "$dev" "$w" "$h" "$fps");              run_pipeline "$cmd" && return 0 || rc=$?
        cmd=$(build_pipeline_mjpg_fb "$dev" "$w" "$h" "$fps");              run_pipeline "$cmd" && return 0 || rc=$?
      elif [[ "$kind" == "h264" ]]; then
        cmd=$(build_pipeline_h264_fb "$dev" "$w" "$h" "$fps");              run_pipeline "$cmd" && return 0 || rc=$?
      elif [[ "$kind" == "mjpg" ]]; then
        cmd=$(build_pipeline_mjpg_fb "$dev" "$w" "$h" "$fps");              run_pipeline "$cmd" && return 0 || rc=$?
      fi
      ;;
    auto-video)
      cmd=$(build_pipeline_any_autovideosink "$dev" "$w" "$h" "$fps" "$kind"); run_pipeline "$cmd" && return 0 || rc=$?
      ;;
  esac

  # sink fallbacks
  if [[ "$sink" != "kms" ]] && has_drm && gst_has kmssink; then
    logI "Trying KMS fallback…"
    run_with_fallbacks "$dev" "$w" "$h" "$fps" "$kind" "kms" && return 0
  fi
  if [[ "$sink" != "fb" ]] && has_fb && gst_has fbdevsink; then
    logI "Trying fbdev fallback…"
    run_with_fallbacks "$dev" "$w" "$h" "$fps" "$kind" "fb" && return 0
  fi
  if [[ "$sink" != "auto-video" ]]; then
    logI "Trying autovideosink fallback…"
    run_with_fallbacks "$dev" "$w" "$h" "$fps" "$kind" "auto-video" && return 0
  fi

  return $rc
}

# -------------------- Main ------------------------
main() {
  parse_args "$@"

  # Wizard?
  if (( USE_MENU==1 )); then
    show_menu
  elif (( SKIP_MENU==0 )) && [[ $# -eq 0 ]] && is_tty; then
    show_menu
  fi

  check_deps
  unblank_and_backlight

  local dev w h kind sink
  dev=$(detect_device)
  read -r w h < <(parse_wh "$RESOLUTION")

  # Try to lock fps & avoid auto-exposure FPS drop (harmless if unsupported)
  v4l2-ctl -d "$dev" --set-parm "$FPS" >/dev/null 2>&1 || true
  v4l2-ctl -d "$dev" -c exposure_auto_priority=0 >/dev/null 2>&1 || true

  local fmts; fmts="$(probe_formats "$dev")"
  logD "Formats for ${dev}:
${fmts}"

  kind=$(pick_source_kind "$fmts")
  [[ "$kind" != "none" ]] || die "No usable formats (YUYV/H264/MJPG) on ${dev}"

  sink=$(pick_sink_pref)
  logI "Device: ${dev}, chosen kind: ${kind}, ${RESOLUTION}@${FPS}fps, sink: ${sink}"

  if ! run_with_fallbacks "$dev" "$w" "$h" "$FPS" "$kind" "$sink"; then
    echo
    logE "All pipelines failed. Check above GST errors."
    logI "Tips:"
    logI "  • Run on local TTY for KMS; stop desktop: sudo systemctl stop lightdm || sudo systemctl stop display-manager"
    logI "  • Ensure /dev/dri/card* exists for KMS; test: kmscube"
    logI "  • For fbdev, /dev/fb0 must exist; we force RGB16."
    exit 1
  fi
}

main "$@"
