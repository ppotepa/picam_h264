# picam_h264

Skrypt `picam.sh` udostępnia interaktywne menu (whiptail) oraz argumenty wiersza poleceń do uruchamiania testów wydajności kamery na Raspberry Pi Zero W. Aktualnie dostępna metoda pipeline wykorzystuje `libcamera-vid`, kodowanie H.264 i podgląd w oknie SDL zbudowanym przez `ffmpeg`.

## Wymagania

- Raspberry Pi OS (Bullseye lub nowszy) z aktywnym stosom libcamera.
- Podłączona i skonfigurowana kamera CSI.
- Zainstalowane pakiety: `libcamera-apps`, `ffmpeg`, `coreutils` (dla `stdbuf`), `awk` i `ps` (z pakietu `procps`). Pakiet `libcamera-apps`
  dostarcza polecenie `libcamera-vid` wymagane przez pipeline H.264.
- `whiptail` (wymagany tylko, gdy korzystasz z kreatora).

`picam.sh` automatycznie sprawdza obecność powyższych poleceń i, jeśli to możliwe, doinstaluje brakujące pakiety (`apt-get` z użyciem `sudo`, gdy nie uruchamiasz skryptu jako root). Do ręcznej obsługi zależności możesz wykorzystać pomocniczy skrypt `dep.sh`:

```bash
# samo sprawdzenie
./dep.sh --check

# instalacja braków (wymaga roota lub sudo)
sudo ./dep.sh
```

Aby wykonać weryfikację środowiska bez uruchamiania benchmarku, użyj również `./picam.sh --check-deps`. Dodaj `--menu`, aby w trybie sprawdzania potraktować `whiptail` jako zależność obowiązkową.

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

Skrypt waliduje wartości FPS, bitrate oraz rozdzielczości i zakończy działanie z komunikatem błędu, jeśli parametry są niepoprawne. Po zatrzymaniu przechwytywania (również sygnałem `Ctrl+C`) tymczasowe pliki FIFO i procesy zostaną uporządkowane automatycznie.

### Zakończenie

Aby zatrzymać nagrywanie i podgląd, naciśnij `Ctrl+C` w terminalu z uruchomionym skryptem.

## Rozszerzanie

Struktura skryptu umożliwia dodanie kolejnych metod przechwytywania. Wystarczy zaimplementować nową funkcję uruchamiającą odpowiedni pipeline wideo i dodać wpis w `start_capture()` oraz menu whiptail.
