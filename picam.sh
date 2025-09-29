#!/usr/bin/env bash
# =============================================================================
# PiCam H.264 Benchmarking Script
# =============================================================================
# A comprehensive camera benchmarking tool for Raspberry Pi that supports both
# CSI (ribbon cable) cameras and USB webcams. Creates a video capture pipeline
# with real-time performance overlay showing FPS, bitrate, and system metrics.
#
# Features:
# - Auto-detection of CSI and USB cameras
# - Interactive menu and CLI interface
# - Real-time performance monitoring
# - Automatic dependency management
# - Support for both libcamera-vid and rpicam-vid
# =============================================================================

set -euo pipefail

# =============================================================================
# DEFAULT CONFIGURATION VALUES
# =============================================================================
# These values are used when no arguments are provided or as fallbacks
DEFAULT_METHOD="h264_sdl_preview"    # Default capture method
DEFAULT_RESOLUTION="1280x720"        # Default video resolution
DEFAULT_FPS="30"                     # Default frame rate
DEFAULT_BITRATE="4000000"            # Default bitrate in bits per second
DEFAULT_DURATION="0"                 # Default duration in seconds (0 = infinite)
DEFAULT_CORNER="top-left"            # Default position for stats overlay
DEFAULT_SOURCE="auto"                # Default camera source (auto-detect)
DEFAULT_ENCODE="auto"                # Default encoding method (auto-detect)

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

SCRIPT_NAME=$(basename "$0")

# Logging system
LOG_LEVEL=${LOG_LEVEL:-1}  # 0=ERROR, 1=INFO, 2=DEBUG
LOG_FILE=""                # Set via --log-file or LOG_FILE env var

# Logging functions with timestamps
log_timestamp() {
  date '+%H:%M:%S.%3N' 2>/dev/null || date '+%H:%M:%S'
}

log_msg() {
  local level="$1"
  local level_num="$2"
  shift 2
  
  if [[ "$level_num" -gt "$LOG_LEVEL" ]]; then
    return
  fi
  
  local timestamp
  timestamp=$(log_timestamp)
  local output="[${timestamp}] ${level}: $*"
  
  if [[ -n "$LOG_FILE" ]]; then
    echo "$output" >> "$LOG_FILE"
  else
    echo "$output" >&2
  fi
}

log_error() { log_msg "ERROR" 0 "$@"; }
log_info()  { log_msg "INFO " 1 "$@"; }
log_debug() { log_msg "DEBUG" 2 "$@"; }

# Error handling function - prints error message and exits
die() {
  local msg="$1"
  log_error "${msg}"
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
  -s, --source <device>       Camera source: auto, csi, or /dev/videoN (default: auto)
  -e, --encode <method>       Encoding method: auto, software, hardware (default: auto)
  -d, --duration <seconds>    Recording duration in seconds (default: ${DEFAULT_DURATION}, 0 = infinite)
      --fb0, --framebuffer    Output to framebuffer /dev/fb0 instead of SDL window
  -v, --verbose               Increase logging verbosity (can be repeated)
      --quiet                 Only show error messages
      --log-file <path>       Write logs to file instead of stderr
      --no-menu               Skip the interactive whiptail wizard
      --no-overlay            Skip performance overlay (for low-end CPUs)
      --menu                  Force showing the wizard even if arguments are provided
      --check-deps            Only verify dependencies (no installation) and exit
      --install-deps          Install missing dependencies and exit
      --debug-cameras         Print a detailed camera detection report and exit
      --test-usb              Run a short USB camera capture test (requires ffmpeg) and exit
      --list-cameras          List available cameras and exit
  -h, --help                  Show this help message and exit

Encoding Methods:
  auto                        Auto-detect best available encoding (hardware preferred)
  software                    Use software encoding (libx264 - CPU intensive)
  hardware                    Use Pi's hardware encoder (h264_v4l2m2m via /dev/video11)

Examples:
  ${SCRIPT_NAME}                             # start the wizard
  ${SCRIPT_NAME} --method h264_sdl_preview \
      --resolution 1920x1080 --fps 25 --bitrate 6000000
USAGE
}

# Font detection function for overlay text rendering
# Uses name reference to return the found font path
# Searches common system font locations and falls back to any available TTF
find_font_path() {
  local -n result=$1
  result=""
  
  # Common font paths to check (in order of preference)
  # DejaVu fonts are standard on most Raspberry Pi OS installations
  local font_paths=(
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    "/usr/share/fonts/ttf-dejavu/DejaVuSans.ttf"
    "/usr/share/fonts/TTF/DejaVuSans.ttf"
    "/usr/share/fonts/truetype/ttf-dejavu/DejaVuSans.ttf"
  )
  
  # Check each font path
  for font in "${font_paths[@]}"; do
    if [[ -f "$font" ]]; then
      result="$font"
      return
    fi
  done
  
  # If no specific font was found, try to find any TTF font
  if command -v find &>/dev/null; then
    local found_font
    found_font=$(find /usr/share/fonts -name "*.ttf" -print -quit 2>/dev/null)
    if [[ -n "$found_font" ]]; then
      result="$found_font"
    fi
  fi
}

# =============================================================================
# DEPENDENCY MANAGEMENT
# =============================================================================

# Core commands required for basic functionality
REQUIRED_COMMANDS_BASE=(
  libcamera-vid    # Camera capture (older Raspberry Pi OS)
  ffmpeg          # Video processing and display
  awk             # Text processing for stats
  ps              # Process monitoring
  stdbuf          # Buffering control for real-time output
)

# Optional commands that enhance functionality but aren't critical
OPTIONAL_COMMANDS_BASE=(
  whiptail        # Interactive menu interface
  v4l2-ctl        # USB camera diagnostics and format detection
)

# Mapping of commands to their package names for automatic installation
declare -A COMMAND_PACKAGES=(
  [libcamera-vid]="libcamera-apps"   # Raspberry Pi camera tools
  [rpicam-vid]="libcamera-apps"      # Newer name for camera tools
  [ffmpeg]="ffmpeg"                  # Video processing suite
  [awk]="gawk"                       # GNU awk implementation
  [ps]="procps"                      # Process utilities
  [stdbuf]="coreutils"               # Core utilities
  [whiptail]="whiptail"               # Dialog boxes for shell scripts
  [v4l2-ctl]="v4l-utils"             # Video4Linux utilities
)

