#!/usr/bin/env bash
# =============================================================================
# PiCam H.264 Benchmarking Script (FB0 Edition) — FIXED
# =============================================================================
# Key fixes in this revision:
# - Added `-y -nostdin` to ALL ffmpeg writers/readers so named pipes (/tmp/.../video.h264)
#   and fbdev (/dev/fb0) never trigger "File exists. Overwrite?" prompts.
# - Keeps consumer (display) starting BEFORE producer (camera) to avoid FIFO stalls.
# - Preserves full CLI feature set and behavior; output path is framebuffer (fbdev).
#
# Features:
# - CSI and USB camera support
# - CLI + optional whiptail wizard
# - FPS/bitrate/CPU/MEM overlay (toggleable)
# - Auto-detect HW encoder (h264_v4l2m2m) vs SW (libx264)
# - Auto scale to framebuffer geometry; auto-pick pixel format
# =============================================================================

set -euo pipefail

# =============================================================================
# DEFAULT CONFIGURATION VALUES
# =============================================================================
DEFAULT_METHOD="h264_sdl_preview"    # Back-compat name; renders to fbdev internally
DEFAULT_RESOLUTION="1280x720"
DEFAULT_FPS="30"
DEFAULT_BITRATE="4000000"
DEFAULT_DURATION="0"                  # 0 = infinite
DEFAULT_CORNER="top-left"
DEFAULT_SOURCE="auto"                 # auto | csi | /dev/videoN
DEFAULT_ENCODE="auto"                 # auto | hardware | software
DEFAULT_FBDEV="/dev/fb0"

# =============================================================================
# LOGGING
# =============================================================================
SCRIPT_NAME=$(basename "$0")
LOG_LEVEL=${LOG_LEVEL:-1}  # 0=ERROR, 1=INFO, 2=DEBUG
LOG_FILE=""

ts() { date '+%H:%M:%S.%3N' 2>/dev/null || date '+%H:%M:%S'; }
log() { local lvl="$1" n="$2"; shift 2; [[ "$n" -le "$LOG_LEVEL" ]] || return; local o="[$(ts)] ${lvl}: $*"; [[ -n "$LOG_FILE" ]] && echo "$o" >>"$LOG_FILE" || echo "$o" >&2; }
die() { log "ERROR" 0 "$*"; exit 1; }

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Options:
  -m, --method <name>         Capture method (default: ${DEFAULT_METHOD})
  -r, --resolution WxH        e.g. 1920x1080 (default: ${DEFAULT_RESOLUTION})
  -f, --fps <number>          Frames per second (default: ${DEFAULT_FPS})
  -b, --bitrate <bits>        Target bitrate in bits per second (default: ${DEFAULT_BITRATE})
  -c, --corner <pos>          Overlay: top-left|top-right|bottom-left|bottom-right (default: ${DEFAULT_CORNER})
  -s, --source <src>          auto|csi|/dev/videoN (default: ${DEFAULT_SOURCE})
  -e, --encode <method>       auto|software|hardware (default: ${DEFAULT_ENCODE})
  -d, --duration <sec>        Recording duration (default: ${DEFAULT_DURATION}, 0 = infinite)
      --fb0, --framebuffer    (Compat flag; output is fbdev in this build)
      --fbdev <path>          Framebuffer device (default: ${DEFAULT_FBDEV})
  -v, --verbose               Increase verbosity (repeatable)
      --quiet                 Errors only
      --log-file <path>       Log to file instead of stderr
      --no-menu               Skip wizard
      --menu                  Force wizard
      --no-overlay            Disable stats overlay
      --check-deps            Only verify deps and exit
      --install-deps          Install missing deps and exit
      --debug-cameras         Detailed camera debug and exit
      --test-usb              Quick USB capture test and exit
      --list-cameras          List cameras and exit
  -h, --help                  This help
USAGE
}

# =============================================================================
# HELPERS
# =============================================================================
have(){ command -v "$1" >/dev/null 2>&1; }

parse_res(){
  [[ "$RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]] || die "Bad --resolution '$RESOLUTION' (use WxH)."
  WIDTH="${BASH_REMATCH[1]}"; HEIGHT="${BASH_REMATCH[2]}"
}

cam_cmd(){
  if have libcamera-vid; then echo libcamera-vid
  elif have rpicam-vid; then echo rpicam-vid
  else echo ""; fi
}

has_hw_encoder(){
  [[ -c /dev/video11 ]] && have v4l2-ctl && v4l2-ctl --device=/dev/video11 --info 2>/dev/null | grep -q "bcm2835-codec-encode"
}

pick_encode(){
  case "$ENCODE" in
    hardware) has_hw_encoder && echo hardware || echo software ;;
    software) echo software ;;
    auto)     has_hw_encoder && echo hardware || echo software ;;
    *) die "ENCODE must be auto|hardware|software";;
  esac
}

