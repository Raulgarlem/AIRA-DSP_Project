# Interfaz de separacion

La interfaz permite preparar una configuracion de separacion sin ejecutar
todavia los algoritmos.

## Ejecucion

Desde la carpeta `AIRA`:

```bash
./build/separation_gui
```

## Opciones

Modo de operacion:

- `En linea`: habilita la seleccion de localizacion con DAS adaptativo o
  SRP-PHAT.
- `Con DOA conocidos`: utiliza los angulos de `info.txt` y deshabilita la
  seleccion de localizacion.

Metodo de separacion:

- Beamforming DAS.
- LCMV.
- GSC.

La carpeta seleccionada debe contener `info.txt`, `wav_mic1.wav`,
`wav_mic2.wav` y `wav_mic3.wav`.

El boton `Play` solo valida y muestra la configuracion. La implementacion
de los metodos de separacion se agregara posteriormente.