declare -a MISSING_REQUIRED_COMMANDS=()
declare -a MISSING_OPTIONAL_COMMANDS=()

build_required_commands() {
  local require_whiptail="$1"
  local -n _out="$2"
  _out=("${REQUIRED_COMMANDS_BASE[@]}")
  if [[ "$require_whiptail" -eq 1 ]]; then
    _out+=("whiptail")
  fi
}

build_optional_commands() {
  local require_whiptail="$1"
  local -n _out="$2"
  _out=()
  for cmd in "${OPTIONAL_COMMANDS_BASE[@]}"; do
    if [[ "$require_whiptail" -eq 1 && "$cmd" == "whiptail" ]]; then
      continue
    fi
    _out+=("$cmd")
  done
}

# =============================================================================
# CAMERA DETECTION AND COMPATIBILITY
# =============================================================================

# Check if any camera command is available (handles OS version differences)
# Returns 0 if camera tools are available, 1 otherwise
check_camera_command() {
  if command -v libcamera-vid >/dev/null 2>&1; then
    return 0
  fi
  if command -v rpicam-vid >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Get the correct camera command for this OS version
# Raspberry Pi OS Bookworm renamed libcamera-vid to rpicam-vid
get_camera_command() {
  if command -v libcamera-vid >/dev/null 2>&1; then
    echo "libcamera-vid"
  elif command -v rpicam-vid >/dev/null 2>&1; then
    echo "rpicam-vid"
  else
    echo "libcamera-vid"  # fallback for error messages
  fi
}

# Check if device has video capture capability from hex value
has_video_capture_capability() {
  local caps_hex="$1"
  # Remove 0x prefix if present
  caps_hex="${caps_hex#0x}"
  # Convert to decimal
  local caps_dec=$((16#$caps_hex))
  # Check if bit 0 is set (VIDEO_CAPTURE = 0x00000001)
  (( caps_dec & 0x00000001 ))
}

# Return 0 if $1 is a real USB capture node (uvcvideo + Video Capture)
is_usb_capture_node() {
  local dev="$1"
  [[ -c "$dev" ]] || return 1
  
  # Method 1: Try v4l2-ctl
  if command -v v4l2-ctl >/dev/null 2>&1; then
    local info
    info=$(v4l2-ctl --device="$dev" -D 2>/dev/null || true)
    
    # Must be uvcvideo driver
    if ! grep -qiE 'Driver name:[[:space:]]*uvcvideo' <<<"$info"; then
      return 1
    fi
    
    # Check capabilities hex value or text
    local caps_line
    caps_line=$(grep -E '^[[:space:]]*Capabilities[[:space:]]*:.*0x' <<<"$info" | head -1)
    if [[ $caps_line =~ 0x([0-9a-fA-F]+) ]]; then
      if has_video_capture_capability "${BASH_REMATCH[1]}"; then
        return 0
      fi
    fi
    
    # Fallback: check for explicit "Video Capture" text
    if grep -qi 'Video Capture' <<<"$info"; then
      return 0
    fi
  fi
  
  # Method 2: Check sysfs
  local dev_name
  dev_name=$(basename "$dev")
  local uevent="/sys/class/video4linux/$dev_name/device/uevent"
  if [[ -f "$uevent" ]] && grep -q "DRIVER=uvcvideo" "$uevent" 2>/dev/null; then
    return 0
  fi
  
  return 1
}

# Pick the first proper capture node (e.g., /dev/video0 for C920)
select_usb_capture_device() {
  # Try /dev/video0 first (most common for USB cameras)
  if is_usb_capture_node "/dev/video0"; then
    echo "/dev/video0"
    return 0
  fi
  
  # Try other devices
  local dev
  for dev in /dev/video*; do
    if is_usb_capture_node "$dev"; then
      echo "$dev"
      return 0
    fi
  done
  
  return 1
}

# Comprehensive camera detection function
# Detects both CSI (ribbon cable) and USB cameras
# Returns shell variables: csi_available, usb_available, usb_device
detect_cameras() {
  log_debug "Starting camera detection..."
  local csi_available=0
  local usb_available=0
  local usb_device=""

  # CSI (avoid counting USB seen by libcamera)
  log_debug "Checking for CSI camera using command: $(get_camera_command)"
  if command -v "$(get_camera_command)" >/dev/null 2>&1; then
    local camera_output
    camera_output=$("$(get_camera_command)" --list-cameras 2>&1 || true)
    if echo "$camera_output" | grep -q "Available cameras" && \
       ! echo "$camera_output" | grep -q "ERROR.*no cameras available"; then
      # If libcamera lists anything *not* marked usb@, consider it real CSI
      if echo "$camera_output" | grep -qv "usb@"; then
        csi_available=1
      fi
    fi
  fi

  # USB (uvcvideo + Video Capture)
  log_debug "Checking for USB cameras in /dev/video*"
  if ls /dev/video* >/dev/null 2>&1; then
    local dev
    dev=$(select_usb_capture_device || true)
    if [[ -n "$dev" ]]; then
      usb_available=1
      usb_device="$dev"
    fi
  fi

  echo "csi_available=$csi_available usb_available=$usb_available usb_device=$usb_device"
}

# Get the best available camera type
get_camera_type() {
  # Handle explicit source selection
  case "$SOURCE" in
    csi)
      echo "csi"
      return
      ;;
    /dev/video*)
      if [[ -c "$SOURCE" ]]; then
        echo "usb"
      else
        echo "none"
      fi
      return
      ;;
    auto)
      # Auto-detection logic (original behavior)
      ;;
    *)
      die "Invalid source: '$SOURCE'. Use 'auto', 'csi', or '/dev/videoN'"
      ;;
  esac

  # Auto-detection when SOURCE=auto
  local detection
  detection=$(detect_cameras)
  eval "$detection"
  
  if [[ "$csi_available" -eq 1 ]]; then
    echo "csi"
  elif [[ "$usb_available" -eq 1 ]]; then
    echo "usb"
  else
    echo "none"
  fi
}

