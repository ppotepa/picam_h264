#!/usr/bin/env bash
# picam_menu.sh - convenience launcher for common benchmarking commands
# Provides a simple text menu so you can quickly run frequently used
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

add_entry "Build C implementation" "./build.sh"
add_entry "Run C benchmark (auto-detect camera)" "./picam_bench --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000"
add_entry "Run C benchmark (force USB /dev/video0)" "./picam_bench --source /dev/video0 --encode auto --resolution 1920x1080 --fps 30 --bitrate 6000000"
add_entry "Run bash benchmark (interactive menu)" "./picam.sh"
add_entry "Run bash benchmark headless" "./picam.sh --no-menu --source auto --resolution 1280x720 --fps 30 --bitrate 4000000"
add_entry "Debug camera detection" "./picam.sh --debug-cameras"
add_entry "List cameras (C version)" "./picam_bench --list-cameras"

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
  echo "Executing: $cmd"
  echo "========================================"
  echo
  # shellcheck disable=SC2086
  eval "$cmd"
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
