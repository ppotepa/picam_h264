#!/usr/bin/env bash
# picam_h264_fb0.sh
# Camera -> H.264 (HW if available, else SW) -> decode -> /dev/fb0 (with live stats)
# Works with CSI via libcamera/rpicam and USB via v4l2 (/dev/videoN).
# No SDL, no auto-apt; just clean checks and a tight pipeline.

set -euo pipefail

# -----------------------------
# Defaults
# -----------------------------
RESOLUTION="${RESOLUTION:-1280x720}"   # WIDTHxHEIGHT
FPS="${FPS:-30}"
BITRATE="${BITRATE:-4000000}"          # bits/s
DURATION="${DURATION:-0}"              # 0 = infinite
SOURCE="${SOURCE:-auto}"               # auto | csi | /dev/videoN
ENCODE="${ENCODE:-auto}"               # auto | hardware | software
OVERLAY="${OVERLAY:-1}"                # 1=on, 0=off
FB_DEV="${FB_DEV:-/dev/fb0}"

# -----------------------------
# Mini arg parser
# -----------------------------
usage() {
  cat <<EOF
Usage: $0 [options]
  -s, --source <auto|csi|/dev/videoN>
  -r, --resolution <WxH>      (default ${RESOLUTION})
  -f, --fps <N>               (default ${FPS})
  -b, --bitrate <bits>        (default ${BITRATE})
  -d, --duration <sec>        (default ${DURATION}, 0 = infinite)
  -e, --encode <auto|hardware|software> (default ${ENCODE})
      --no-overlay            (disable text overlay)
      --fb <path>             (default ${FB_DEV})
  -h, --help
Examples:
  $0 --source auto
  $0 -s /dev/video0 -r 1920x1080 -f 25 -b 6000000 -e hardware
EOF
}

if [[ $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--source) SOURCE="$2"; shift 2 ;;
      -r|--resolution) RESOLUTION="$2"; shift 2 ;;
      -f|--fps) FPS="$2"; shift 2 ;;
      -b|--bitrate) BITRATE="$2"; shift 2 ;;
      -d|--duration) DURATION="$2"; shift 2 ;;
      -e|--encode) ENCODE="$2"; shift 2 ;;
      --no-overlay) OVERLAY=0; shift ;;
      --fb) FB_DEV="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done
fi

# -----------------------------
# Helpers
# -----------------------------
die(){ echo "[ERR] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
parse_res(){
  [[ "$RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]] || die "Bad RESOLUTION '$RESOLUTION' (use WxH)."
  WIDTH="${BASH_REMATCH[1]}"; HEIGHT="${BASH_REMATCH[2]}"
}

cam_cmd(){
  if have libcamera-vid; then echo libcamera-vid
  elif have rpicam-vid; then echo rpicam-vid
  else echo ""; fi
}

has_hw_encoder(){ [[ -c /dev/video11 ]] && have v4l2-ctl && v4l2-ctl --device=/dev/video11 --info 2>/dev/null | grep -q "bcm2835-codec-encode"; }

pick_encode(){
  case "$ENCODE" in
    hardware) if has_hw_encoder; then echo "hardware"; else echo "software"; fi ;;
    software) echo "software" ;;
    auto)     if has_hw_encoder; then echo "hardware"; else echo "software"; fi ;;
    *) die "ENCODE must be auto|hardware|software";;
  esac
}

first_usb_capture(){
  # Friendly pick for /dev/video*
  if have v4l2-ctl; then
    for n in /dev/video*; do
      [[ -c "$n" ]] || continue
      local info; info="$(v4l2-ctl --device="$n" -D 2>/dev/null || true)"
      grep -qiE 'Driver name:[[:space:]]*uvcvideo' <<<"$info" || continue
      v4l2-ctl --device="$n" -D 2>/dev/null | grep -qi 'Video Capture' && { echo "$n"; return 0; }
    done
  else
    # Best effort
    for n in /dev/video*; do [[ -c "$n" ]] && { echo "$n"; return 0; }; done
  fi
  return 1
}

detect_source(){
  case "$SOURCE" in
    csi) echo "csi"; return;;
    /dev/video*) [[ -c "$SOURCE" ]] || die "No such device: $SOURCE"; echo "usb"; return;;
    auto)
      # Prefer CSI if libcamera reports any non-usb@
      local cc; cc="$(cam_cmd)"
      if [[ -n "$cc" ]]; then
        if "$cc" --list-cameras 2>&1 | grep -q "Available cameras" && ! "$cc" --list-cameras 2>&1 | grep -q "usb@"; then
          echo "csi"; return
        fi
      fi
      local u; if u="$(first_usb_capture)"; then echo "usb"; SOURCE="$u"; return; fi
      echo "none"; return;;
    *) die "SOURCE must be auto|csi|/dev/videoN";;
  esac
}