first_usb_capture(){
  if have v4l2-ctl; then
    for n in /dev/video* 2>/dev/null; do
      [[ -c "$n" ]] || continue
      local info; info="$(v4l2-ctl -d "$n" -D 2>/dev/null || true)"
      grep -qiE 'Driver name:[[:space:]]*uvcvideo' <<<"$info" || continue
      v4l2-ctl -d "$n" -D 2>/dev/null | grep -qi 'Video Capture' && { echo "$n"; return 0; }
    done
  else
    for n in /dev/video* 2>/dev/null; do [[ -c "$n" ]] && { echo "$n"; return 0; }; done
  fi
  return 1
}

detect_source(){
  case "$SOURCE" in
    csi) echo "csi"; return;;
    /dev/video*) [[ -c "$SOURCE" ]] || die "No such device: $SOURCE"; echo "usb"; return;;
    auto)
      local cc; cc="$(cam_cmd)"
      if [[ -n "$cc" ]]; then
        if "$cc" --list-cameras 2>&1 | grep -q "Available cameras" && ! "$cc" --list-cameras 2>&1 | grep -q "usb@"; then
          echo "csi"; return
        fi
      fi
      local u; if u="$(first_usb_capture)"; then SOURCE="$u"; echo "usb"; return; fi
      echo "none"; return;;
    *) die "SOURCE must be auto|csi|/dev/videoN";;
  esac
}

fb_geometry() {
  local w="$WIDTH" h="$HEIGHT" bpp="32"
  if have fbset; then
    local g; g="$(fbset -s 2>/dev/null | tr -s ' ')"
    if [[ "$g" =~ geometry[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+([0-9]+) ]]; then
      w="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"; bpp="${BASH_REMATCH[3]}"
    fi
  fi
  echo "${w}x${h} ${bpp}"
}

fb_pix_fmt_from_bpp(){ case "$1" in 16) echo rgb565le;; 24) echo bgr24;; 30) echo x2rgb10le;; 32) echo xrgb8888;; *) echo xrgb8888;; esac; }

find_font(){
  for f in \
    /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
    /usr/share/fonts/truetype/freefont/FreeSans.ttf \
    /usr/share/fonts/*/*/*.ttf; do
    [[ -f "$f" ]] && { echo "$f"; return; }
  done
  echo ""
}

