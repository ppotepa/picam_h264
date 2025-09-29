#!/usr/bin/env bash
# Simple USB camera test script

echo "=== USB Camera Test ==="

# Check for video devices
echo "Video devices:"
ls -la /dev/video* 2>/dev/null || echo "No video devices found"

# Check if v4l2-ctl is available
if command -v v4l2-ctl >/dev/null 2>&1; then
    echo -e "\n=== Testing each video device ==="
    for device in /dev/video*; do
        if [[ -c "$device" ]]; then
            echo -e "\n--- Testing $device ---"
            echo "Device info:"
            v4l2-ctl --device="$device" --info 2>/dev/null || echo "Failed to get device info"
            
            echo "Supported formats:"
            v4l2-ctl --device="$device" --list-formats-ext 2>/dev/null | head -20 || echo "Failed to list formats"
        fi
    done
    
    echo -e "\n=== Testing ffmpeg with USB camera ==="
    USB_DEVICE=""
    for device in /dev/video*; do
        if [[ -c "$device" ]]; then
            if v4l2-ctl --device="$device" --list-formats-ext 2>/dev/null | grep -q "MJPG\|YUYV"; then
                USB_DEVICE="$device"
                break
            fi
        fi
    done
    
    if [[ -n "$USB_DEVICE" ]]; then
        echo "Testing ffmpeg with $USB_DEVICE for 5 seconds..."
        timeout 5s ffmpeg -f v4l2 -input_format mjpeg -video_size 640x480 -framerate 15 -i "$USB_DEVICE" -f null - 2>&1 | tail -10
        echo "Test completed."
    else
        echo "No suitable USB camera found for testing"
    fi
else
    echo "v4l2-ctl not available. Install with: sudo apt-get install v4l-utils"
fi

echo -e "\n=== Manual ffmpeg test command ==="
echo "You can manually test your USB camera with:"
echo "ffmpeg -f v4l2 -input_format mjpeg -video_size 640x480 -framerate 15 -i /dev/video0 -t 5 test.mp4"