# Interfaz de localizacion

La interfaz localiza fuentes sobre los tres archivos `wav_micX.wav` de una
carpeta y los envia al localizador mediante JACK.

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

Antes de pulsar `Play`, seleccione uno de los metodos:

- `DAS adaptativo`: compara DAS base con DAS ponderado por SNR.
- `SRP-PHAT`: acumula el espectro cruzado PHAT de los tres pares de
  microfonos y evalua la potencia dirigida para cada angulo.

Al pulsar `Play`, la interfaz ejecuta `StartProjectScript.sh`. El script
inicia `jack_das_localizer`, inicia `ReadMicWavs` y conecta sus tres salidas
con las tres entradas del localizador. Tambien conecta
`ReadMicWavs:out_1` con `system:playback_1` y `system:playback_2` para
escuchar el primer canal por ambos lados mientras avanza la localizacion.

El localizador estima automaticamente la cantidad de fuentes. Busca hasta
cuatro maximos locales separados al menos 20 grados y conserva los que
alcanzan al menos `0.55` veces el maximo del espectro espacial. La interfaz
muestra tanto la cantidad detectada como sus angulos.

Una direccion se considera fuente valida despues de aparecer estable en
tres momentos separados al menos 0.5 segundos. Cada momento requiere tres
estimaciones consecutivas dentro de 5 grados. Las observaciones de una
direccion se agrupan con una tolerancia de 20 grados y se conservan durante
todo el audio. Una vez confirmada, la fuente y su angulo permanecen en el
resultado aunque deje de detectarse posteriormente.

La primera estimacion aparece en la ventana 15, despues de 12 ventanas de
calentamiento. A partir de ese momento, la interfaz actualiza el resultado
cada 3 ventanas usando el promedio acumulado de todos los espectros desde
el inicio.

El calculo interno conserva el intervalo angular `[-180, 179]`. En el
resultado final, `-180` se representa como `180` por ser la misma direccion.

La confianza espacial se usa internamente para seleccionar entre DAS base
y DAS con mascara SNR, pero no se transmite ni se muestra en la interfaz.

La estabilidad se evalua sobre las ultimas cuatro estimaciones emitidas.
Se muestra `Estable` cuando la variacion angular circular maxima entre los
conjuntos de direcciones no supera 5 grados. Antes de reunir cuatro
mediciones se muestra el progreso del historial y `0/10` estados estables.
Despues se muestra explicitamente la confirmacion de `1/50` a `50/50`.
Cuando el metodo alcanza estabilidad durante 50 estados consecutivos, la
interfaz conserva y muestra el tiempo de audio transcurrido hasta
confirmarla. Un estado inestable reinicia el contador antes de la
confirmacion; una vez confirmada, el tiempo no cambia.
