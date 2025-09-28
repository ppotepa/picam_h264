#!/usr/bin/env bash
set -euo pipefail

# Default configuration values
DEFAULT_METHOD="h264_sdl_preview"
DEFAULT_RESOLUTION="1280x720"
DEFAULT_FPS="30"
DEFAULT_BITRATE="4000000"
DEFAULT_CORNER="top-left"

SCRIPT_NAME=$(basename "$0")
die() {
  local msg="$1"
  echo "${SCRIPT_NAME}: ${msg}" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Options:
  -m, --method <name>         Capture method to use (default: ${DEFAULT_METHOD})
  -r, --resolution WxH        Video resolution, e.g. 1920x1080 (default: ${DEFAULT_RESOLUTION})
  -f, --fps <number>          Frame rate in frames per second (default: ${DEFAULT_FPS})
  -b, --bitrate <bits>        Target bitrate in bits per second (default: ${DEFAULT_BITRATE})
  -c, --corner <position>     Overlay corner: top-left, top-right, bottom-left, bottom-right (default: ${DEFAULT_CORNER})
      --no-menu               Skip the interactive whiptail wizard
      --menu                  Force showing the wizard even if arguments are provided
      --check-deps            Only verify dependencies and exit
  -h, --help                  Show this help message and exit

Examples:
  ${SCRIPT_NAME}                             # start the wizard
  ${SCRIPT_NAME} --method h264_sdl_preview \
      --resolution 1920x1080 --fps 25 --bitrate 6000000
USAGE
}

declare -A DEPENDENCY_PACKAGES=(
  [libcamera-vid]="libcamera-apps"
  [ffmpeg]="ffmpeg"
  [awk]="gawk"
  [ps]="procps"
  [stdbuf]="coreutils"
  [whiptail]="whiptail"
)

REQUIRED_COMMANDS=(
  libcamera-vid
  ffmpeg
  awk
  ps
  stdbuf
)

OPTIONAL_COMMANDS=(
  whiptail
)

build_required_commands() {
  local require_whiptail="$1"
  local -n _result="$2"
  _result=("${REQUIRED_COMMANDS[@]}")
  if [[ "$require_whiptail" -eq 1 ]]; then
    _result+=("whiptail")
  fi
}

build_optional_commands() {
  local require_whiptail="$1"
  local -n _result="$2"
  _result=()
  for cmd in "${OPTIONAL_COMMANDS[@]}"; do
    if [[ "$require_whiptail" -eq 1 && "$cmd" == "whiptail" ]]; then
      continue
    fi
    _result+=("$cmd")
  done
}

