#!/usr/bin/env bash
# picam_menu.sh - convenience launcher for common benchmarking commands
# Prpicamovides a simple text menu so you can quickly run frequently used
# command combinations without retyping them each time.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMMANDS=()
NAMES=()

# Helper to register menu entries
add_entry() {
  local name="$1"
  shift
  NAMES+=("$name")
  COMMANDS+=("$*")
}

# Build and Setup
add_entry "Build C implementation" "./build.sh"
add_entry "Debug camera detection (bash)" "./picam.sh --debug-cameras"
add_entry "List cameras (C version)" "./picam_bench --list-cameras"
add_entry "Test USB camera (bash)" "./picam.sh --test-usb"

# Bash Script Tests - Various Resolutions and Settings
add_entry "Bash: 640x480 30fps USB /dev/video0" "./picam.sh --no-menu --source /dev/video0 --resolution 640x480 --fps 30 --bitrate 1000000 --duration 10"
add_entry "Bash: 1280x720 30fps auto-detect" "./picam.sh --no-menu --source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --duration 15"
add_entry "Bash: 1920x1080 25fps CSI camera" "./picam.sh --no-menu --source csi --resolution 1920x1080 --fps 25 --bitrate 8000000 --duration 10"
add_entry "Bash: 1920x1080 30fps USB hardware encode" "./picam.sh --no-menu --source /dev/video0 --encode hardware --resolution 1920x1080 --fps 30 --bitrate 6000000 --duration 12"
add_entry "Bash: 1280x720 60fps software encode" "./picam.sh --no-menu --source auto --encode software --resolution 1280x720 --fps 60 --bitrate 5000000 --duration 8"
add_entry "Bash: 800x600 25fps low bitrate" "./picam.sh --no-menu --source auto --resolution 800x600 --fps 25 --bitrate 2000000 --duration 15"
add_entry "Bash: 1920x1080 15fps high bitrate CSI" "./picam.sh --no-menu --source csi --resolution 1920x1080 --fps 15 --bitrate 10000000 --duration 20"
add_entry "Bash: 1280x720 30fps framebuffer out" "./picam.sh --no-menu --source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --fb0 --duration 10"
add_entry "Bash: 640x480 15fps USB infinite" "./picam.sh --no-menu --source /dev/video0 --resolution 640x480 --fps 15 --bitrate 1500000"
add_entry "Bash: 1600x1200 20fps auto-detect" "./picam.sh --no-menu --source auto --resolution 1600x1200 --fps 20 --bitrate 7000000 --duration 12"

# C Implementation Tests - Various Configurations
add_entry "C: 640x480 30fps USB /dev/video0" "./picam --source /dev/video0 --resolution 640x480 --fps 30 --bitrate 1000000 --duration 10"
add_entry "C: 1280x720 30fps auto-detect" "./picam --source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --duration 15"
add_entry "C: 1920x1080 25fps CSI camera" "./picam --source csi --resolution 1920x1080 --fps 25 --bitrate 8000000 --duration 10"
add_entry "C: 1920x1080 30fps USB hardware encode" "./picam --source /dev/video0 --encode hardware --resolution 1920x1080 --fps 30 --bitrate 6000000 --duration 12"
add_entry "C: 1280x720 60fps software encode" "./picam_ --source auto --encode software --resolution 1280x720 --fps 60 --bitrate 5000000 --duration 8"
add_entry "C: 800x600 25fps low bitrate" "./picam_ch --source auto --resolution 800x600 --fps 25 --bitrate 2000000 --duration 15"
add_entry "C: 1920x1080 15fps high bitrate CSI" "./picam --source csi --resolution 1920x1080 --fps 15 --bitrate 10000000 --duration 20"
add_entry "C: 1280x720 30fps framebuffer out" "./picam--source auto --resolution 1280x720 --fps 30 --bitrate 4000000 --fb0 --duration 10"
add_entry "C: 640x480 15fps USB infinite" "./picam --source /dev/video0 --resolution 640x480 --fps 15 --bitrate 1500000"
add_entry "C: 1600x1200 20fps auto-detect" "./picam --source auto --resolution 1600x1200 --fps 20 --bitrate 7000000 --duration 12"

# Special Tests and Interactive Modes
add_entry "Bash: Interactive menu wizard" "./picam.sh"
add_entry "Bash: No overlay performance test" "./picam.sh --no-menu --no-overlay --source auto --resolution 1920x1080 --fps 30 --bitrate 6000000 --duration 10"
add_entry "C: No overlay performance test" "./picam_bench --no-overlay --source auto --resolution 1920x1080 --fps 30 --bitrate 6000000 --duration 10"

print_menu() {
  echo
  echo "Select an action:" 
  local idx=1
  for name in "${NAMES[@]}"; do
    printf "  %d) %s\n" "$idx" "$name"
    ((idx++))
  done
  printf "  c) Custom command\n"
  printf "  q) Quit\n"
  echo
}

run_command() {
  local cmd="$1"
  echo
  echo "========================================"
  echo "[$(date '+%H:%M:%S')] Executing: $cmd"
  echo "========================================"
  echo
  
  # Log to file if LOG_FILE env var is set
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "[$(date '+%H:%M:%S')] Menu executed: $cmd" >> "$LOG_FILE"
  fi
  
  # shellcheck disable=SC2086
  eval "$cmd"
  local exit_code=$?
  
  echo
  echo "========================================"
  echo "[$(date '+%H:%M:%S')] Command completed with exit code: $exit_code"
  echo "========================================"
  
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "[$(date '+%H:%M:%S')] Command completed with exit code: $exit_code" >> "$LOG_FILE"
  fi
  
  return $exit_code
}

while true; do
  print_menu
  read -rp "Enter choice: " choice
  case "$choice" in
    q|Q|quit|exit)
      echo "Bye!"
      exit 0
      ;;
    c|C)
      read -rp "Enter custom command: " custom
      [[ -z "$custom" ]] && continue
      run_command "$custom"
      ;;
    '' )
      continue
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$((choice-1))
        if (( idx >= 0 && idx < ${#COMMANDS[@]} )); then
          run_command "${COMMANDS[$idx]}"
        else
          echo "Invalid numeric choice: $choice"
        fi
      else
        echo "Unknown option: $choice"
      fi
      ;;
  esac
  echo
  read -rp "Press Enter to return to menu..." _
  echo
done