# =============================================================================
# ENCODING DETECTION AND SELECTION
# =============================================================================

# Check if Pi's hardware H.264 encoder is available
# Returns 0 if hardware encoder available, 1 otherwise
detect_hardware_encoder() {
  log_debug "Checking for hardware H.264 encoder at /dev/video11"
  # Check if Pi's hardware encoder is available
  if [[ -c "/dev/video11" ]] && command -v v4l2-ctl >/dev/null 2>&1; then
    local encoder_info
    encoder_info=$(v4l2-ctl --device=/dev/video11 --info 2>/dev/null || true)
    if echo "$encoder_info" | grep -q "bcm2835-codec-encode"; then
      return 0  # Hardware encoder available
    fi
  fi
  return 1  # Hardware encoder not available
}

# Get the encoding method to use based on user preference and availability
get_encoding_method() {
  log_debug "Determining encoding method for ENCODE=$ENCODE"
  case "$ENCODE" in
    software)
      echo "software"
      ;;
    hardware)
      if detect_hardware_encoder; then
        echo "hardware"
      else
        echo "software"  # Fallback to software if hardware not available
      fi
      ;;
    auto)
      # Auto-detect: prefer hardware if available
      if detect_hardware_encoder; then
        echo "hardware"
      else
        echo "software"
      fi
      ;;
    *)
      die "Invalid encoding method: '$ENCODE'. Use 'auto', 'software', or 'hardware'"
      ;;
  esac
}

collect_install_plan() {
  local -n _commands="$1"
  local -n _packages_out="$2"
  local -n _missing_without_pkg="$3"

  _packages_out=()
  _missing_without_pkg=()

  declare -A seen=()
  for cmd in "${_commands[@]}"; do
    local pkg="${COMMAND_PACKAGES[$cmd]:-}"
    if [[ -n "$pkg" ]]; then
      if [[ -z "${seen[$pkg]+x}" ]]; then
        _packages_out+=("$pkg")
        seen[$pkg]=1
      fi
    else
      _missing_without_pkg+=("$cmd")
    fi
  done
}

maybe_sudo() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "${SCRIPT_NAME}: Cannot run '$1' automatically (sudo unavailable)." >&2
    return 1
  fi
}