fb_size(){
  # Get framebuffer WxH (for scaling); fallback to input size
  if have fbset; then
    local g; g="$(fbset -s 2>/dev/null | grep -o 'geometry[^0-9]*[0-9]\+ [0-9]\+' || true)"
    if [[ "$g" =~ ([0-9]+)[[:space:]]+([0-9]+) ]]; then
      echo "${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"; return
    fi
  fi
  echo "${RESOLUTION}"
}

find_font(){
  for f in \
    /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
    /usr/share/fonts/truetype/freefont/FreeSans.ttf \
    /usr/share/fonts/*/*/*.ttf; do
    [[ -f "$f" ]] && { echo "$f"; return; }
  done
  echo ""  # ffmpeg can draw without fontfile, but better with.
}

# -----------------------------
# Sanity checks
# -----------------------------
[[ -w "$FB_DEV" ]] || die "Cannot write to ${FB_DEV}. Are you root? Does it exist?"
have ffmpeg || die "ffmpeg required."
parse_res

camera_type="$(detect_source)"
[[ "$camera_type" != "none" ]] || die "No camera found (CSI or USB)."

if [[ "$camera_type" == "csi" ]]; then
  [[ -n "$(cam_cmd)" ]] || die "libcamera-vid / rpicam-vid not found (needed for CSI)."
fi

# -----------------------------
# Temp + cleanup
# -----------------------------
TMPDIR="$(mktemp -d)"
VIDEO_FIFO="${TMPDIR}/video.h264"
STATS_TXT="${TMPDIR}/stats.txt"
FFLOG_DISP="${TMPDIR}/ffmpeg_display.log"
mkfifo "${VIDEO_FIFO}"
: >"$STATS_TXT"; : >"$FFLOG_DISP"

cleanup(){
  trap - EXIT INT TERM
  rm -rf "$TMPDIR" || true
}
trap cleanup EXIT INT TERM

# -----------------------------
# Overlay + display (always /dev/fb0)
# -----------------------------
FB_SIZE="$(fb_size)"
FONT="$(find_font)"
DRAW=""
if [[ "$OVERLAY" -eq 1 ]]; then
  if [[ -n "$FONT" ]]; then
    DRAW="drawtext=fontfile='${FONT}':textfile='${STATS_TXT}':reload=1:x=10:y=10:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
  else
    DRAW="drawtext=textfile='${STATS_TXT}':reload=1:x=10:y=10:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
  fi
fi

VF_CHAIN=""
if [[ -n "$DRAW" ]]; then
  VF_CHAIN="$DRAW,scale=${FB_SIZE}"
else
  VF_CHAIN="scale=${FB_SIZE}"
fi

# Start the display leg: H.264 -> decode -> fbdev
# Keep stats in a separate log we can parse.
stdbuf -oL -eL ffmpeg -hide_banner -loglevel info -stats \
  -fflags +nobuffer -flags +low_delay -reorder_queue_size 0 -thread_queue_size 512 \
  -f h264 -i "${VIDEO_FIFO}" \
  -vf "${VF_CHAIN}" -an -f fbdev "${FB_DEV}" \
  2> >(stdbuf -oL tee "${FFLOG_DISP}" >&2) &
FFMPEG_DISP_PID=$!

# -----------------------------
# Minimal stats monitor
# -----------------------------
get_usage(){
  local pids=("$@")
  ps -p "${pids[@]}" -o %cpu=,%mem= 2>/dev/null | awk 'BEGIN{c=0;m=0}{c+=$1;m+=$2}END{printf "%.1f %.1f\n", c, m}'
}

