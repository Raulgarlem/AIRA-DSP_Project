# Interfaz de separacion

La interfaz ejecuta separacion DAS o LCMV WOLA en linea usando los DOA
reales guardados en `info.txt`.

## Ejecucion

Desde la carpeta `AIRA`:

```bash
./build/separation_gui
```

La carpeta seleccionada debe contener `info.txt`, `wav_mic1.wav`,
`wav_mic2.wav` y `wav_mic3.wav`.

Se admiten entre una y tres fuentes. El cliente JACK
`jack_das_separator` crea tres entradas y una salida `output_N` por fuente;
el nombre se conserva porque DAS fue el primer metodo implementado.
El selector permite elegir:

- `DAS WOLA`: aplica los pesos de delay-and-sum.
- `LCMV WOLA`: estima una covarianza espectral suavizada, mantiene ganancia
  unitaria hacia la fuente elegida e impone nulos hacia los demas DOA. Usa
  carga diagonal, suavizado temporal de pesos y cae a DAS durante el
  calentamiento, fuera de 300-4000 Hz o cuando una matriz no puede
  invertirse de forma estable. Los pesos excesivamente grandes tambien se
  rechazan para reducir artefactos metalicos.

Las operaciones matriciales LCMV usan Eigen 3.4 con matrices complejas
fijas de 3x3. Los sistemas se resuelven mediante `LDLT`; no se forman
inversas explicitas ni se realizan asignaciones dinamicas de Eigen durante
el procesamiento. Para cada bin se factoriza la covarianza una sola vez y
se calcula conjuntamente la matriz de pesos de todas las fuentes.

Ambos metodos usan ventana Hann de 1024 muestras, salto de 512 muestras y
overlap-add, siguiendo las implementaciones de Octave.

Los radio buttons `Source 1`, `Source 2` y `Source 3` ejecutan
`SwitchSeparationSource.sh`. El script desconecta la salida monitorizada
anterior y conecta la seleccionada a `system:playback_1` y
`system:playback_2`.
