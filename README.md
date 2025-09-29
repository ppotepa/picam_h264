# picam_h264

Camera benchmarking tools for Raspberry Pi with both Bash and C implementations.

## Overview

High-performance camera benchmarking suite for Raspberry Pi systems, featuring real-time performance monitoring, automatic camera detection, and support for both CSI and USB cameras. Available in two implementations:

- **Bash Version** (`picam.sh`): Interactive menu-driven script with whiptail interface
- **C Version** (`picam.c`): High-performance implementation with real-time threading and live overlay

## Features

- 🎥 **Multi-Camera Support**: CSI cameras (libcamera) and USB cameras (V4L2)
- 📊 **Real-time Monitoring**: Live FPS, bitrate, CPU, and memory usage overlay
- 🔧 **Automatic Detection**: Smart camera and encoding capability detection
- ⚡ **Hardware Acceleration**: Automatic hardware/software encoding selection
- 🎛️ **Flexible Interface**: Both interactive menu and command-line modes
- 🐛 **Diagnostic Tools**: Built-in camera testing and dependency checking

## Requirements

- **OS**: Raspberry Pi OS (Bullseye or newer)
- **Hardware**: At least one camera device:
  - CSI camera supported by libcamera
  - **OR** USB camera supported by V4L2
- **Dependencies**: 
  - `libcamera-apps` (provides `libcamera-vid`/`rpicam-vid`)
  - `ffmpeg`
  - `v4l-utils` (optional, for USB camera diagnostics)
  - `whiptail` (for interactive menu)
  - Build tools: `gcc`, `build-essential` (for C version)

The scripts automatically verify and install missing dependencies when needed.

## Quick Start

### Bash Version (Interactive)
```bash
# Clone and run interactive menu
git clone https://github.com/ppotepa/picam_h264.git
cd picam_h264
./picam.sh
```

### C Version (High Performance)
```bash
# Build and run
./build.sh
./picam --list-cameras
./picam --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000
```

## Available Implementations

### 🐚 Bash Version (`picam.sh`)
- **Interactive menu** with whiptail interface
- **Automatic dependency management**
- **Command-line argument support**
- **Built-in diagnostics and testing**
- Perfect for quick testing and development

### ⚡ C Version (`picam.c`)
- **Real-time threading** for better performance
- **Live performance overlay** with detailed statistics
- **Robust USB camera detection** with hex capability parsing
- **Cross-platform compatibility**
- Ideal for production use and benchmarking

## Command Line Usage

### Bash Version Options
```bash
./picam.sh [OPTIONS]

Options:
  --method METHOD          Capture method (default: h264_sdl_preview)
  --resolution WxH         Video resolution (default: 1280x720)
  --fps N                  Frames per second (default: 30)
  --bitrate N              Video bitrate in bps (default: 4000000)
  --corner POSITION        Overlay corner (top-left, top-right, bottom-left, bottom-right)
  --no-menu               Skip interactive menu
  --menu                  Force show menu despite arguments
  
Diagnostic Options:
  --check-deps            Verify dependencies without installing
  --install-deps          Install missing packages and exit
  --debug-cameras         Display detected cameras report
  --test-usb              Run 5-second USB camera test
  --help                  Show help message
```

### C Version Options
```bash
./picam [OPTIONS]

Options:
  -s, --source SOURCE     Camera source: auto, csi, or /dev/videoN
  -e, --encode MODE       Encoding: auto, hardware, software
  -r, --resolution WxH    Video resolution (default: 1280x720)
  -f, --fps N             Frames per second (default: 30)
  -b, --bitrate N         Video bitrate in bps (default: 4000000)
  -d, --duration N        Recording duration in seconds (0 = infinite)
  -c, --corner POSITION   Overlay corner position
  -v, --verbose           Increase verbosity (can be used multiple times)
  --quiet                 Only show errors
  --log-file FILE         Log to file instead of stderr
  --no-overlay            Disable performance overlay
  --list-cameras          List all detected cameras
  --help                  Show help message
```

## How to Stop

To stop recording and preview, press `Ctrl+C` in the terminal running the script or application.

## Diagnostic Tools

### Bash Version Diagnostics
```bash
./picam.sh --check-deps       # Verify dependencies without installing
./picam.sh --install-deps     # Install missing packages and exit
./picam.sh --debug-cameras    # Display detected cameras report
./picam.sh --test-usb         # Run 5-second USB camera test
```

### C Version Diagnostics
```bash
./picam --list-cameras        # List all detected cameras with capabilities
./picam --help               # Show all available options
```

The `--test-usb` option uses `ffmpeg` directly without running the full pipeline – a quick way to verify USB device accessibility.

