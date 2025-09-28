#!/usr/bin/env bash
# Debug script to find libcamera binaries and test the updated detection

echo "=== Testing camera command detection ==="
get_camera_command() {
  if command -v libcamera-vid >/dev/null 2>&1; then
    echo "libcamera-vid"
  elif command -v rpicam-vid >/dev/null 2>&1; then
    echo "rpicam-vid"
  else
    echo "libcamera-vid"  # fallback for error messages
  fi
}

CAMERA_CMD=$(get_camera_command)
echo "Detected camera command: $CAMERA_CMD"

echo -e "\n=== Checking libcamera-apps package contents ==="
dpkg -L libcamera-apps | grep bin

echo -e "\n=== Searching for libcamera binaries in PATH ==="
which libcamera-vid 2>/dev/null || echo "libcamera-vid not found in PATH"
which rpicam-vid 2>/dev/null || echo "rpicam-vid not found in PATH"

echo -e "\n=== Searching for any libcamera/rpicam binaries ==="
find /usr/bin /usr/local/bin -name "*libcamera*" -o -name "*rpicam*" 2>/dev/null

echo -e "\n=== Current PATH ==="
echo $PATH

echo -e "\n=== Testing commands directly ==="
/usr/bin/libcamera-vid --help >/dev/null 2>&1 && echo "libcamera-vid works from /usr/bin" || echo "libcamera-vid not working from /usr/bin"
/usr/bin/rpicam-vid --help >/dev/null 2>&1 && echo "rpicam-vid works from /usr/bin" || echo "rpicam-vid not working from /usr/bin"

echo -e "\n=== Package version ==="
dpkg -l | grep libcamera

echo -e "\n=== Testing the camera command ==="
if command -v "$CAMERA_CMD" >/dev/null 2>&1; then
    echo "SUCCESS: $CAMERA_CMD is available and should work"
    $CAMERA_CMD --help 2>&1 | head -5
else
    echo "FAILED: $CAMERA_CMD is not available"
fi