apt_update_and_install() {
  local -n _packages_ref="$1"

  if [[ ${#_packages_ref[@]} -eq 0 ]]; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "${SCRIPT_NAME}: apt-get is required to install packages automatically." >&2
    return 1
  fi

  if ! maybe_sudo apt-get update; then
    return 1
  fi

  if ! maybe_sudo apt-get install -y "${_packages_ref[@]}"; then
    return 1
  fi
}

check_dependencies() {
  local require_whiptail="$1"
  
  log_info "Checking dependencies (whiptail required: $require_whiptail)..."

  local required_commands=()
  local optional_commands=()
  build_required_commands "$require_whiptail" required_commands
  build_optional_commands "$require_whiptail" optional_commands

  MISSING_REQUIRED_COMMANDS=()
  MISSING_OPTIONAL_COMMANDS=()

  echo "Checking required commands..."
  for cmd in "${required_commands[@]}"; do
    if [[ "$cmd" == "libcamera-vid" ]]; then
      if command -v libcamera-vid >/dev/null 2>&1; then
        echo "[OK] libcamera-vid"
      elif command -v rpicam-vid >/dev/null 2>&1; then
        echo "[OK] rpicam-vid (replaces libcamera-vid)"
      else
        local pkg="${COMMAND_PACKAGES[$cmd]:-}"
        if [[ -n "$pkg" ]]; then
          echo "[MISSING] libcamera-vid (install package: $pkg)"
        else
          echo "[MISSING] libcamera-vid"
        fi
        MISSING_REQUIRED_COMMANDS+=("$cmd")
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
      MISSING_REQUIRED_COMMANDS+=("$cmd")
    fi
  done

  if [[ ${#optional_commands[@]} -gt 0 ]]; then
    echo
    echo "Checking optional commands..."
    for cmd in "${optional_commands[@]}"; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo "[OK] $cmd"
      else
        local pkg="${COMMAND_PACKAGES[$cmd]:-}"
        if [[ -n "$pkg" ]]; then
          echo "[OPTIONAL MISSING] $cmd (install package: $pkg)"
        else
          echo "[OPTIONAL MISSING] $cmd"
        fi
        MISSING_OPTIONAL_COMMANDS+=("$cmd")
      fi
    done
  fi

  if [[ ${#MISSING_REQUIRED_COMMANDS[@]} -gt 0 ]]; then
    return 1
  fi
  return 0
}

attempt_dependency_install() {
  local require_whiptail="$1"
  
  log_info "Attempting to install missing dependencies..."

  local packages=()
  local missing_without_pkg=()
  collect_install_plan MISSING_REQUIRED_COMMANDS packages missing_without_pkg

  if [[ ${#missing_without_pkg[@]} -gt 0 ]]; then
    echo "${SCRIPT_NAME}: Missing required commands without known packages: ${missing_without_pkg[*]}" >&2
    return 1
  fi

  if [[ ${#packages[@]} -eq 0 ]]; then
    echo "${SCRIPT_NAME}: Required commands are missing but no packages were identified." >&2
    return 1
  fi

  echo "Installing packages: ${packages[*]}"
  if ! apt_update_and_install packages; then
    echo "${SCRIPT_NAME}: Package installation failed." >&2
    return 1
  fi

  hash -r 2>/dev/null || true

  if check_dependencies "$require_whiptail"; then
    return 0
  fi

  echo "${SCRIPT_NAME}: Dependencies remain missing after installation." >&2
  return 1
}

ensure_dependencies() {
  local require_whiptail="$1"
  local auto_install="${2:-1}"

  if check_dependencies "$require_whiptail"; then
    return 0
  fi

  if [[ "$auto_install" -eq 0 ]]; then
    return 1
  fi

  echo "Missing dependencies detected."
  if ! attempt_dependency_install "$require_whiptail"; then
    return 1
  fi

  return 0
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
  parsed=$(getopt -o m:r:f:b:c:s:e:d:vh --long method:,resolution:,fps:,bitrate:,corner:,source:,encode:,duration:,verbose,quiet,log-file:,help,menu,no-menu,no-overlay,check-deps,install-deps,debug-cameras,test-usb,list-cameras,fb0,framebuffer -- "$@") || {
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
      -s|--source)
        SOURCE="$2"
        shift 2
        ;;
      -e|--encode)
        ENCODE="$2"
        shift 2
        ;;
      -d|--duration)
        DURATION="$2"
        shift 2
        ;;
      --fb0|--framebuffer)
        USE_FRAMEBUFFER=1
        shift
        ;;
      -v|--verbose)
        ((LOG_LEVEL++))
        shift
        ;;
      --quiet)
        LOG_LEVEL=0
        shift
        ;;
      --log-file)
        LOG_FILE="$2"
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
      --no-overlay)
        NO_OVERLAY=1
        shift
        ;;
      --check-deps)
        CHECK_DEPS_ONLY=1
        shift
        ;;
      --install-deps)
        INSTALL_DEPS_ONLY=1
        shift
        ;;
      --debug-cameras)
        DEBUG_CAMERAS_ONLY=1
        shift
        ;;
      --test-usb)
        USB_TEST_ONLY=1
        shift
        ;;
      --list-cameras)
        LIST_CAMERAS_ONLY=1
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

validate_encoding() {
  case "$1" in
    auto|software|hardware)
      ;;
    *)
      die "Invalid encoding method '${1}'. Use one of: auto, software, hardware."
      ;;
  esac
}

validate_duration() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die "Invalid duration: '${value}'. Provide a non-negative integer (0 for infinite)."
  fi
}

validate_configuration() {
  parse_resolution "$RESOLUTION"
  validate_numeric "$FPS" "FPS"
  validate_numeric "$BITRATE" "bitrate"
  validate_corner "$OVERLAY_CORNER"
  validate_encoding "$ENCODE"
  validate_duration "$DURATION"
}

# =============================================================================
# USER INTERFACE FUNCTIONS
# =============================================================================

# Interactive menu system using whiptail for user-friendly configuration
show_whiptail_wizard() {
  local menu_choice
  # Display method selection menu with whiptail
  menu_choice=$(whiptail --title "PiCam Benchmark" --menu "Select capture method" 20 78 10 \
    "h264_sdl_preview" "Camera -> H264 -> ffmpeg SDL preview" \
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

  # Camera source selection
  local source_options=()
  source_options+=("auto" "Auto-detect (CSI preferred)")
  
  # Check for CSI camera
  if "$(get_camera_command)" --list-cameras --timeout 1000 2>/dev/null | grep -q "Available cameras"; then
    source_options+=("csi" "CSI Camera (ribbon cable)")
  fi
  
  # Check for USB cameras
  if ls /dev/video* >/dev/null 2>&1; then
    local device
    for device in /dev/video*; do
      [[ -c "$device" ]] || continue
      
      # Skip Pi's internal video processing devices
      if command -v v4l2-ctl >/dev/null 2>&1; then
        local driver_info
        driver_info=$(v4l2-ctl --device="$device" --all 2>/dev/null || true)
        if echo "$driver_info" | grep -qi "bcm2835\|codec\|isp"; then
          continue
        fi
        
        if echo "$driver_info" | grep -qiE "Driver name:[[:space:]]*uvcvideo" && \
           echo "$driver_info" | grep -qi "Capabilities:.*Video Capture"; then
          local card_name
          card_name=$(echo "$driver_info" | grep "Card type" | cut -d: -f2 | xargs)
          source_options+=("$device" "USB: ${card_name:-Unknown}")
        fi
      else
        source_options+=("$device" "USB Camera")
      fi
    done
  fi

  if [[ ${#source_options[@]} -gt 2 ]]; then
    local source_choice
    source_choice=$(whiptail --title "Camera Source" --menu "Select camera source" 20 78 10 \
      "${source_options[@]}" \
      3>&1 1>&2 2>&3) || exit 1
    SOURCE="$source_choice"
  fi

  # Encoding method selection
  local encode_options=("auto" "Auto-detect (hardware preferred)")
  encode_options+=("software" "Software encoding (CPU intensive)")
  if detect_hardware_encoder; then
    encode_options+=("hardware" "Hardware encoding (Pi's H.264 encoder)")
  fi

  if [[ ${#encode_options[@]} -gt 2 ]]; then
    local encode_choice
    encode_choice=$(whiptail --title "Encoding Method" --menu "Select encoding method" 15 78 10 \
      "${encode_options[@]}" \
      3>&1 1>&2 2>&3) || exit 1
    ENCODE="$encode_choice"
  fi
}

# Calculate overlay position coordinates for ffmpeg drawtext filter
# Uses ffmpeg's text positioning expressions (w=width, h=height, tw=text width, th=text height)
compute_overlay_position() {
  local corner="$1"      # Corner position (top-left, etc.)
  local width="$2"       # Video width (currently unused but for future enhancements)
  local height="$3"      # Video height (currently unused but for future enhancements) 
  local -n x_result="$4" # X coordinate result (by reference)
  local -n y_result="$5" # Y coordinate result (by reference)
  
  case "$corner" in
    top-left)
      x_result="10"
      y_result="10"
      ;;
    top-right)
      x_result="w-tw-10"
      y_result="10"
      ;;
    bottom-left)
      x_result="10"
      y_result="h-th-10"
      ;;
    bottom-right)
      x_result="w-tw-10"
      y_result="h-th-10"
      ;;
    *)
      # Default to top-left if unknown
      x_result="10"
      y_result="10"
      ;;
  esac
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
  # Collect valid PIDs from arguments
  for pid in "$@"; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done
  # Return zeros if no valid PIDs provided
  if [[ ${#pids[@]} -eq 0 ]]; then
    echo "0.0 0.0"
    return
  fi
  # Use ps and awk to sum CPU and memory usage across all processes
  ps -p "${pids[@]}" -o %cpu=,%mem= 2>/dev/null | \
    awk 'BEGIN{cpu=0; mem=0} {cpu+=$1; mem+=$2} END{printf "%.1f %.1f\n", cpu, mem}'
}

# Main monitoring loop that continuously updates performance statistics
# Writes metrics to a file that ffmpeg reads for the overlay display
monitor_metrics() {
  local stats_file="$1"      # File where stats are written for ffmpeg overlay
  local ffmpeg_log="$2"     # FFmpeg log file to parse for actual metrics
  local width="$3"          # Video width for display
  local height="$4"         # Video height for display
  local bitrate_target="$5" # Target bitrate for comparison
  local fps_target="$6"     # Target FPS for comparison
  shift 6                    # Remove processed arguments, leaving PIDs
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
      if [[ $latest_line =~ bitrate=([^ ]+) ]] && [[ ${BASH_REMATCH[1]} != "N/A" ]]; then
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

# =============================================================================
# DIAGNOSTIC AND TESTING FUNCTIONS
# =============================================================================

# List available cameras in a user-friendly format
list_available_cameras() {
  echo "=== Available Cameras ==="
  echo
  
  # Check for CSI camera
  local camera_cmd
  camera_cmd=$(get_camera_command)
  echo "Checking for CSI camera..."
  if "$camera_cmd" --list-cameras --timeout 1000 2>/dev/null | grep -q "Available cameras"; then
    echo "✓ CSI Camera detected (use: --source csi)"
    "$camera_cmd" --list-cameras --timeout 1000 2>/dev/null | head -10
  else
    echo "✗ No CSI camera detected"
  fi
  echo
  
  # Check for USB cameras
  echo "Checking for USB cameras..."
  local found_usb=0
  if ls /dev/video* >/dev/null 2>&1; then
    local device
    for device in /dev/video*; do
      [[ -c "$device" ]] || continue
      
      # Skip non-capture devices (bcm2835 codec devices)
      local driver_info
      if command -v v4l2-ctl >/dev/null 2>&1; then
        driver_info=$(v4l2-ctl --device="$device" --all 2>/dev/null || true)
        if echo "$driver_info" | grep -qi "bcm2835\|codec\|isp"; then
          continue  # Skip Pi's internal video processing devices
        fi
        
        if echo "$driver_info" | grep -qiE "Driver name:[[:space:]]*uvcvideo" && \
           echo "$driver_info" | grep -qi "Capabilities:.*Video Capture"; then
          echo "✓ USB Camera: $device (use: --source $device)"
          echo "$driver_info" | head -3 | sed 's/^/  /'
          found_usb=1
          echo
        fi
      else
        # Fallback without v4l2-ctl
        echo "? Possible USB Camera: $device (use: --source $device)"
        found_usb=1
      fi
    done
  fi
  
  if [[ $found_usb -eq 0 ]]; then
    echo "✗ No USB cameras detected"
  fi
  
  echo
  echo "Usage examples:"
  echo "  $0 --source auto        # Auto-detect (CSI preferred)"
  echo "  $0 --source csi         # Force CSI camera"
  echo "  $0 --source /dev/video0 # Force specific USB camera"
}

# Generate comprehensive camera detection report for troubleshooting
# Shows detailed information about available cameras and their capabilities
run_camera_debug_report() {
  local camera_cmd
  camera_cmd=$(get_camera_command)

  echo "=== Camera command detection ==="
  echo "Preferred camera command: $camera_cmd"
  echo

  echo "=== Checking libcamera-apps package contents ==="
  if command -v dpkg >/dev/null 2>&1; then
    local dpkg_output
    if dpkg_output=$(dpkg -L libcamera-apps 2>/dev/null); then
      local binaries
      binaries=$(grep -E '/bin/' <<<"$dpkg_output" || true)
      if [[ -n "$binaries" ]]; then
        echo "$binaries"
      else
        echo "No binaries in /bin provided by libcamera-apps."
      fi
    else
      echo "Package 'libcamera-apps' is not installed."
    fi
  else
    echo "dpkg not available; skipping package inspection."
  fi
  echo

  echo "=== Searching for camera binaries in PATH ==="
  if command -v libcamera-vid >/dev/null 2>&1; then
    echo "libcamera-vid -> $(command -v libcamera-vid)"
  else
    echo "libcamera-vid not found in PATH"
  fi
  if command -v rpicam-vid >/dev/null 2>&1; then
    echo "rpicam-vid -> $(command -v rpicam-vid)"
  else
    echo "rpicam-vid not found in PATH"
  fi
  echo

  echo "=== Listing camera-related binaries ==="
  if command -v find >/dev/null 2>&1; then
    local find_output
    find_output=$(find /usr/bin /usr/local/bin -maxdepth 1 -type f \
      \( -name "*libcamera*" -o -name "*rpicam*" \) 2>/dev/null | sort || true)
    if [[ -n "$find_output" ]]; then
      echo "$find_output"
    else
      echo "No camera binaries found in standard locations."
    fi
  else
    echo "find command not available; skipping binary listing."
  fi
  echo

  echo "=== Testing the camera command ==="
  if command -v "$camera_cmd" >/dev/null 2>&1; then
    echo "Running '$camera_cmd --list-cameras'..."
    "$camera_cmd" --list-cameras 2>&1 || true
  else
    echo "Camera command '$camera_cmd' is not available."
  fi
  echo

  echo "=== Camera detection summary ==="
  local detection
  detection=$(detect_cameras)
  eval "$detection"
  echo "CSI camera available: $csi_available"
  echo "USB camera available: $usb_available"
  echo "USB device: ${usb_device:-<none>}"
  echo "Selected camera type: $(get_camera_type)"
}

# USB camera testing function with format auto-detection
# Performs a 5-second capture test to verify USB camera functionality
run_usb_camera_test() {
  echo "=== USB camera diagnostic ==="

  # List available video devices for diagnostic purposes
  ls -la /dev/video* 2>/dev/null || echo "No /dev/video* entries found."
  echo

  parse_resolution "$RESOLUTION"
  local width="$WIDTH"
  local height="$HEIGHT"

  local usb_device=""
  local input_format=""
  
  if ls /dev/video* >/dev/null 2>&1; then
    if command -v v4l2-ctl >/dev/null 2>&1; then
      for device in /dev/video*; do
        [[ -c "$device" ]] || continue
        
        echo "Checking device: $device"
        local formats
        formats=$(v4l2-ctl --device="$device" --list-formats-ext 2>/dev/null)
        
        # Check for available formats in order of preference
        if echo "$formats" | grep -q "H264"; then
          usb_device="$device"
          input_format="h264"
          echo "Found H264 capable device: $device"
          break
        elif echo "$formats" | grep -q "MJPG"; then
          usb_device="$device"
          input_format="mjpeg"
          echo "Found MJPEG capable device: $device"
          break
        elif echo "$formats" | grep -q "YUYV"; then
          usb_device="$device"
          input_format="yuyv422"
          echo "Found YUYV capable device: $device"
          break
        fi
      done
    else
      # If v4l2-ctl is not available, try the first device with mjpeg (most common)
      for device in /dev/video*; do
        [[ -c "$device" ]] || continue
        usb_device="$device"
        input_format="mjpeg"  # Default to mjpeg
        break
      done
    fi
  fi

  if [[ -z "$usb_device" ]]; then
    echo "No suitable USB camera detected."
    return 1
  fi

  echo "Selected device: $usb_device with format: $input_format"

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is required for the USB camera test." >&2
    return 1
  fi

  local capture_cmd
  if [[ -n "$input_format" ]]; then
    capture_cmd=(ffmpeg -f v4l2 -input_format "$input_format" -video_size "${width}x${height}" -framerate "$FPS" -i "$usb_device" -t 5 -f null -)
  else
    # If format detection failed, try without specifying a format (let ffmpeg auto-detect)
    capture_cmd=(ffmpeg -f v4l2 -video_size "${width}x${height}" -framerate "$FPS" -i "$usb_device" -t 5 -f null -)
  fi
  
  local timeout_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout 6s)
  fi

  echo "Capturing 5 seconds from $usb_device using ffmpeg..."
  local ffmpeg_output
  if ! ffmpeg_output=$("${timeout_cmd[@]}" "${capture_cmd[@]}" 2>&1); then
    printf '%s\n' "$ffmpeg_output"
    echo "ffmpeg capture reported an error. Trying without format specification..." >&2
    
    # Try again without format specification
    capture_cmd=(ffmpeg -f v4l2 -video_size "${width}x${height}" -framerate "$FPS" -i "$usb_device" -t 5 -f null -)
    if ! ffmpeg_output=$("${timeout_cmd[@]}" "${capture_cmd[@]}" 2>&1); then
      printf '%s\n' "$ffmpeg_output"
      echo "Second capture attempt also failed." >&2
      return 1
    fi
  fi

  printf '%s\n' "$ffmpeg_output" | tail -n 10
  echo
  echo "USB camera test completed successfully."
  echo "You can run the capture manually with:"
  if [[ -n "$input_format" ]]; then
    echo "ffmpeg -f v4l2 -input_format $input_format -video_size ${width}x${height} -framerate $FPS -i $usb_device -t 5 output.mp4"
  else
    echo "ffmpeg -f v4l2 -video_size ${width}x${height} -framerate $FPS -i $usb_device -t 5 output.mp4"
  fi
}

# =============================================================================
# CAPTURE PIPELINE FUNCTIONS
# =============================================================================

# Main capture pipeline for CSI cameras using libcamera/rpicam tools
# Creates: Camera -> H.264 encoder -> FIFO -> ffmpeg -> SDL display with stats overlay
run_h264_sdl_preview() {
  log_info "Starting CSI camera H.264 preview pipeline"
  parse_resolution "$RESOLUTION"
  local width="$WIDTH"     # Parsed video width
  local height="$HEIGHT"   # Parsed video height  
  local fps="$FPS"         # Frame rate
  local bitrate="$BITRATE" # Target bitrate

  overlay_position "$OVERLAY_CORNER"
  local overlay_x="$OVERLAY_X"
  local overlay_y="$OVERLAY_Y"

  local font_path=""
  find_font_path font_path

  local tmpdir video_fifo
  tmpdir="$(mktemp -d)"
  video_fifo="$tmpdir/video.h264"
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
    rm -rf "$tmpdir" "$stats_file" "$ffmpeg_log"
  }

  trap cleanup_pipeline EXIT INT TERM

  local drawtext=""
  if [[ "$NO_OVERLAY" -eq 0 ]]; then
    if [[ -n "$font_path" ]]; then
      drawtext="drawtext=fontfile=$(escape_path_for_drawtext "$font_path"):textfile=$(escape_path_for_drawtext "$stats_file"):reload=1:x=${overlay_x}:y=${overlay_y}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
    else
      drawtext="drawtext=textfile=$(escape_path_for_drawtext "$stats_file"):reload=1:x=${overlay_x}:y=${overlay_y}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
    fi
  fi

  local duration_args=()
  if [[ "$DURATION" -gt 0 ]]; then
    duration_args=(-t "$DURATION")
  fi

  local output_args=()
  if [[ "$USE_FRAMEBUFFER" -eq 1 ]]; then
    output_args=(-f fbdev /dev/fb0)
  else
    output_args=(-f sdl "PiCam Preview")
  fi

  if [[ -n "$drawtext" ]]; then
    stdbuf -oL -eL ffmpeg -hide_banner -loglevel info -stats \
      -fflags +nobuffer -flags +low_delay -reorder_queue_size 0 -thread_queue_size 512 \
      -f h264 -i "$video_fifo" "${duration_args[@]}" \
      -vf "$drawtext" -an "${output_args[@]}" \
      2> >(stdbuf -oL tee "$ffmpeg_log" >&2) &
  else
    stdbuf -oL -eL ffmpeg -hide_banner -loglevel info -stats \
      -fflags +nobuffer -flags +low_delay -reorder_queue_size 0 -thread_queue_size 512 \
      -f h264 -i "$video_fifo" "${duration_args[@]}" \
      -an "${output_args[@]}" \
      2> >(stdbuf -oL tee "$ffmpeg_log" >&2) &
  fi
  ffmpeg_pid=$!

  local timeout_ms=0
  if [[ "$DURATION" -gt 0 ]]; then
    timeout_ms=$((DURATION * 1000))
  fi

  log_info "Starting CSI camera: $(get_camera_command) ${width}x${height}@${fps}fps, bitrate=${bitrate}, timeout=${timeout_ms}ms"
  stdbuf -oL "$(get_camera_command)" --inline --codec h264 --timeout "$timeout_ms" \
    --width "$width" --height "$height" --framerate "$fps" \
    --bitrate "$bitrate" -o - > "$video_fifo" &
  camera_pid=$!
  log_debug "CSI camera process started with PID: $camera_pid"

  if [[ "$NO_OVERLAY" -eq 0 ]]; then
    monitor_metrics "$stats_file" "$ffmpeg_log" "$width" "$height" "$bitrate" "$fps" "$camera_pid" "$ffmpeg_pid" &
    monitor_pid=$!
  fi

  log_info "Waiting for pipeline processes to complete..."
  wait "$camera_pid" 2>/dev/null || true
  wait "$ffmpeg_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true

  log_info "CSI camera pipeline completed successfully"
  trap - EXIT INT TERM
  cleanup_pipeline
}

# USB camera capture pipeline using ffmpeg for both capture and display
# Creates: USB Camera -> ffmpeg capture -> H.264 -> FIFO -> ffmpeg display with stats
run_usb_h264_sdl_preview() {
  log_info "Starting USB camera H.264 preview pipeline"
  local width height
  parse_resolution "$RESOLUTION"
  width="$WIDTH"   # Parsed video width
  height="$HEIGHT" # Parsed video height

  local usb_device
  
  # Use explicit device if specified, otherwise auto-detect
  if [[ "$SOURCE" =~ ^/dev/video[0-9]+$ ]]; then
    usb_device="$SOURCE"
    if [[ ! -c "$usb_device" ]]; then
      die "Specified USB camera device not found: $usb_device"
    fi
  else
    # Auto-detect USB camera
    local detection
    detection=$(detect_cameras)
    eval "$detection"
    
    if [[ "$usb_available" -ne 1 ]]; then
      die "No USB camera found"
    fi
  fi

  local tmpdir video_fifo stats_file ffmpeg_log font_path overlay_x overlay_y
  tmpdir="$(mktemp -d)"
  video_fifo="$tmpdir/video.h264"
  stats_file=$(mktemp --suffix=.txt)
  ffmpeg_log=$(mktemp --suffix=.log)

  mkfifo "$video_fifo"

  find_font_path font_path
  compute_overlay_position "$OVERLAY_CORNER" "$width" "$height" overlay_x overlay_y

  local camera_pid ffmpeg_pid monitor_pid

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
    rm -rf "$tmpdir" "$stats_file" "$ffmpeg_log"
  }

  trap cleanup_pipeline EXIT INT TERM

  local drawtext=""
  if [[ "$NO_OVERLAY" -eq 0 ]]; then
    if [[ -n "$font_path" ]]; then
      drawtext="drawtext=fontfile=$(escape_path_for_drawtext "$font_path"):textfile=$(escape_path_for_drawtext "$stats_file"):reload=1:x=${overlay_x}:y=${overlay_y}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
    else
      drawtext="drawtext=textfile=$(escape_path_for_drawtext "$stats_file"):reload=1:x=${overlay_x}:y=${overlay_y}:fontcolor=white:fontsize=28:box=1:boxcolor=0x000000AA:boxborderw=8:line_spacing=6"
    fi
  fi

  local duration_args=()
  if [[ "$DURATION" -gt 0 ]]; then
    duration_args=(-t "$DURATION")
  fi

  local output_args=()
  if [[ "$USE_FRAMEBUFFER" -eq 1 ]]; then
    output_args=(-f fbdev /dev/fb0)
  else
    output_args=(-f sdl "USB Camera Preview")
  fi

  if [[ -n "$drawtext" ]]; then
    stdbuf -oL -eL ffmpeg -hide_banner -loglevel info -stats \
      -fflags +nobuffer -flags +low_delay -reorder_queue_size 0 -thread_queue_size 512 \
      -f h264 -i "$video_fifo" "${duration_args[@]}" \
      -vf "$drawtext" -an "${output_args[@]}" \
      2> >(stdbuf -oL tee "$ffmpeg_log" >&2) &
  else
    stdbuf -oL -eL ffmpeg -hide_banner -loglevel info -stats \
      -fflags +nobuffer -flags +low_delay -reorder_queue_size 0 -thread_queue_size 512 \
      -f h264 -i "$video_fifo" "${duration_args[@]}" \
      -an "${output_args[@]}" \
      2> >(stdbuf -oL tee "$ffmpeg_log" >&2) &
  fi
  ffmpeg_pid=$!

  # Use ffmpeg to capture from USB camera and encode to H.264
  local input_format=""
  if command -v v4l2-ctl >/dev/null 2>&1; then
    local fmts
    fmts=$(v4l2-ctl --device="$usb_device" --list-formats-ext 2>/dev/null || true)
    if grep -q "H264" <<<"$fmts"; then
      input_format="h264"
    elif grep -q "MJPG" <<<"$fmts"; then
      input_format="mjpeg"
    elif grep -q "YUYV" <<<"$fmts"; then
      input_format="yuyv422"
    fi
  fi

  local encoding_method
  encoding_method=$(get_encoding_method)

  local -a ffmpeg_input_args=( -f v4l2 )
  if [[ -n "$input_format" ]]; then
    ffmpeg_input_args+=( -input_format "$input_format" )
  fi
  ffmpeg_input_args+=( -video_size "${width}x${height}" -framerate "$FPS" -i "$usb_device" )

  local duration_args=()
  if [[ "$DURATION" -gt 0 ]]; then
    duration_args=(-t "$DURATION")
  fi

  if [[ "$encoding_method" == "hardware" ]]; then
    if [[ "$input_format" == "h264" ]]; then
      stdbuf -oL ffmpeg -hide_banner -loglevel info -stats \
        "${ffmpeg_input_args[@]}" "${duration_args[@]}" \
        -c:v copy -f h264 "$video_fifo" &
      camera_pid=$!
    else
      stdbuf -oL ffmpeg -hide_banner -loglevel info -stats \
        "${ffmpeg_input_args[@]}" "${duration_args[@]}" \
        -pix_fmt nv12 -c:v h264_v4l2m2m \
        -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize $((BITRATE * 2)) \
        -f h264 "$video_fifo" &
      camera_pid=$!
    fi
  else
    stdbuf -oL ffmpeg -hide_banner -loglevel info -stats \
      "${ffmpeg_input_args[@]}" "${duration_args[@]}" \
      -c:v libx264 -preset ultrafast -tune zerolatency \
      -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize $((BITRATE * 2)) \
      -f h264 "$video_fifo" &
    camera_pid=$!
  fi

  if [[ "$NO_OVERLAY" -eq 0 ]]; then
    monitor_metrics "$stats_file" "$ffmpeg_log" "$width" "$height" "$BITRATE" "$FPS" "$camera_pid" "$ffmpeg_pid" &
    monitor_pid=$!
  fi

  log_info "Waiting for USB camera pipeline processes to complete..."
  wait "$camera_pid" 2>/dev/null || true
  wait "$ffmpeg_pid" 2>/dev/null || true
  if [[ "$NO_OVERLAY" -eq 0 ]]; then
    wait "$monitor_pid" 2>/dev/null || true
  fi

  log_info "USB camera pipeline completed successfully"
  trap - EXIT INT TERM
  cleanup_pipeline
}

start_capture() {
  local camera_type
  camera_type=$(get_camera_type)
  
  case "$METHOD" in
    h264_sdl_preview)
      case "$camera_type" in
        csi)
          echo "Using CSI camera module..."
          run_h264_sdl_preview
          ;;
        usb)
          echo "Using USB camera..."
          run_usb_h264_sdl_preview
          ;;
        none)
          die "No supported camera found. Please connect a CSI camera module or USB camera."
          ;;
      esac
      ;;
    *)
      die "Unsupported method '$METHOD'"
      ;;
  esac
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Script entry point - orchestrates the entire execution flow
# Handles argument parsing, dependency checking, and dispatches to appropriate functions
main() {
  # Initialize logging from environment
  LOG_LEVEL=${LOG_LEVEL:-1}
  LOG_FILE=${LOG_FILE:-""}
  
  # Initialize global variables with default values
  METHOD="$DEFAULT_METHOD"           # Capture method to use
  RESOLUTION="$DEFAULT_RESOLUTION"   # Video resolution
  FPS="$DEFAULT_FPS"                 # Frame rate
  BITRATE="$DEFAULT_BITRATE"         # Target bitrate
  OVERLAY_CORNER="$DEFAULT_CORNER"   # Stats overlay position
  SOURCE="$DEFAULT_SOURCE"           # Camera source
  ENCODE="$DEFAULT_ENCODE"           # Encoding method
  DURATION="$DEFAULT_DURATION"       # Recording duration in seconds
  USE_FRAMEBUFFER=0                  # Output to framebuffer instead of SDL
  SKIP_MENU=0                       # Skip interactive menu flag
  FORCE_MENU=0                      # Force menu display flag
  NO_OVERLAY=0                      # Skip overlay flag
  CHECK_DEPS_ONLY=0                 # Only check dependencies flag
  INSTALL_DEPS_ONLY=0               # Only install dependencies flag
  DEBUG_CAMERAS_ONLY=0              # Only show camera debug info flag
  USB_TEST_ONLY=0                   # Only run USB camera test flag
  LIST_CAMERAS_ONLY=0               # Only list cameras flag

  local original_argc=$#
  local show_menu=0
  local require_whiptail=0

  parse_arguments "$@"
  
  # Initialize logging after parsing arguments
  if [[ -n "$LOG_FILE" ]]; then
    log_info "Logging to file: $LOG_FILE"
  fi
  
  log_info "${SCRIPT_NAME} starting with config: ${RESOLUTION}@${FPS}fps, bitrate=${BITRATE}, source=${SOURCE}, encode=${ENCODE}, duration=${DURATION}s"
  log_debug "Method: ${METHOD}, Corner: ${OVERLAY_CORNER}, Framebuffer: ${USE_FRAMEBUFFER}"

  if [[ "$SKIP_MENU" -eq 0 ]]; then
    if [[ "$FORCE_MENU" -eq 1 || ( "$original_argc" -eq 0 && -t 0 && -t 1 ) ]]; then
      show_menu=1
      require_whiptail=1
    fi
  fi

  if (( DEBUG_CAMERAS_ONLY )); then
    run_camera_debug_report
    exit 0
  fi

  if (( USB_TEST_ONLY )); then
    if ! ensure_dependencies 0 1; then
      die "Dependencies remain missing; cannot run USB camera test."
    fi
    if run_usb_camera_test; then
      exit 0
    else
      exit 1
    fi
  fi

  if (( LIST_CAMERAS_ONLY )); then
    list_available_cameras
    exit 0
  fi

  if (( CHECK_DEPS_ONLY )); then
    if ensure_dependencies "$require_whiptail" 0; then
      exit 0
    else
      exit 1
    fi
  fi

  if (( INSTALL_DEPS_ONLY )); then
    if ensure_dependencies "$require_whiptail" 1; then
      exit 0
    else
      die "Dependency installation failed."
    fi
  fi

  if ! ensure_dependencies "$require_whiptail" 1; then
    die "Dependencies remain missing after automatic installation attempt."
  fi

  if [[ "$show_menu" -eq 1 ]]; then
    show_whiptail_wizard
  fi

  validate_configuration
  start_capture
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Execute main function with all command line arguments
main "$@"

