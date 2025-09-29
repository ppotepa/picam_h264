#!/bin/bash
# build_menu.sh - Build script for picam_menu.c
# Creates the interactive menu launcher for quick testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/picam_menu.c"
OUT="${SCRIPT_DIR}/picam_menu"

echo "Building picam_menu (C menu launcher)..."
echo "Source: $SOURCE"
echo "Output: $OUT"

# Check if source file exists
if [ ! -f "$SOURCE" ]; then
    echo "Error: Source file $SOURCE not found"
    exit 1
fi

# Compile with optimizations and warnings
gcc -O2 -Wall -Wextra -o "$OUT" "$SOURCE"

if [ $? -eq 0 ]; then
    echo "Build successful: $OUT"
    echo "Usage: ./picam_menu"
    echo ""
    echo "Available environment variables:"
    echo "  LOG_FILE=path    - Enable logging to file"
    echo ""
    echo "Example with logging:"
    echo "  LOG_FILE=menu.log ./picam_menu"
else
    echo "Build failed"
    exit 1
fi