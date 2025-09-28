# picam_h264

Skrypt `picam.sh` udostępnia interaktywne menu (whiptail) oraz argumenty wiersza poleceń do uruchamiania testów wydajności kamery na Raspberry Pi Zero W. Aktualnie dostępna metoda pipeline wykorzystuje `libcamera-vid`, kodowanie H.264 i podgląd w oknie SDL zbudowanym przez `ffmpeg`.

## Wymagania

- Raspberry Pi OS (Bullseye lub nowszy) z aktywnym stosom libcamera.
- Zainstalowane pakiety: `libcamera-apps`, `ffmpeg`, `whiptail`, `coreutils` (dla `stdbuf`), `awk` i `ps` (z pakietu `procps`).
- Podłączona i skonfigurowana kamera CSI.

## Użycie

```bash
./picam.sh
```

Domyślnie skrypt wyświetla kreator z wykorzystaniem whiptail. Po wyborze ustawień rozpocznie się przechwytywanie obrazu, a w wybranym rogu okna pojawi się nakładka ze statystykami: FPS, rozdzielczość, bitrate, użycie CPU oraz pamięci dla procesów `libcamera-vid` i `ffmpeg`.

### Argumenty CLI

Każda opcja dostępna w kreatorze może zostać ustawiona z linii poleceń:

```bash
./picam.sh \
  --method h264_sdl_preview \
  --resolution 1920x1080 \
  --fps 25 \
  --bitrate 6000000 \
  --corner top-right \
  --no-menu
```

Przełącznik `--no-menu` pomija kreator. Aby wymusić jego pokazanie mimo podania argumentów, użyj `--menu`.

### Zakończenie

Aby zatrzymać nagrywanie i podgląd, naciśnij `Ctrl+C` w terminalu z uruchomionym skryptem.

## Rozszerzanie

Struktura skryptu umożliwia dodanie kolejnych metod przechwytywania. Wystarczy zaimplementować nową funkcję uruchamiającą odpowiedni pipeline wideo i dodać wpis w `start_capture()` oraz menu whiptail.
