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
    echo "SUCCESS: $CAMERA_CMD is available"
    $CAMERA_CMD --list-cameras 2>&1 | head -10
else
    echo "FAILED: $CAMERA_CMD is not available"
fi

echo -e "\n=== Camera Detection Test ==="

# Test libcamera detection more thoroughly
echo "Testing libcamera camera detection:"
CAMERA_OUTPUT=$($CAMERA_CMD --list-cameras 2>&1)
echo "$CAMERA_OUTPUT"

if echo "$CAMERA_OUTPUT" | grep -q "Available cameras" && \
   ! echo "$CAMERA_OUTPUT" | grep -q "ERROR.*no cameras available"; then
    if echo "$CAMERA_OUTPUT" | grep -qv "usb@"; then
        echo "CSI Camera: YES (libcamera found non-USB cameras)"
    else
        echo "CSI Camera: NO (libcamera only found USB cameras)"
    fi
else
    echo "CSI Camera: NO (libcamera error or no cameras)"
fi

# Test USB camera detection
echo -e "\nTesting USB camera detection:"
detect_cameras() {
  local csi_available=0
  local usb_available=0
  local usb_device=""
  
  # Check for CSI camera using libcamera - more robust detection
  if command -v "$CAMERA_CMD" >/dev/null 2>&1; then
    local camera_output
    camera_output=$($CAMERA_CMD --list-cameras 2>&1)
    
    # Check if there are actual CSI cameras (not just USB cameras detected by libcamera)
    if echo "$camera_output" | grep -q "Available cameras" && \
       ! echo "$camera_output" | grep -q "ERROR.*no cameras available"; then
      # Further check: ensure it's not just USB cameras being detected
      if echo "$camera_output" | grep -qv "usb@"; then
        csi_available=1
      fi
    fi
  fi
  
  # Check for USB cameras using V4L2
  if ls /dev/video* >/dev/null 2>&1; then
    for device in /dev/video*; do
      # Check if device is accessible and supports common formats
      if command -v v4l2-ctl >/dev/null 2>&1; then
        if v4l2-ctl --device="$device" --list-formats-ext 2>/dev/null | grep -q "H264\|MJPG\|YUYV"; then
          usb_available=1
          usb_device="$device"
          break
        fi
      else
        # Fallback: if v4l2-ctl not available, assume first video device is usable
        if [[ -c "$device" ]]; then
          usb_available=1
          usb_device="$device"
          break
        fi
      fi
    done
  fi
  
  echo "CSI Camera Available: $csi_available"
  echo "USB Camera Available: $usb_available"
  echo "USB Device: $usb_device"
}

detect_cameras

# Test what camera type would be selected
get_camera_type() {
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

echo -e "\nSelected camera type: $(get_camera_type)"

echo -e "\n=== USB Camera Details ==="
if ls /dev/video* >/dev/null 2>&1; then
    echo "Video devices found:"
    ls -la /dev/video*
    if command -v v4l2-ctl >/dev/null 2>&1; then
        for device in /dev/video*; do
            echo -e "\n--- $device ---"
            v4l2-ctl --device="$device" --list-formats-ext 2>/dev/null | head -20
        done
    else
        echo "v4l2-ctl not available - install v4l-utils package"
    fi
else
    echo "No video devices found"
fi