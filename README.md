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

## Key Features

- **Robust USB Camera Detection**: Advanced hex capability parsing for V4L2 devices with fallback detection methods
- **Real-time Performance Monitoring**: Live FPS, bitrate, CPU, and memory usage overlay
- **Cross-Platform Compatibility**: Works on Raspberry Pi OS Bullseye, Bookworm, and other Debian-based systems
- **Hardware/Software Encoding**: Automatic detection and selection of optimal encoding method
- **Interactive and CLI Modes**: Both menu-driven and command-line interfaces available
- **Threading Support**: C version uses dedicated threads for monitoring and overlay rendering

## Extending

Both implementations support adding new capture methods. For the bash version, implement a new function with the appropriate video pipeline and add entries in `start_capture()` and the whiptail menu. The C version uses a modular architecture that allows easy addition of new source and encoding types.
