# picam_h264

Skrypt `picam.sh` udostęp### Tryby diagnostyczne

`picam.sh` udostępnia kilka przełączników pomocnych przy rozwiązywaniu problemów:

```bash
./picam.sh --check-deps       # weryfikuje zależności, nie instaluje pakietów
./picam.sh --install-deps     # doinstalowuje brakujące pakiety i kończy działanie
./picam.sh --debug-cameras    # wypisuje raport wykrytych kamer (CSI/USB)
./picam.sh --test-usb         # uruchamia 5‑sekundowy test przechwytywania z kamery USB
```

Opcja `--test-usb` korzysta bezpośrednio z `ffmpeg` i nie uruchamia pełnego pipeline'u – to szybki sposób na sprawdzenie, czy urządzenie USB jest poprawnie dostępne. Skrypt automatycznie wykrywa dostępne formaty kamery (H264, MJPEG, YUYV) i dobiera najlepszy dostępny. W przypadku problemów, podejmuje próbę przechwycenia obrazu bez określania formatu.ywne menu (whiptail) oraz argumenty wiersza poleceń do uruchamiania testów wydajności kamery na Raspberry Pi Zero W. Domyślna metoda pipeline korzysta z kodowania H.264, procesów `libcamera-vid`/`rpicam-vid` (zależnie od wersji systemu) oraz podglądu SDL uruchamianego przez `ffmpeg`. Skrypt potrafi również automatycznie przełączyć się na rejestrację z kamer USB (V4L2), dzięki czemu nie trzeba ręcznie modyfikować konfiguracji.

## Wymagania

- Raspberry Pi OS (Bullseye lub nowszy).
- Co najmniej jedno urządzenie rejestrujące obraz:
  - kamera CSI obsługiwana przez libcamera,
  - **lub** kamera USB obsługiwana przez V4L2.
- Pakiety: `libcamera-apps` (dostarcza `libcamera-vid`/`rpicam-vid`), `ffmpeg`, `coreutils` (dla `stdbuf`), `gawk`, `procps` (`ps`) oraz `v4l-utils` (opcjonalnie, ale przydatny do diagnostyki kamer USB).
- `whiptail` (tylko gdy korzystasz z kreatora).

`picam.sh` automatycznie weryfikuje dostępność powyższych poleceń i – **tylko gdy czegoś brakuje** – spróbuje doinstalować wymagane pakiety (`sudo apt-get`, jeśli nie działasz jako root). Przy kolejnych uruchomieniach instalacja nie jest powtarzana, dzięki czemu start jest szybki.

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

### Tryby diagnostyczne

`picam.sh` udostępnia kilka przełączników pomocnych przy rozwiązywaniu problemów:

```bash
./picam.sh --check-deps       # weryfikuje zależności, nie instaluje pakietów
./picam.sh --install-deps     # doinstalowuje brakujące pakiety i kończy działanie
./picam.sh --debug-cameras    # wypisuje raport wykrytych kamer (CSI/USB)
./picam.sh --test-usb         # uruchamia 5‑sekundowy test przechwytywania z kamery USB
```

Opcja `--test-usb` korzysta bezpośrednio z `ffmpeg` i nie uruchamia pełnego pipeline’u – to szybki sposób na sprawdzenie, czy urządzenie USB jest poprawnie dostępne.

### Zakończenie

Aby zatrzymać nagrywanie i podgląd, naciśnij `Ctrl+C` w terminalu z uruchomionym skryptem.

## Rozszerzanie

Struktura skryptu umożliwia dodanie kolejnych metod przechwytywania. Wystarczy zaimplementować nową funkcję uruchamiającą odpowiedni pipeline wideo i dodać wpis w `start_capture()` oraz menu whiptail.
