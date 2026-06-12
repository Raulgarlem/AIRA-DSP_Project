# Evaluacion de separacion DAS y LCMV

Fecha de evaluacion: 12 de junio de 2026.

## Metodologia

Se evaluaron los metodos `DAS WOLA` y `LCMV WOLA` con los DOA de
`info.txt` en cuatro casos del corpus de 48 kHz:

- `clean-2source`
- `noisy-2source`
- `clean-3source`
- `noisy-3source`

Cada salida `output_N` se comparo con `pristine_channelN.wav`. Como linea
base se uso `wav_mic1.wav`, que representa la mezcla sin separar recibida
por un microfono.

La metrica principal es mejora de SI-SDR:

```text
SI-SDRi = SI-SDR(salida, fuente limpia)
          - SI-SDR(wav_mic1, fuente limpia)
```

- Un `SI-SDRi` positivo significa que la separacion mejoro la fuente.
- Un `SI-SDRi` negativo significa que la salida fue peor que la mezcla.
- Las senales se alinearon por correlacion cruzada con un margen de
  +/-2 segundos para compensar los retardos de propagacion, JACK y WOLA.
- Se descartaron 250 ms en cada extremo despues de la alineacion.

Los SI-SDR absolutos son negativos. Esto es consistente con referencias
`pristine_channelN.wav` sin la misma respuesta acustica y filtrado que
aparecen en `wav_micN.wav`. Por ello, el resultado relevante para comparar
los metodos es `SI-SDRi`, no solamente el SI-SDR absoluto.

## Dos fuentes limpias

| Metodo | Fuente | Entrada dB | Salida dB | Mejora dB |
|---|---:|---:|---:|---:|
| DAS | 1 | -15.25 | -14.39 | +0.86 |
| DAS | 2 | -21.75 | -20.35 | +1.40 |
| LCMV | 1 | -15.25 | -14.06 | +1.19 |
| LCMV | 2 | -21.75 | -19.75 | +2.00 |

Promedio: DAS `+1.13 dB`; LCMV `+1.60 dB`.

## Dos fuentes con ruido

| Metodo | Fuente | Entrada dB | Salida dB | Mejora dB |
|---|---:|---:|---:|---:|
| DAS | 1 | -25.05 | -24.48 | +0.57 |
| DAS | 2 | -15.21 | -15.44 | **-0.23** |
| LCMV | 1 | -25.05 | -23.53 | +1.52 |
| LCMV | 2 | -15.21 | -15.35 | **-0.13** |

Promedio: DAS `+0.17 dB`; LCMV `+0.69 dB`.

Este fue el unico caso con disminucion: la fuente 2 perdio `0.23 dB` con
DAS y `0.13 dB` con LCMV.

## Tres fuentes limpias

| Metodo | Fuente | Entrada dB | Salida dB | Mejora dB |
|---|---:|---:|---:|---:|
| DAS | 1 | -16.41 | -15.01 | +1.40 |
| DAS | 2 | -18.90 | -18.27 | +0.63 |
| DAS | 3 | -17.98 | -15.11 | +2.87 |
| LCMV | 1 | -16.41 | -14.32 | +2.09 |
| LCMV | 2 | -18.90 | -17.46 | +1.45 |
| LCMV | 3 | -17.98 | -14.28 | +3.70 |

Promedio: DAS `+1.63 dB`; LCMV `+2.41 dB`.

Este fue el mejor caso para LCMV. La fuente 3 obtuvo la mayor mejora
individual de toda la evaluacion: `+3.70 dB`.

## Tres fuentes con ruido

| Metodo | Fuente | Entrada dB | Salida dB | Mejora dB |
|---|---:|---:|---:|---:|
| DAS | 1 | -22.26 | -20.79 | +1.47 |
| DAS | 2 | -22.46 | -21.85 | +0.60 |
| DAS | 3 | -25.17 | -24.56 | +0.61 |
| LCMV | 1 | -22.26 | -21.08 | +1.19 |
| LCMV | 2 | -22.46 | -22.30 | +0.15 |
| LCMV | 3 | -25.17 | -24.45 | +0.73 |

Promedio: DAS `+0.90 dB`; LCMV `+0.69 dB`.

En este caso DAS supero a LCMV por `0.21 dB` en el promedio.

## Resumen

| Caso | DAS promedio | LCMV promedio | Mejor promedio |
|---|---:|---:|---|
| Dos fuentes limpias | +1.13 dB | +1.60 dB | LCMV |
| Dos fuentes con ruido | +0.17 dB | +0.69 dB | LCMV |
| Tres fuentes limpias | +1.63 dB | +2.41 dB | LCMV |
| Tres fuentes con ruido | +0.90 dB | +0.69 dB | DAS |
| Todas las fuentes | +1.02 dB | +1.39 dB | LCMV |

LCMV obtuvo una mejora global media `0.37 dB` mayor que DAS. La ventaja
no fue uniforme: LCMV fue mejor en los casos limpios y en dos fuentes con
ruido, mientras que DAS fue ligeramente mejor con tres fuentes y ruido.

## Observaciones

La matriz de comparaciones cruzadas indico fuga importante en algunos
casos:

- En dos fuentes limpias, `output_2` se parecio mas a la fuente 1 que a
  la fuente 2 con ambos metodos.
- En dos fuentes con ruido, `output_1` se parecio mas a la fuente 2.
- En tres fuentes con ruido, `output_3` se parecio mas a la fuente 1.

Por tanto, una mejora positiva no implica aislamiento completo. Los
resultados muestran atenuacion parcial de interferencia, pero todavia hay
mezcla entre algunas salidas. La correspondencia de
`pristine_channelN.wav` con el angulo N de `info.txt` se asumio por el
orden de los archivos y debe confirmarse en el generador del corpus.