escape_dt_path(){ local p="$1"; p=${p//\\/\\\\}; p=${p//:/\\:}; echo "$p"; }

any_alive(){ for p in "$@"; do [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
usage_sum(){ ps -p "$@" -o %cpu=,%mem= 2>/dev/null | awk 'BEGIN{c=0;m=0}{c+=$1;m+=$2}END{printf "%.1f %.1f\n",c,m}'; }

ff_has_drawtext(){ ffmpeg -hide_banner -filters 2>/dev/null | grep -q '^ *T.*drawtext'; }
ff_has_fbdev(){ ffmpeg -hide_banner -devices 2>/dev/null | grep -qE 'D[[:space:]]+fbdev'; }

# =============================================================================
# DEPENDENCIES
# =============================================================================
REQUIRED=(libcamera-vid ffmpeg awk ps stdbuf)
OPTIONAL=(whiptail v4l2-ctl fbset)

declare -A PKG=(
  [libcamera-vid]="libcamera-apps"
  [rpicam-vid]="libcamera-apps"
  [ffmpeg]="ffmpeg"
  [awk]="gawk"
  [ps]="procps"
  [stdbuf]="coreutils"
  [whiptail]="whiptail"
  [v4l2-ctl]="v4l-utils"
  [fbset]="fbset"
)

check_deps(){
  local need_whip="$1"
  log "INFO " 1 "Checking dependencies (whiptail required: $need_whip)..."
  local miss=() opt_miss=()
  echo "Checking required commands..."
  for c in "${REQUIRED[@]}"; do
    if [[ "$c" == "libcamera-vid" ]]; then
      if have libcamera-vid; then echo "[OK] libcamera-vid"
      elif have rpicam-vid; then echo "[OK] rpicam-vid (replaces libcamera-vid)"
      else echo "[MISSING] libcamera-vid (pkg: ${PKG[$c]})"; miss+=("$c"); fi
    else
      have "$c" && echo "[OK] $c" || { echo "[MISSING] $c (pkg: ${PKG[$c]})"; miss+=("$c"); }
    fi
  done
  echo; echo "Checking optional commands..."
  for c in "${OPTIONAL[@]}"; do
    if [[ $need_whip -eq 0 && "$c" == "whiptail" ]]; then continue; fi
    have "$c" && echo "[OK] $c" || echo "[OPTIONAL MISSING] $c (pkg: ${PKG[$c]})"
  done
  if have ffmpeg && ! ff_has_fbdev; then
    echo "[WARN] ffmpeg fbdev output not listed; your ffmpeg may lack framebuffer support."
  fi
  ((${#miss[@]}==0)) || return 1
}

collect_pkgs(){
  local cmds=("$@") out=() seen=()
  for c in "${cmds[@]}"; do
    local p="${PKG[$c]:-}"; [[ -z "$p" ]] && continue
    [[ -n "${seen[$p]:-}" ]] || { out+=("$p"); seen[$p]=1; }
  done
  printf '%s\n' "${out[@]}"
}

maybe_sudo(){ if [[ $EUID -eq 0 ]]; then "$@"; elif have sudo; then sudo "$@"; else return 1; fi }
apt_install(){
  local pkgs=("$@"); ((${#pkgs[@]})) || return 0
  have apt-get || { echo "${SCRIPT_NAME}: apt-get required" >&2; return 1; }
  maybe_sudo apt-get update && maybe_sudo apt-get install -y "${pkgs[@]}"
}

ensure_deps(){
  local need_whip="$1" auto="${2:-1}"
  if check_deps "$need_whip"; then return 0; fi
  ((auto==1)) || return 1
  echo "Missing deps detected. Attempting install..."
  local req=("${REQUIRED[@]}")
  (( need_whip==1 )) && req+=("whiptail")
  local pkgs; mapfile -t pkgs < <(collect_pkgs "${req[@]}")
  apt_install "${pkgs[@]}" || return 1
  check_deps "$need_whip"
}

# =============================================================================
# CAMERA DETECTION
# =============================================================================
get_camera_command(){
  if have libcamera-vid; then echo libcamera-vid
  elif have rpicam-vid; then echo rpicam-vid
  else echo libcamera-vid; fi
}

has_video_capture_capability(){ local h="${1#0x}"; local d=$((16#$h)); (( d & 0x00000001 )); }

is_usb_capture_node(){
  local dev="$1"; [[ -c "$dev" ]] || return 1
  if have v4l2-ctl; then
    local info; info=$(v4l2-ctl -d "$dev" -D 2>/dev/null || true)
    grep -qiE 'Driver name:[[:space:]]*uvcvideo' <<<"$info" || return 1
    local caps; caps=$(grep -E 'Capabilities.*0x' <<<"$info" | head -1 || true)
    if [[ $caps =~ 0x([0-9a-fA-F]+) ]] && has_video_capture_capability "${BASH_REMATCH[1]}"; then return 0; fi
    grep -qi 'Video Capture' <<<"$info" && return 0
  fi
  local n; n=$(basename "$dev")
  [[ -f "/sys/class/video4linux/$n/device/uevent" ]] && grep -q "DRIVER=uvcvideo" "/sys/class/video4linux/$n/device/uevent"
}

select_usb_capture_device(){
  is_usb_capture_node "/dev/video0" && { echo "/dev/video0"; return; }
  local d; for d in /dev/video* 2>/dev/null; do is_usb_capture_node "$d" && { echo "$d"; return; }; done
  return 1
}

detect_cameras(){
  local csi=0 usb=0 usb_dev=""
  local cc; cc="$(get_camera_command)"
  if have "$cc"; then
    local out; out=$("$cc" --list-cameras 2>&1 || true)
    if grep -q "Available cameras" <<<"$out" && ! grep -q "ERROR.*no cameras available" <<<"$out"; then
      grep -qv "usb@" <<<"$out" && csi=1
    fi
  fi
  if ls /dev/video* >/dev/null 2>&1; then
    local d; d=$(select_usb_capture_device || true)
    if [[ -n "$d" ]]; then usb=1; usb_dev="$d"; fi
  fi
  echo "csi_available=$csi usb_available=$usb usb_device=$usb_dev"
}

get_camera_type(){
  case "$SOURCE" in
    csi) echo "csi"; return;;
    /dev/video*) [[ -c "$SOURCE" ]] && echo "usb" || echo "none"; return;;
    auto) ;;
    *) die "Invalid --source '$SOURCE'";;
  esac
  local det; det=$(detect_cameras); eval "$det"
  (( csi_available==1 )) && { echo "csi"; return; }
  (( usb_available==1 )) && { echo "usb"; return; }
  echo "none"
}

# =============================================================================
# ARGUMENTS
# =============================================================================
parse_args(){
  local parsed
  parsed=$(getopt -o m:r:f:b:c:s:e:d:vh --long method:,resolution:,fps:,bitrate:,corner:,source:,encode:,duration:,verbose,quiet,log-file:,help,menu,no-menu,no-overlay,check-deps,install-deps,debug-cameras,test-usb,list-cameras,fb0,framebuffer,fbdev: -- "$@") || { usage; exit 1; }
  eval set -- "$parsed"
  while true; do
    case "$1" in
      -m|--method)       METHOD="$2"; shift 2;;
      -r|--resolution)   RESOLUTION="$2"; shift 2;;
      -f|--fps)          FPS="$2"; shift 2;;
      -b|--bitrate)      BITRATE="$2"; shift 2;;
      -c|--corner)       OVERLAY_CORNER="$2"; shift 2;;
      -s|--source)       SOURCE="$2"; shift 2;;
      -e|--encode)       ENCODE="$2"; shift 2;;
      -d|--duration)     DURATION="$2"; shift 2;;
      --fb0|--framebuffer) USE_FRAMEBUFFER=1; shift;;
      --fbdev)           FBDEV="$2"; shift 2;;
      -v|--verbose)      ((LOG_LEVEL++)); shift;;
      --quiet)           LOG_LEVEL=0; shift;;
      --log-file)        LOG_FILE="$2"; shift 2;;
      --menu)            FORCE_MENU=1; shift;;
      --no-menu)         SKIP_MENU=1; shift;;
      --no-overlay)      NO_OVERLAY=1; shift;;
      --check-deps)      CHECK_DEPS_ONLY=1; shift;;
      --install-deps)    INSTALL_DEPS_ONLY=1; shift;;
      --debug-cameras)   DEBUG_CAMERAS_ONLY=1; shift;;
      --test-usb)        USB_TEST_ONLY=1; shift;;
      --list-cameras)    LIST_CAMERAS_ONLY=1; shift;;
      -h|--help)         usage; exit 0;;
      --) shift; break;;
      *) die "Unexpected arg: $1";;
    esac
  done
}

