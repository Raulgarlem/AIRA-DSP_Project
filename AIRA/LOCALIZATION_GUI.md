# Interfaz de localizacion DAS

La interfaz ejecuta la localizacion DAS adaptativa sobre los tres archivos
`wav_micX.wav` de una carpeta y los envia al localizador mediante JACK.

## Dependencias en Linux

En Debian o Ubuntu:

```bash
sudo apt install build-essential cmake pkg-config \
  libjack-jackd2-dev libsndfile1-dev libfftw3-dev libgtk-3-dev
```

JACK debe estar iniciado y configurado a `48000 Hz`.

## Compilacion

Desde la carpeta `AIRA`:

```bash
cmake -S . -B build
cmake --build build -j
```

## Ejecucion

Desde la carpeta `AIRA`:

```bash
./build/localization_gui
```

Seleccione una carpeta que contenga:

```text
info.txt
wav_mic1.wav
wav_mic2.wav
wav_mic3.wav
```

Al pulsar `Play`, la interfaz ejecuta `StartProjectScript.sh`. El script
inicia `jack_das_localizer`, inicia `ReadMicWavs` y conecta sus tres salidas
con las tres entradas del localizador.

La interfaz conserva solamente el resultado mas reciente. Cada nueva
ventana sustituye los angulos calculados, el intervalo, el modo y la
confianza mostrados anteriormente.
