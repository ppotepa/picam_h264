#!/usr/bin/env bash
# Quick dependency installer for picam_h264
# Run this script on your Raspberry Pi to install missing dependencies

set -euo pipefail

echo "Installing required dependencies for picam_h264..."

# Make sure we have the latest package list
sudo apt-get update

# Install libcamera-apps (which provides libcamera-vid)
echo "Installing libcamera-apps..."
sudo apt-get install -y libcamera-apps

# Install other required packages
echo "Installing other required packages..."
sudo apt-get install -y ffmpeg gawk procps coreutils whiptail

echo "All dependencies installed successfully!"
echo "You can now run ./picam.sh"

# Make scripts executable
chmod +x dep.sh 2>/dev/null || true
chmod +x picam.sh 2>/dev/null || true

echo "Scripts are now executable."