validate_num(){ [[ "$1" =~ ^[0-9]+$ ]] || die "Invalid $2: '$1'"; }
validate_corner(){
  case "$1" in top-left|top-right|bottom-left|bottom-right) ;; *) die "Invalid corner '$1'";; esac
}
validate_encode(){ case "$1" in auto|software|hardware) ;; *) die "Invalid encode '$1'";; esac

overlay_pos(){
  case "$1" in
    top-left)     OVERLAY_X="10"; OVERLAY_Y="10";;
    top-right)    OVERLAY_X="w-tw-10"; OVERLAY_Y="10";;
    bottom-left)  OVERLAY_X="10"; OVERLAY_Y="h-th-10";;
    bottom-right) OVERLAY_X="w-tw-10"; OVERLAY_Y="h-th-10";;
  esac
}

# =============================================================================
# UI (WIZARD)
# =============================================================================
show_wizard(){
  local m; m=$(whiptail --title "PiCam Benchmark" --menu "Select method" 20 78 10 \
     "h264_sdl_preview" "Camera -> H.264 -> fbdev" 3>&1 1>&2 2>&3) || exit 1
  METHOD="$m"
  local r; r=$(whiptail --title "Resolution" --inputbox "WIDTHxHEIGHT" 8 60 "$RESOLUTION" 3>&1 1>&2 2>&3) || exit 1; RESOLUTION="$r"
  local f; f=$(whiptail --title "FPS" --inputbox "Frames per second" 8 60 "$FPS" 3>&1 1>&2 2>&3) || exit 1; FPS="$f"
  local br; br=$(whiptail --title "Bitrate" --inputbox "bits per second" 8 60 "$BITRATE" 3>&1 1>&2 2>&3) || exit 1; BITRATE="$br"
  local c; c=$(whiptail --title "Overlay corner" --menu "Choose" 15 60 4 top-left "" top-right "" bottom-left "" bottom-right "" 3>&1 1>&2 2>&3) || exit 1; OVERLAY_CORNER="$c"
  local src_opts=("auto" "Auto (CSI preferred)"); local cc; cc="$(get_camera_command)"
  if [[ -n "$cc" ]] && "$cc" --list-cameras --timeout 1000 2>/dev/null | grep -q "Available cameras"; then src_opts+=("csi" "CSI Camera"); fi
  if ls /dev/video* >/dev/null 2>&1; then
    local d; for d in /dev/video*; do [[ -c "$d" ]] && src_opts+=("$d" "USB"); done
  fi
  if ((${#src_opts[@]}>2)); then
    local s; s=$(whiptail --title "Source" --menu "Select camera" 20 78 10 "${src_opts[@]}" 3>&1 1>&2 2>&3) || exit 1; SOURCE="$s"
  fi
  local enc_opts=("auto" "Auto" "software" "libx264")
  has_hw_encoder && enc_opts+=("hardware" "h264_v4l2m2m")
  if ((${#enc_opts[@]}>2)); then
    local e; e=$(whiptail --title "Encoding" --menu "Select" 15 78 10 "${enc_opts[@]}" 3>&1 1>&2 2>&3) || exit 1; ENCODE="$e"
  fi
}

# =============================================================================
# OVERLAY + MONITOR
# =============================================================================
compute_overlay_xy(){ case "$1" in top-left) echo "10 10";; top-right) echo "w-tw-10 10";; bottom-left) echo "10 h-th-10";; bottom-right) echo "w-tw-10 h-th-10";; esac; }

monitor_metrics(){
  local stats="$1" flog="$2" w="$3" h="$4" bps="$5" fps_target="$6"; shift 6
  local fps="$fps_target" br; br=$(awk -v b="$bps" 'BEGIN{printf "%.1f Mbps", b/1000000}')
  while any_alive "$@"; do
    [[ -f "$stats" ]] || break
    if [[ -s "$flog" ]]; then
      local line; line="$(tail -n 5 "$flog" | tr '\r' '\n' | tail -n 1)"
      [[ "$line" =~ fps=([0-9.]+) ]] && fps="${BASH_REMATCH[1]}"
      if [[ "$line" =~ bitrate=([^[:space:]]+) ]] && [[ ${BASH_REMATCH[1]} != "N/A" ]]; then br="${BASH_REMATCH[1]}"; fi
    fi
    local u cpu mem; u="$(usage_sum "$@")"; cpu="$(awk '{print $1}' <<<"$u")"; mem="$(awk '{print $2}' <<<"$u")"
    {
      printf "FPS: %s\n" "$fps"
      printf "RES: %sx%s\n" "$w" "$h"
      printf "BitRate: %s\n" "$br"
      printf "CPU: %s%%%%\n" "$cpu"
      printf "MEM: %s%%%%\n" "$mem"
    } > "$stats"
    sleep 1
  done
}

# =============================================================================
# CAPTURE LEGS (→ H.264 FIFO)
# =============================================================================
run_csi_h264_capture(){
  parse_res
  local ms=0; (( DURATION>0 )) && ms=$((DURATION*1000))
  local cc; cc="$(get_camera_command)"
  log "INFO " 1 "Starting CSI: ${cc} ${WIDTH}x${HEIGHT}@${FPS}, bitrate=${BITRATE}, timeout=${ms}ms"
  stdbuf -oL "$cc" --inline --codec h264 --timeout "$ms" \
    --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
    --bitrate "$BITRATE" -o - > "$1" &
  echo $!
}

pick_usb_infmt(){
  local dev="$1" fmt=""
  if have v4l2-ctl; then
    local f; f=$(v4l2-ctl -d "$dev" --list-formats-ext 2>/dev/null || true)
    if grep -q "H264" <<<"$f"; then fmt="h264"
    elif grep -q "MJPG" <<<"$f"; then fmt="mjpeg"
    elif grep -q "YUYV" <<<"$f"; then fmt="yuyv422"
    fi
  fi
  echo "$fmt"
}

run_usb_h264_capture(){
  parse_res
  local dev="$SOURCE"
  if [[ ! "$dev" =~ ^/dev/video[0-9]+$ ]]; then
    local det; det=$(detect_cameras); eval "$det"
    (( usb_available==1 )) || die "No USB camera found"
    dev="$usb_device"
  fi
  local enc; enc="$(pick_encode)"
  local infmt; infmt="$(pick_usb_infmt "$dev")"
  local dur=(); (( DURATION>0 )) && dur=(-t "$DURATION")

  log "INFO " 1 "Starting USB: ${dev} ${WIDTH}x${HEIGHT}@${FPS} input=${infmt:-auto} encode=${enc}"

  local inargs=(-f v4l2 -video_size "${WIDTH}x${HEIGHT}" -framerate "${FPS}" -i "${dev}")
  [[ -n "$infmt" ]] && inargs=(-f v4l2 -input_format "$infmt" -video_size "${WIDTH}x${HEIGHT}" -framerate "${FPS}" -i "${dev}")

  if [[ "$enc" == "hardware" ]]; then
    if [[ "$infmt" == "h264" ]]; then
      stdbuf -oL ffmpeg -nostdin -y -hide_banner -loglevel info -stats \
        "${inargs[@]}" "${dur[@]}" \
        -c:v copy -f h264 "$1" &
    else
      stdbuf -oL ffmpeg -nostdin -y -hide_banner -loglevel info -stats \
        "${inargs[@]}" "${dur[@]}" \
        -pix_fmt nv12 -c:v h264_v4l2m2m \
        -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize $((BITRATE*2)) \
        -f h264 "$1" &
    fi
  else
    stdbuf -oL ffmpeg -nostdin -y -hide_banner -loglevel info -stats \
      "${inargs[@]}" "${dur[@]}" \
      -c:v libx264 -preset ultrafast -tune zerolatency \
      -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize $((BITRATE*2)) \
      -f h264 "$1" &
  fi
  echo $!
}

# =============================================================================
# DISPLAY LEG (H.264 FIFO → decode → fbdev)
# =============================================================================
start_fb_display(){
  local fifo_in="$1" stats_file="$2" flog="$3" corner="$4" fb="$5"

  local geo bpp fmt
  read -r geo bpp <<<"$(fb_geometry)"
  fmt="$(fb_pix_fmt_from_bpp "$bpp")"
  log "INFO " 1 "Framebuffer ${fb}: geometry=${geo}, bpp=${bpp}, pix_fmt=${fmt}"

  local draw=""
  if (( NO_OVERLAY==0 )) && ff_has_drawtext; then
    local font; font="$(find_font)"
    local ox oy; read -r ox oy <<<"$(compute_overlay_xy "$corner")"
    if [[ -n "$font" ]]; then
      draw="drawtext=fontfile=$(escape_dt_path "$font"):textfile=$(escape_dt_path "$stats_file"):reload=1:x=${ox}:y=${oy}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
    else
      draw="drawtext=textfile=$(escape_dt_path "$stats_file"):reload=1:x=${ox}:y=${oy}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
    fi
  elif (( NO_OVERLAY==0 )); then
    log "INFO " 1 "drawtext not available; overlay disabled."
    NO_OVERLAY=1
  fi

  local vf="scale=${geo}"
  [[ -n "$draw" ]] && vf="${draw},${vf}"

  ff_has_fbdev || log "ERROR" 0 "ffmpeg fbdev output not listed; attempting anyway."

  # IMPORTANT: -y -nostdin here prevents "fb0 exists, overwrite?" prompts.
  stdbuf -oL -eL ffmpeg -nostdin -y -hide_banner -loglevel info -stats \
    -fflags +nobuffer -flags +low_delay -reorder_queue_size 0 -thread_queue_size 512 \
    -f h264 -i "$fifo_in" \
    -vf "${vf}" -pix_fmt "${fmt}" -an -f fbdev "${fb}" \
    2> >(stdbuf -oL tee "$flog" >&2) &
  echo $!
}

# =============================================================================
# PIPELINE ORCHESTRATION (ALWAYS FBDEV)
# =============================================================================
run_csi_pipeline_fbdev(){
  parse_res; overlay_pos "$OVERLAY_CORNER"
  local tmp="$(mktemp -d)" fifo="$tmp/video.h264" stats="$(mktemp /tmp/picam_stats.XXXXXX)" flog="$(mktemp /tmp/picam_ffmpeg.XXXXXX)"
  mkfifo "$fifo"
  local ffpid campid monpid
  cleanup(){ trap - EXIT INT TERM; kill "$monpid" "$campid" "$ffpid" 2>/dev/null || true; wait "$monpid" "$campid" "$ffpid" 2>/dev/null || true; rm -rf "$tmp" "$stats" "$flog"; }
  trap cleanup EXIT INT TERM
  ffpid="$(start_fb_display "$fifo" "$stats" "$flog" "$OVERLAY_CORNER" "$FBDEV")"
  campid="$(run_csi_h264_capture "$fifo")"
  (( NO_OVERLAY==0 )) && { monitor_metrics "$stats" "$flog" "$WIDTH" "$HEIGHT" "$BITRATE" "$FPS" "$campid" "$ffpid" & monpid=$!; } || monpid=""
  log "INFO " 1 "Waiting for pipeline processes..."
  wait "$campid" 2>/dev/null || true; wait "$ffpid" 2>/dev/null || true; [[ -n "$monpid" ]] && wait "$monpid" 2>/dev/null || true
  cleanup
}

run_usb_pipeline_fbdev(){
  parse_res; overlay_pos "$OVERLAY_CORNER"
  local tmp="$(mktemp -d)" fifo="$tmp/video.h264" stats="$(mktemp /tmp/picam_stats.XXXXXX)" flog="$(mktemp /tmp/picam_ffmpeg.XXXXXX)"
  mkfifo "$fifo"
  local ffpid campid monpid
  cleanup(){ trap - EXIT INT TERM; kill "$monpid" "$campid" "$ffpid" 2>/dev/null || true; wait "$monpid" "$campid" "$ffpid" 2>/dev/null || true; rm -rf "$tmp" "$stats" "$flog"; }
  trap cleanup EXIT INT TERM
  ffpid="$(start_fb_display "$fifo" "$stats" "$flog" "$OVERLAY_CORNER" "$FBDEV")"
  campid="$(run_usb_h264_capture "$fifo")"
  (( NO_OVERLAY==0 )) && { monitor_metrics "$stats" "$flog" "$WIDTH" "$HEIGHT" "$BITRATE" "$FPS" "$campid" "$ffpid" & monpid=$!; } || monpid=""
  log "INFO " 1 "Waiting for pipeline processes..."
  wait "$campid" 2>/dev/null || true; wait "$ffpid" 2>/dev/null || true; [[ -n "$monpid" ]] && wait "$monpid" 2>/dev/null || true
  cleanup
}

start_capture(){
  local type; type="$(get_camera_type)"
  case "$METHOD" in
    h264_sdl_preview|h264_fb_preview|h264_fb0_preview)
      case "$type" in
        csi) echo "Using CSI camera module..."; run_csi_pipeline_fbdev;;
        usb) echo "Using USB camera...";      run_usb_pipeline_fbdev;;
        none) die "No supported camera found (CSI/USB).";;
      esac
      ;;
    *) die "Unsupported method '$METHOD'";;
  esac
}