print_dependency_status() {
  local require_whiptail="$1"
  local required=()
  local optional=()
  build_required_commands "$require_whiptail" required
  build_optional_commands "$require_whiptail" optional

  local missing=0

  echo "Checking required commands..."
  for cmd in "${required[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "[OK] $cmd"
    else
      missing=1
      local pkg="${DEPENDENCY_PACKAGES[$cmd]:-}"
      if [[ -n "$pkg" ]]; then
        echo "[MISSING] $cmd (install package: $pkg)"
      else
        echo "[MISSING] $cmd"
      fi
    fi
  done

  if [[ ${#optional[@]} -gt 0 ]]; then
    echo
    echo "Checking optional commands (recommended)..."
    for cmd in "${optional[@]}"; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo "[OK] $cmd"
      else
        local pkg="${DEPENDENCY_PACKAGES[$cmd]:-}"
        if [[ -n "$pkg" ]]; then
          echo "[OPTIONAL MISSING] $cmd (install package: $pkg)"
        else
          echo "[OPTIONAL MISSING] $cmd"
        fi
      fi
    done
  fi

  echo
  if [[ "$missing" -eq 0 ]]; then
    echo "All required commands are available."
  else
    echo "Required commands are missing."
  fi

  return "$missing"
}

install_packages() {
  local -a packages=()
  declare -A seen=()
  for pkg in "$@"; do
    [[ -z "$pkg" ]] && continue
    if [[ -z "${seen[$pkg]+x}" ]]; then
      packages+=("$pkg")
      seen[$pkg]=1
    fi
  done

  [[ ${#packages[@]} -gt 0 ]] || return 0

  if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get is not available. Install the following packages manually: ${packages[*]}"
  fi

  local -a prefix=()
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      prefix=(sudo)
    else
      die "Missing required dependencies and sudo is unavailable. Install packages manually: ${packages[*]}"
    fi
  fi

  echo "Installing packages: ${packages[*]}"
  "${prefix[@]}" apt-get update
  "${prefix[@]}" apt-get install -y "${packages[@]}"
}

ensure_dependencies() {
  local require_whiptail="$1"
  local required=()
  build_required_commands "$require_whiptail" required

  local missing_commands=()
  local installable_packages=()
  local manual_commands=()

  for cmd in "${required[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      continue
    fi
    missing_commands+=("$cmd")
    local pkg="${DEPENDENCY_PACKAGES[$cmd]:-}"
    if [[ -n "$pkg" ]]; then
      installable_packages+=("$pkg")
    else
      manual_commands+=("$cmd")
    fi
  done

  if [[ ${#manual_commands[@]} -gt 0 ]]; then
    die "Missing required dependencies: ${manual_commands[*]}. Install the appropriate packages manually and re-run the script."
  fi

  if [[ ${#missing_commands[@]} -gt 0 ]]; then
    echo "Missing required commands: ${missing_commands[*]}"
    install_packages "${installable_packages[@]}"
    hash -r 2>/dev/null || true
  fi

  local verify_missing=()
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      verify_missing+=("$cmd")
    fi
  done

  if [[ ${#verify_missing[@]} -gt 0 ]]; then
    local suggest_packages=()
    for cmd in "${verify_missing[@]}"; do
      local pkg="${DEPENDENCY_PACKAGES[$cmd]:-}"
      [[ -n "$pkg" ]] && suggest_packages+=("$pkg")
    done
    if [[ ${#suggest_packages[@]} -gt 0 ]]; then
      die "Dependencies are still missing after installation: ${verify_missing[*]}. Install packages manually: ${suggest_packages[*]}"
    else
      die "Dependencies are still missing after installation: ${verify_missing[*]}"
    fi
  fi

  local optional=()
  build_optional_commands "$require_whiptail" optional
  for cmd in "${optional[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      continue
    fi
    local pkg="${DEPENDENCY_PACKAGES[$cmd]:-}"
    if [[ -n "$pkg" ]]; then
      echo "Optional dependency '$cmd' not found. Install the '${pkg}' package to enable related features."
    else
      echo "Optional dependency '$cmd' not found."
    fi
  done
}

parse_resolution() {
  local res="$1"
  if [[ ! $res =~ ^([0-9]+)x([0-9]+)$ ]]; then
    die "Invalid resolution '$res'. Use the form WIDTHxHEIGHT (e.g. 1920x1080)."
  fi
  WIDTH="${BASH_REMATCH[1]}"
  HEIGHT="${BASH_REMATCH[2]}"
}

parse_arguments() {
  local parsed
  parsed=$(getopt -o m:r:f:b:c:h --long method:,resolution:,fps:,bitrate:,corner:,help,menu,no-menu,check-deps -- "$@") || {
    usage
    exit 1
  }
  eval set -- "$parsed"

  while true; do
    case "$1" in
      -m|--method)
        METHOD="$2"
        shift 2
        ;;
      -r|--resolution)
        RESOLUTION="$2"
        shift 2
        ;;
      -f|--fps)
        FPS="$2"
        shift 2
        ;;
      -b|--bitrate)
        BITRATE="$2"
        shift 2
        ;;
      -c|--corner)
        OVERLAY_CORNER="$2"
        shift 2
        ;;
      --menu)
        FORCE_MENU=1
        shift
        ;;
      --no-menu)
        SKIP_MENU=1
        shift
        ;;
      --check-deps)
        CHECK_DEPS_ONLY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        die "Unexpected argument: $1"
        ;;
    esac
  done
}

validate_numeric() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die "Invalid ${label}: '${value}'. Provide a positive integer."
  fi
}

validate_corner() {
  case "$1" in
    top-left|top-right|bottom-left|bottom-right)
      ;;
    *)
      die "Invalid overlay corner '${1}'. Use one of: top-left, top-right, bottom-left, bottom-right."
      ;;
  esac
}

validate_configuration() {
  parse_resolution "$RESOLUTION"
  validate_numeric "$FPS" "FPS"
  validate_numeric "$BITRATE" "bitrate"
  validate_corner "$OVERLAY_CORNER"
}

show_whiptail_wizard() {
  local menu_choice
  menu_choice=$(whiptail --title "PiCam Benchmark" --menu "Select capture method" 20 78 10 \
    "h264_sdl_preview" "libcamera-vid -> H264 -> ffmpeg SDL preview" \
    3>&1 1>&2 2>&3) || exit 1
  METHOD="$menu_choice"

  local res_choice
  res_choice=$(whiptail --title "Resolution" --inputbox "Enter resolution (WIDTHxHEIGHT)" 8 60 "$RESOLUTION" \
    3>&1 1>&2 2>&3) || exit 1
  RESOLUTION="$res_choice"

  local fps_choice
  fps_choice=$(whiptail --title "Frame rate" --inputbox "Enter FPS" 8 60 "$FPS" \
    3>&1 1>&2 2>&3) || exit 1
  FPS="$fps_choice"

  local bitrate_choice
  bitrate_choice=$(whiptail --title "Bitrate" --inputbox "Enter bitrate (bits per second)" 8 60 "$BITRATE" \
    3>&1 1>&2 2>&3) || exit 1
  BITRATE="$bitrate_choice"

  local corner_choice
  corner_choice=$(whiptail --title "Overlay position" --menu "Select overlay corner" 15 60 4 \
    "top-left" "Top left corner" \
    "top-right" "Top right corner" \
    "bottom-left" "Bottom left corner" \
    "bottom-right" "Bottom right corner" \
    3>&1 1>&2 2>&3) || exit 1
  OVERLAY_CORNER="$corner_choice"
}

overlay_position() {
  local corner="$1"
  case "$corner" in
    top-left)
      OVERLAY_X="10"
      OVERLAY_Y="10"
      ;;
    top-right)
      OVERLAY_X="w-tw-10"
      OVERLAY_Y="10"
      ;;
    bottom-left)
      OVERLAY_X="10"
      OVERLAY_Y="h-th-10"
      ;;
    bottom-right)
      OVERLAY_X="w-tw-10"
      OVERLAY_Y="h-th-10"
      ;;
    *)
      die "Unknown overlay corner '$corner'"
      ;;
  esac
}

escape_path_for_drawtext() {
  local path="$1"
  path=${path//\\/\\\\}
  path=${path//:/\\:}
  echo "$path"
}

any_pid_alive() {
  local pid
  for pid in "$@"; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

format_resource_usage() {
  local pids=()
  local pid
  for pid in "$@"; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done
  if [[ ${#pids[@]} -eq 0 ]]; then
    echo "0.0 0.0"
    return
  fi
  ps -p "${pids[@]}" -o %cpu=,%mem= 2>/dev/null | \
    awk 'BEGIN{cpu=0; mem=0} {cpu+=$1; mem+=$2} END{printf "%.1f %.1f\n", cpu, mem}'
}

monitor_metrics() {
  local stats_file="$1"
  local ffmpeg_log="$2"
  local width="$3"
  local height="$4"
  local bitrate_target="$5"
  local fps_target="$6"
  shift 6
  local pids=("$@")

  local fps_value="$fps_target"
  local bitrate_value
  bitrate_value=$(awk -v b="$bitrate_target" 'BEGIN{printf "%.1f Mbps", b / 1000000}')

  while any_pid_alive "${pids[@]}"; do
    [[ -f "$stats_file" ]] || break

    if [[ -s "$ffmpeg_log" ]]; then
      local latest_line
      latest_line=$(tail -n 5 "$ffmpeg_log" | tr '\r' '\n' | tail -n 1)
      if [[ $latest_line =~ fps=([0-9.]+) ]]; then
        fps_value="${BASH_REMATCH[1]}"
      fi
      if [[ $latest_line =~ bitrate=([^ ]+) ]]; then
        bitrate_value="${BASH_REMATCH[1]}"
      fi
    fi

    local usage
    usage=$(format_resource_usage "${pids[@]}")
    local cpu_usage mem_usage
    cpu_usage=$(awk '{print $1}' <<<"$usage")
    mem_usage=$(awk '{print $2}' <<<"$usage")

    {
      printf "FPS: %s\n" "$fps_value"
      printf "RES: %sx%s\n" "$width" "$height"
      printf "BitRate: %s\n" "$bitrate_value"
      printf "CPU: %s%%%%\n" "$cpu_usage"
      printf "MEM: %s%%%%\n" "$mem_usage"
    } >"$stats_file"

    sleep 1
  done
}

run_h264_sdl_preview() {
  parse_resolution "$RESOLUTION"
  local width="$WIDTH"
  local height="$HEIGHT"
  local fps="$FPS"
  local bitrate="$BITRATE"

  overlay_position "$OVERLAY_CORNER"
  local overlay_x="$OVERLAY_X"
  local overlay_y="$OVERLAY_Y"

  local font_path=""
  if [[ -f /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf ]]; then
    font_path="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
  elif [[ -f /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf ]]; then
    font_path="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
  fi

  local video_fifo
  video_fifo=$(mktemp -u /tmp/picam_video.XXXXXX)
  mkfifo "$video_fifo"

  local stats_file
  stats_file=$(mktemp /tmp/picam_stats.XXXXXX)
  local ffmpeg_log
  ffmpeg_log=$(mktemp /tmp/picam_ffmpeg.XXXXXX)

  local ffmpeg_pid=""
  local camera_pid=""
  local monitor_pid=""

  stop_process() {
    local pid="$1"
    [[ -n "$pid" ]] || return
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }

  cleanup_pipeline() {
    stop_process "$monitor_pid"
    stop_process "$camera_pid"
    stop_process "$ffmpeg_pid"
    rm -f "$video_fifo" "$stats_file" "$ffmpeg_log"
  }

  trap cleanup_pipeline EXIT INT TERM

  local drawtext
  if [[ -n "$font_path" ]]; then
    drawtext="drawtext=fontfile=$(escape_path_for_drawtext "$font_path"):textfile=$(escape_path_for_drawtext "$stats_file"):reload=1:x=${overlay_x}:y=${overlay_y}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
  else
    drawtext="drawtext=textfile=$(escape_path_for_drawtext "$stats_file"):reload=1:x=${overlay_x}:y=${overlay_y}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
  fi

  stdbuf -oL -eL ffmpeg -hide_banner -loglevel info -stats \
    -fflags nobuffer -flags low_delay -framedrop \
    -f h264 -i "$video_fifo" \
    -vf "$drawtext" -an -f sdl "PiCam Preview" \
    2> >(stdbuf -oL tee "$ffmpeg_log") &
  ffmpeg_pid=$!

  stdbuf -oL libcamera-vid --inline --codec h264 -t 0 \
    --width "$width" --height "$height" --framerate "$fps" \
    --bitrate "$bitrate" -o "$video_fifo" &
  camera_pid=$!

  monitor_metrics "$stats_file" "$ffmpeg_log" "$width" "$height" "$bitrate" "$fps" "$camera_pid" "$ffmpeg_pid" &
  monitor_pid=$!

  wait "$camera_pid" 2>/dev/null || true
  wait "$ffmpeg_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true

  trap - EXIT INT TERM
  cleanup_pipeline
}

start_capture() {
  case "$METHOD" in
    h264_sdl_preview)
      run_h264_sdl_preview
      ;;
    *)
      die "Unsupported method '$METHOD'"
      ;;
  esac
}

main() {
  METHOD="$DEFAULT_METHOD"
  RESOLUTION="$DEFAULT_RESOLUTION"
  FPS="$DEFAULT_FPS"
  BITRATE="$DEFAULT_BITRATE"
  OVERLAY_CORNER="$DEFAULT_CORNER"
  SKIP_MENU=0
  FORCE_MENU=0
  CHECK_DEPS_ONLY=0

  local original_argc=$#
  local show_menu=0
  local require_whiptail=0

  parse_arguments "$@"

  if [[ "$SKIP_MENU" -eq 0 ]]; then
    if [[ "$FORCE_MENU" -eq 1 || ( "$original_argc" -eq 0 && -t 0 && -t 1 ) ]]; then
      show_menu=1
      require_whiptail=1
    fi
  fi

  if (( CHECK_DEPS_ONLY )); then
    if print_dependency_status "$require_whiptail"; then
      exit 0
    else
      exit 1
    fi
  fi

  ensure_dependencies "$require_whiptail"

  if [[ "$show_menu" -eq 1 ]]; then
    show_whiptail_wizard
  fi

  validate_configuration
  start_capture
}

main "$@"
