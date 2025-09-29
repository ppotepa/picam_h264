# picam_h264

Camera benchmarking tools for Raspberry Pi Zero W wit### Diagnostic Modes

**Bash version diagnostics:**
```bash
./picam.sh --check-deps       # verify dependencies without installing packages
./picam.sh --install-deps     # install missing packages and exit
./picam.sh --debug-cameras    # display detected cameras report (CSI/USB)
./picam.sh --test-usb         # run 5-second USB camera capture test
```

**C version diagnostics:**
```bash
./picam_bench --list-cameras  # list all detected cameras with capabilities
./picam_bench --help          # show all available options
```

The `--test-usb` option uses `ffmpeg` directly without running the full pipeline – a quick way to verify USB device accessibility. The script automatically detects available camera formats (H264, MJPEG, YUYV) and selects the best available option.and C implementations.

## Available Implementations

### Bash Version (`picam.sh`)
Interactive bash script with whiptail menu and command-line arguments for camera performance testing. The default pipeline uses H.264 encoding with `libcamera-vid`/`rpicam-vid` (depending on system version) and SDL preview via `ffmpeg`. The script can automatically switch to USB camera recording (V4L2) without manual configuration changes.

### C Version (`picam_bench.c`)
High-performance C implementation with real-time threading, live performance overlay, and robust USB detection. Provides the same functionality as the bash version but with better performance monitoring and cross-platform compatibility.

## Wymagania

- Raspberry Pi OS (Bullseye lub nowszy).
- Co najmniej jedno urządzenie rejestrujące obraz:
  - kamera CSI obsługiwana przez libcamera,
  - **lub** kamera USB obsługiwana przez V4L2.
- Pakiety: `libcamera-apps` (dostarcza `libcamera-vid`/`rpicam-vid`), `ffmpeg`, `coreutils` (dla `stdbuf`), `gawk`, `procps` (`ps`) oraz `v4l-utils` (opcjonalnie, ale przydatny do diagnostyki kamer USB).
- `whiptail` (tylko gdy korzystasz z kreatora).

`picam.sh` automatycznie weryfikuje dostępność powyższych poleceń i – **tylko gdy czegoś brakuje** – spróbuje doinstalować wymagane pakiety (`sudo apt-get`, jeśli nie działasz jako root). Przy kolejnych uruchomieniach instalacja nie jest powtarzana, dzięki czemu start jest szybki.

## Usage

### Quick Start

**Bash version (interactive menu):**
```bash
./picam.sh
```

**C version (command line):**
```bash
./build.sh                    # Build the C implementation
./picam_bench --list-cameras  # List available cameras
./picam_bench --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000
```

Both implementations provide real-time overlay with statistics: FPS, resolution, bitrate, CPU and memory usage for camera and ffmpeg processes.

### Command Line Arguments

**Bash version options:**
```bash
./picam.sh \
  --method h264_sdl_preview \
  --resolution 1920x1080 \
  --fps 25 \
  --bitrate 6000000 \
  --corner top-right \
  --no-menu
```

**C version options:**
```bash
./picam_bench \
  --source auto \             # auto, csi, or /dev/videoN
  --encode hardware \         # auto, hardware, software
  --resolution 1920x1080 \
  --fps 25 \
  --bitrate 6000000 \
  --no-overlay
```

The `--no-menu` flag skips the interactive wizard in bash version. To force showing the menu despite providing arguments, use `--menu`.

Skrypt waliduje wartości FPS, bitrate oraz rozdzielczości i zakończy działanie z komunikatem błędu, jeśli parametry są niepoprawne. Po zatrzymaniu przechwytywania (również sygnałem `Ctrl+C`) tymczasowe pliki FIFO i procesy zostaną uporządkowane automatycznie.

### Tryby diagnostyczne

`picam.sh` udostępnia kilka przełączników pomocnych przy rozwiązywaniu problemów:

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
# Build the C implementation
./build.sh

# Or build manually
gcc -O2 -Wall -pthread -o picam_bench picam_bench.c
```

#### Basic Usage
```bash
# List available cameras
./picam_bench --list-cameras

# Auto-detect everything
./picam_bench --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000

# Quick default test
./picam_bench --no-menu --source auto --encode auto
```

#### Camera Source Selection
```bash
# Force CSI camera
./picam_bench --source csi --encode hardware --resolution 1920x1080 --fps 30 --bitrate 6000000

# Force specific USB camera
./picam_bench --source /dev/video0 --encode software --resolution 1280x720 --fps 30 --bitrate 4000000

# Auto-select with hardware encoding preference
./picam_bench --source auto --encode hardware --resolution 1920x1080 --fps 25 --bitrate 8000000
```

#### Performance Testing
```bash
# High quality 1080p test
./picam_bench --source auto --encode hardware --resolution 1920x1080 --fps 30 --bitrate 10000000

# Low latency 720p test
./picam_bench --source auto --encode hardware --resolution 1280x720 --fps 60 --bitrate 6000000 --no-overlay

# Software encoding comparison
./picam_bench --source auto --encode software --resolution 1280x720 --fps 30 --bitrate 4000000
```

#### USB Camera Specific
```bash
# Test Logitech C920 (common USB camera)
./picam_bench --source /dev/video0 --encode hardware --resolution 1280x720 --fps 30 --bitrate 4000000

# Test with different USB camera
./picam_bench --source /dev/video2 --encode software --resolution 640x480 --fps 30 --bitrate 2000000
```

#### Overlay Options
```bash
# Disable performance overlay
./picam_bench --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000 --no-overlay

# Default with overlay (shows FPS, bitrate, CPU, memory)
./picam_bench --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000
```

### Quick Test Sequence

#### Test Everything Available
```bash
# 1. Check what cameras are detected
./picam.sh --debug-cameras

# 2. Test bash version with auto-detection
./picam.sh --no-menu --resolution 1280x720 --fps 30 --bitrate 4000000

# 3. Build and test C version
./build.sh
./picam_bench --list-cameras
./picam_bench --source auto --encode auto --resolution 1280x720 --fps 30 --bitrate 4000000
```

#### Troubleshooting Commands
```bash
# If USB camera not detected
./picam.sh --debug-cameras
./picam.sh --test-usb

# If build fails
./build.sh  # Check error output
sudo apt update && sudo apt install build-essential linux-libc-dev

# If ffmpeg preview fails
./picam_bench --source auto --encode auto --no-overlay --resolution 640x480 --fps 15
```

## Key Features

- **Robust USB Camera Detection**: Advanced hex capability parsing for V4L2 devices with fallback detection methods
- **Real-time Performance Monitoring**: Live FPS, bitrate, CPU, and memory usage overlay
- **Cross-Platform Compatibility**: Works on Raspberry Pi OS Bullseye, Bookworm, and other Debian-based systems
- **Hardware/Software Encoding**: Automatic detection and selection of optimal encoding method
- **Interactive and CLI Modes**: Both menu-driven and command-line interfaces available
- **Threading Support**: C version uses dedicated threads for monitoring and overlay rendering

## Extending

Both implementations support adding new capture methods. For the bash version, implement a new function with the appropriate video pipeline and add entries in `start_capture()` and the whiptail menu. The C version uses a modular architecture that allows easy addition of new source and encoding types.