# =============================================================================
# DIAGNOSTICS (unchanged)
# =============================================================================
list_cams(){
  echo "=== Available Cameras ==="; echo
  local cc; cc="$(get_camera_command)"
  echo "Checking for CSI camera..."
  if "$cc" --list-cameras --timeout 1000 2>/dev/null | grep -q "Available cameras"; then
    echo "✓ CSI Camera detected (use: --source csi)"
    "$cc" --list-cameras --timeout 1000 2>/dev/null | head -10
  else
    echo "✗ No CSI camera detected"
  fi
  echo; echo "Checking for USB cameras..."
  local found=0
  if ls /dev/video* >/dev/null 2>&1; then
    local d
    for d in /dev/video*; do
      [[ -c "$d" ]] || continue
      if have v4l2-ctl; then
        local info; info=$(v4l2-ctl -d "$d" --all 2>/dev/null || true)
        if echo "$info" | grep -qi "bcm2835\|codec\|isp"; then continue; fi
        if echo "$info" | grep -qiE "Driver name:[[:space:]]*uvcvideo" && echo "$info" | grep -qi "Capabilities:.*Video Capture"; then
          echo "✓ USB Camera: $d (use: --source $d)"; echo "$info" | head -3 | sed 's/^/  /'; echo; found=1
        fi
      else
        echo "? Possible USB Camera: $d (use: --source $d)"; found=1
      fi
    done
  fi
  ((found==1)) || echo "✗ No USB cameras detected"
}