monitor(){
  local enc_pid="$1"
  local disp_pid="$2"
  local fps="$FPS"
  local br="$(awk -v b="$BITRATE" 'BEGIN{printf "%.1f Mbps", b/1000000}')"
  while kill -0 "$disp_pid" >/dev/null 2>&1 || kill -0 "$enc_pid" >/dev/null 2>&1; do
    if [[ -s "$FFLOG_DISP" ]]; then
      local line; line="$(tail -n 3 "$FFLOG_DISP" | tr '\r' '\n' | tail -n 1)"
      [[ "$line" =~ fps=([0-9\.]+) ]] && fps="${BASH_REMATCH[1]}"
      if [[ "$line" =~ bitrate=([^[:space:]]+) ]] && [[ ${BASH_REMATCH[1]} != "N/A" ]]; then br="${BASH_REMATCH[1]}"; fi
    fi
    local usage; usage="$(get_usage "$enc_pid" "$disp_pid")"
    local cpu mem; cpu="$(awk '{print $1}' <<<"$usage")"; mem="$(awk '{print $2}' <<<"$usage")"
    {
      printf "FPS: %s\n" "$fps"
      printf "RES: %sx%s\n" "$WIDTH" "$HEIGHT"
      printf "BitRate: %s\n" "$br"
      printf "CPU: %s%%%%\n" "$cpu"
      printf "MEM: %s%%%%\n" "$mem"
    } > "$STATS_TXT"
    sleep 1
  done
}

# -----------------------------
# Capture/encode leg (produces H.264 into FIFO)
# -----------------------------
start_csi(){
  local cc; cc="$(cam_cmd)"
  local ms=$(( DURATION * 1000 ))
  echo "[INFO] CSI: ${cc} ${RESOLUTION}@${FPS} bitrate=${BITRATE} -> H.264 FIFO"
  stdbuf -oL "$cc" --inline --codec h264 --timeout "$ms" \
    --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
    --bitrate "$BITRATE" -o - > "${VIDEO_FIFO}" &
  echo $!
}

pick_usb_infmt(){
  local dev="$1"
  local fmt=""
  if have v4l2-ctl; then
    local f; f="$(v4l2-ctl --device="$dev" --list-formats-ext 2>/dev/null || true)"
    if grep -q "H264" <<<"$f"; then fmt="h264"
    elif grep -q "MJPG" <<<"$f"; then fmt="mjpeg"
    elif grep -q "YUYV" <<<"$f"; then fmt="yuyv422"
    fi
  fi
  echo "$fmt"
}

start_usb(){
  local dev="$1"
  local enc_mode; enc_mode="$(pick_encode)"
  local infmt; infmt="$(pick_usb_infmt "$dev")"
  local duration_args=()
  [[ "$DURATION" -gt 0 ]] && duration_args=(-t "$DURATION")

  echo "[INFO] USB: ${dev} ${RESOLUTION}@${FPS} input=${infmt:-auto} encode=${enc_mode} -> H.264 FIFO"

  # Build input args
  local input_args=(-f v4l2 -video_size "${RESOLUTION}" -framerate "${FPS}" -i "${dev}")
  [[ -n "$infmt" ]] && input_args=(-f v4l2 -input_format "$infmt" -video_size "${RESOLUTION}" -framerate "${FPS}" -i "${dev}")

  if [[ "$enc_mode" == "hardware" ]]; then
    if [[ "$infmt" == "h264" ]]; then
      # Camera already gives H.264 → copy
      stdbuf -oL ffmpeg -hide_banner -loglevel info -stats \
        "${input_args[@]}" "${duration_args[@]}" \
        -c:v copy -f h264 "${VIDEO_FIFO}" &
    else
      # HW encode via v4l2m2m
      stdbuf -oL ffmpeg -hide_banner -loglevel info -stats \
        "${input_args[@]}" "${duration_args[@]}" \
        -pix_fmt nv12 -c:v h264_v4l2m2m \
        -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize $((BITRATE*2)) \
        -f h264 "${VIDEO_FIFO}" &
    fi
  else
    # Software x264 (ultrafast, low-latency)
    stdbuf -oL ffmpeg -hide_banner -loglevel info -stats \
      "${input_args[@]}" "${duration_args[@]}" \
      -c:v libx264 -preset ultrafast -tune zerolatency \
      -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize $((BITRATE*2)) \
      -f h264 "${VIDEO_FIFO}" &
  fi
  echo $!
}

# Kick off capture
ENC_PID=""
case "$camera_type" in
  csi) ENC_PID="$(start_csi)" ;;
  usb) ENC_PID="$(start_usb "$SOURCE")" ;;
  *) die "Unexpected camera type: $camera_type" ;;
esac

# Start monitor (writes overlay file)
monitor "$ENC_PID" "$FFMPEG_DISP_PID" & MON_PID=$!

echo "[INFO] Running. Ctrl+C to quit."
wait "$ENC_PID" 2>/dev/null || true
wait "$FFMPEG_DISP_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