```bash
./picam.sh --check-deps       # weryfikuje zależności, nie instaluje pakietów
./picam.sh --install-deps     # doinstalowuje brakujące pakiety i kończy działanie
./picam.sh --debug-cameras    # wypisuje raport wykrytych kamer (CSI/USB)
./picam.sh --test-usb         # uruchamia 5‑sekundowy test przechwytywania z kamery USB
```

Opcja `--test-usb` korzysta bezpośrednio z `ffmpeg` i nie uruchamia pełnego pipeline’u – to szybki sposób na sprawdzenie, czy urządzenie USB jest poprawnie dostępne.

### Stopping

To stop recording and preview, press `Ctrl+C` in the terminal running the script or application.

## Command Examples

### Bash Version (`picam.sh`)

#### Basic Usage
```bash
# Interactive menu (default)
./picam.sh

# Skip menu with auto-detection
./picam.sh --no-menu

# Quick test with specific settings
./picam.sh --no-menu --resolution 1280x720 --fps 30 --bitrate 4000000
```

#### Camera Source Selection
```bash
# Force CSI camera
./picam.sh --no-menu --method h264_sdl_preview --resolution 1920x1080

# Auto-detect best camera
./picam.sh --no-menu --resolution 1280x720 --fps 25 --bitrate 2000000
```

#### High Quality Recording
```bash
# 1080p 30fps high bitrate
./picam.sh --no-menu --resolution 1920x1080 --fps 30 --bitrate 8000000 --corner bottom-right

# 720p 60fps (if supported)
./picam.sh --no-menu --resolution 1280x720 --fps 60 --bitrate 6000000
```

#### Diagnostic Commands
```bash
# Check what cameras are detected
./picam.sh --debug-cameras

# Test USB camera quickly
./picam.sh --test-usb

# Check dependencies
./picam.sh --check-deps

# Install missing packages
./picam.sh --install-deps
```

### C Version (`picam_bench`)

#### Build First
```bash
# List all detected cameras
./picam --list-cameras

# Quick verbose test
./picam --source auto --encode auto --verbose
```

### Quick Test Sequence

```bash
# 1. Check what cameras are detected
./picam.sh --debug-cameras

# 2. Test bash version with auto-detection
./picam.sh --no-menu --resolution 1280x720 --fps 30 --bitrate 4000000

# 3. Build and test C version
./build.sh
./picam --list-cameras
./picam --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000
```

### Troubleshooting

```bash
# If USB camera not detected
./picam.sh --debug-cameras
./picam.sh --test-usb

# If build fails
./build.sh  # Check error output
sudo apt update && sudo apt install build-essential linux-libc-dev

# If preview fails
./picam --source auto --encode auto --no-overlay --resolution 640x480 --fps 15
```

## Technical Features

- 🔍 **Advanced USB Detection**: Hex capability parsing for V4L2 devices with fallback methods
- 📊 **Real-time Monitoring**: Live FPS, bitrate, CPU, and memory usage overlay
- 🔧 **Smart Encoding**: Automatic hardware/software encoding detection and selection
- 🧵 **Multi-threading**: C version uses dedicated threads for monitoring and rendering
- 📱 **Cross-platform**: Compatible with Raspberry Pi OS Bullseye, Bookworm, and Debian-based systems
- 🎛️ **Dual Interface**: Both interactive menu and command-line modes available

## Architecture

### Bash Implementation
- **Interactive Menu**: Whiptail-based user interface
- **Pipeline**: libcamera-vid/rpicam-vid → ffmpeg → SDL preview
- **Monitoring**: Background processes for statistics collection
- **Auto-detection**: Camera and capability discovery

### C Implementation
- **Multi-threaded**: Separate threads for capture, preview, and monitoring
- **Real-time Overlay**: Live statistics rendering with configurable position
- **Robust Detection**: Advanced V4L2 capability parsing
- **Memory Efficient**: Optimized for Raspberry Pi Zero W and similar devices

## Development

### Adding New Capture Methods

**Bash Version:**
1. Implement new function in `picam.sh`
2. Add entry in `start_capture()` function
3. Update whiptail menu options

**C Version:**
1. Add new source type to `source_t` enum
2. Implement handler in main capture loop
3. Update argument parsing

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on Raspberry Pi hardware
5. Submit a pull request

## License

MIT License - see individual files for details.

## Support

- **Issues**: Report bugs and feature requests on GitHub
- **Documentation**: Check the README for examples
- **Hardware**: Tested on Raspberry Pi Zero W, 3B+, 4B
- **OS Support**: Raspberry Pi OS Bullseye and Bookworm