debug_cams(){
  local cc; cc="$(get_camera_command)"
  echo "=== Camera command detection ==="; echo "Preferred: $cc"; echo
  if have dpkg; then
    echo "=== libcamera-apps contents ==="
    dpkg -L libcamera-apps 2>/dev/null | grep -E '/bin/' || echo "libcamera-apps not installed or no /bin binaries."
  fi
  echo; echo "=== PATH search ==="
  have libcamera-vid && echo "libcamera-vid -> $(command -v libcamera-vid)" || echo "libcamera-vid not found"
  have rpicam-vid   && echo "rpicam-vid   -> $(command -v rpicam-vid)"   || echo "rpicam-vid not found"
  echo; echo "=== --list-cameras ==="
  if have "$cc"; then "$cc" --list-cameras 2>&1 || true; else echo "Camera cmd '$cc' unavailable"; fi
  echo; echo "=== Summary ==="
  local det; det=$(detect_cameras); eval "$det"
  echo "CSI: $csi_available  USB: $usb_available  USB dev: ${usb_device:-<none>}  Type: $(get_camera_type)"
}

usb_test(){
  echo "=== USB camera diagnostic ==="
  ls -la /dev/video* 2>/dev/null || echo "No /dev/video*"
  parse_res
  local dev="" fmt=""
  if ls /dev/video* >/dev/null 2>&1; then
    if have v4l2-ctl; then
      for d in /dev/video*; do
        [[ -c "$d" ]] || continue
        local f; f=$(v4l2-ctl -d "$d" --list-formats-ext 2>/dev/null)
        if grep -q "H264" <<<"$f"; then dev="$d"; fmt="h264"; break
        elif grep -q "MJPG" <<<"$f"; then dev="$d"; fmt="mjpeg"; break
        elif grep -q "YUYV" <<<"$f"; then dev="$d"; fmt="yuyv422"; break
        fi
      done
    else
      for d in /dev/video*; do [[ -c "$d" ]] && { dev="$d"; fmt="mjpeg"; break; }; done
    fi
  fi
  [[ -n "$dev" ]] || { echo "No suitable USB camera."; return 1; }
  have ffmpeg || { echo "ffmpeg required"; return 1; }
  echo "Test: $dev fmt=$fmt"
  local args=(-f v4l2 -video_size "${WIDTH}x${HEIGHT}" -framerate "$FPS" -i "$dev")
  [[ -n "$fmt" ]] && args=(-f v4l2 -input_format "$fmt" -video_size "${WIDTH}x${HEIGHT}" -framerate "$FPS" -i "$dev")
  if ! ffmpeg -nostdin -y "${args[@]}" -t 5 -f null - 2>&1 | tail -n 20; then
    echo "USB test failed."; return 1
  fi
  echo "USB test ok."
}

# =============================================================================
# MAIN
# =============================================================================
main(){
  LOG_LEVEL=${LOG_LEVEL:-1}; LOG_FILE=${LOG_FILE:-""}
  METHOD="$DEFAULT_METHOD"; RESOLUTION="$DEFAULT_RESOLUTION"; FPS="$DEFAULT_FPS"; BITRATE="$DEFAULT_BITRATE"
  OVERLAY_CORNER="$DEFAULT_CORNER"; SOURCE="$DEFAULT_SOURCE"; ENCODE="$DEFAULT_ENCODE"; DURATION="$DEFAULT_DURATION"
  USE_FRAMEBUFFER=1; FBDEV="$DEFAULT_FBDEV"; SKIP_MENU=0; FORCE_MENU=0; NO_OVERLAY=0
  CHECK_DEPS_ONLY=0; INSTALL_DEPS_ONLY=0; DEBUG_CAMERAS_ONLY=0; USB_TEST_ONLY=0; LIST_CAMERAS_ONLY=0

  local argc=$#
  parse_args "$@"

  [[ -n "$LOG_FILE" ]] && log "INFO " 1 "Logging to: $LOG_FILE"
  log "INFO " 1 "${SCRIPT_NAME} starting with config: ${RESOLUTION}@${FPS}fps, bitrate=${BITRATE}, source=${SOURCE}, encode=${ENCODE}, duration=${DURATION}s"

  local show_menu=0 need_whip=0
  if (( SKIP_MENU==0 )); then
    if (( FORCE_MENU==1 )) || { (( argc==0 )) && -t 0 && -t 1; }; then show_menu=1; need_whip=1; fi
  fi

  (( DEBUG_CAMERAS_ONLY )) && { debug_cams; exit 0; }
  (( USB_TEST_ONLY )) && { ensure_deps 0 1 || die "Deps missing"; usb_test && exit 0 || exit 1; }
  (( LIST_CAMERAS_ONLY )) && { list_cams; exit 0; }
  (( CHECK_DEPS_ONLY )) && { ensure_deps "$need_whip" 0 && exit 0 || exit 1; }
  (( INSTALL_DEPS_ONLY )) && { ensure_deps "$need_whip" 1 && exit 0 || die "Dependency install failed"; }

  ensure_deps "$need_whip" 1 || die "Dependencies remain missing."
  [[ -e "$FBDEV" ]] || die "Framebuffer '$FBDEV' not found."
  [[ -w "$FBDEV" ]] || log "INFO " 1 "Note: '$FBDEV' not writable by current user; use sudo."

  (( show_menu==1 )) && show_wizard

  parse_res; validate_num "$FPS" "FPS"; validate_num "$BITRATE" "bitrate"; validate_corner "$OVERLAY_CORNER"; validate_encode "$ENCODE"; validate_num "$DURATION" "duration"

  # Inform about legacy method name
  [[ "$METHOD" == "h264_sdl_preview" ]] && log "INFO " 1 "Method '${METHOD}' selected; display is framebuffer (fbdev) in this build."

  start_capture
}

start_capture(){
  local type; type="$(get_camera_type)"
  case "$METHOD" in
    h264_sdl_preview|h264_fb_preview|h264_fb0_preview)
      case "$type" in
        csi) echo "Using CSI camera..."; run_csi_pipeline_fbdev;;
        usb) echo "Using USB camera..."; run_usb_pipeline_fbdev;;
        none) die "No supported camera found. Connect a CSI or USB camera.";;
      esac
      ;;
    *) die "Unsupported method '$METHOD'";;
  esac
}

main "$@"