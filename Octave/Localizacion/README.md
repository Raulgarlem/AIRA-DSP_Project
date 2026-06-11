# Simulacion de localizacion AIRA

Esta etapa implementa solamente estimacion de direccion de llegada (DOA). No
realiza separacion de fuentes ni utiliza JACK en tiempo real.

## Geometria

Se modelan los tres microfonos de AIRA como un triangulo equilatero de lado
`0.18 m`:

```text
mic 1 = ( 0.00,  0.00)
mic 2 = (-0.18,  0.00)
mic 3 = (-0.09, -0.156)
```

La convencion angular coincide con los scripts existentes:

- `0 grados`: direccion `+y`.
- `90 grados`: direccion `+x`.
- Angulos positivos: giro hacia `+x`.
- Barrido completo: `[-180, 179] grados`.

La numeracion y los ejes corresponden a la diapositiva 14 de `05-AIRA`:
microfono 1 arriba-derecha, microfono 2 arriba-izquierda y microfono 3 abajo.
El vector angular apunta desde el centro del arreglo hacia la fuente; por eso
los retardos de llegada usan el signo negativo del producto espacial.

## Metodos comparados

- **Pearson:** para una fuente reproduce el enfoque original con el par de
  microfonos 2-1 y rango `[-90, 90]`; para varias fuentes usa todos los pares.
- **GCC:** sigue la misma seleccion de pares que Pearson, calculando la
  correlacion en frecuencia.
- **GCC-PHAT:** aplica normalizacion PHAT a la correlacion del par de
  microfonos 2-1 y reporta solamente el retardo dominante. Conserva el rango
  `[-90, 90]`. Antes de la FFT aplica una ventana Hann para reducir el
  sangrado producido por discontinuidades en los extremos, como se indica
  en la diapositiva 85 de `06.1-1_DOA`.
- **Multi-GCC-PHAT:** implementa por separado el planteamiento de las
  diapositivas 7 a 28 de `06.2-M_DOA`. Las diapositivas lo describen como un
  "parche" para reutilizar correlacion cruzada con varias fuentes: examina
  una sola correlacion GCC-PHAT del par 2-1 y conserva varios maximos de
  retardo, uno por fuente esperada. No combina evidencias de los tres pares.
  Como utiliza un solo par, los angulos quedan limitados a `[-90, 90]` y
  pueden existir fuentes no separables o ambiguas fuera de ese semiplano.
  La combinacion espacial de los tres pares corresponde a SRP-PHAT.
- **SRP-PHAT:** suma las correlaciones GCC-PHAT de todos los pares para cada
  direccion candidata. Los retardos de todos los angulos se evaluan de forma
  vectorizada y cada par utiliza la misma ventana Hann antes de aplicar PHAT.
- **Delay-and-Sum:** mide la potencia de salida de un beamformer dirigido a
  cada angulo. Todos los beamformers angulares se calculan simultaneamente
  para cada frecuencia usando el barrido completo de `1 grado`.
- **Delay-and-Sum Hierarchical:** reutiliza el mismo beamformer vectorizado,
  pero primero barre cada `5 grados` y refina cada `1 grado` alrededor de los
  candidatos.
- **MUSIC:** calcula un pseudoespectro de subespacios usando ventanas STFT.

Los tres pares de microfonos participan en los metodos de correlacion. Esto
permite estimar 360 grados y evita depender de la ambiguedad de un solo par.

## Ejecucion

Desde Octave:

```octave
cd Octave/Localizacion
results = run_localization_simulation();
```

El experimento ejecuta:

1. Una fuente a `60 grados`.
2. Dos fuentes a `-30` y `90 grados`.

Para cada metodo imprime los angulos estimados y el error angular medio. Las
graficas muestran:

- Linea azul continua: espectro espacial calculado por el metodo.
- Linea verde discontinua: direccion real de la fuente simulada.
- Linea roja punteada: direccion estimada por el metodo.

Cada ventana muestra los angulos reales, los angulos estimados, un error por
cada fuente, el error angular medio y el tiempo empleado por el localizador.
El CSV contiene las columnas `errores_por_fuente_grados` y
`error_medio_grados`.

La preparacion STFT compartida por Delay-and-Sum y MUSIC se mide por separado
y se imprime en la consola. Los tiempos quedan disponibles en:

```octave
results{escenario}.localization_times_s
results{escenario}.preprocessing_time_s
```

Cada grafica se abre en una ventana independiente. Al terminar los calculos,
el programa espera a que se presione Enter para evitar que Octave cierre las
ventanas automaticamente. Para desactivar esa espera, cambie:

```octave
config.wait_for_user = false;
```

## Parametros

Los parametros editables estan al inicio de
`run_localization_simulation.m`:

- Frecuencia de muestreo y duracion.
- Distancia entre microfonos.
- SNR.
- Resolucion angular.
- Banda de frecuencias.
- Longitud y salto de la STFT.
- Separacion minima entre picos.

## Siguiente validacion

Para evaluar automaticamente todas las carpetas de `corpus44100` y
`corpus48000`, ejecute:

```octave
cd Octave/Localizacion
results = run_localization_corpus();
```

El lote:

- Lee los tres archivos `wav_micX.wav` de cada carpeta.
- Lee la distancia y los angulos reales desde `info.txt`.
- Analiza el segundo central de cada grabacion para acelerar la evaluacion y
  evitar posibles silencios de inicio.
- Ejecuta Pearson, GCC, GCC-PHAT, Multi-GCC-PHAT, SRP-PHAT, Delay-and-Sum,
  Delay-and-Sum Hierarchical y MUSIC.
- Omite MUSIC cuando hay tres o mas fuentes, porque MUSIC requiere menos
  fuentes que microfonos.
- Guarda angulos, error y tiempo en `corpus_localization_results.csv`.
- Guarda las graficas sin mostrarlas dentro de la subcarpeta
  `localization_results` de cada caso.

Cada subcarpeta de resultados contiene:

```text
signals.png
pearson.png
gcc.png
gcc_phat.png
multi_gcc_phat.png
srp_phat.png
delay_and_sum.png
delay_and_sum_hierarchical.png
music.png
```

El modo de lote no abre ventanas. Para cambiar velocidad, precision o
generacion de imagenes edite los parametros al inicio de
`run_corpus_batch()`:

- `segment_duration_s`: duracion analizada por carpeta.
- `angle_grid_deg`: resolucion del barrido angular.
- `hierarchical_search`: activa la busqueda gruesa y refinada para SRP-PHAT.
- `coarse_step_deg`: paso del barrido global, por defecto `5 grados`.
- `refine_step_deg`: paso del refinamiento local, por defecto `1 grado`.
- `refine_radius_deg`: radio refinado alrededor de cada candidato.
- `music_frequency_stride`: cantidad de frecuencias evaluadas por MUSIC.
- `save_plots`: activa o desactiva la generacion de PNG.
- `plot_resolution_dpi`: resolucion de las imagenes.

## Ejecutar un solo corpus

Para procesar solamente uno de los dos corpus:

```octave
results = run_localization_single_corpus("corpus44100");
```

o:

```octave
results = run_localization_single_corpus("corpus48000");
```

## Validacion WOLA por bloques

`run_wola_localization_corpus.m` valida los cuatro localizadores elegidos
consumiendo los WAV de `corpus48000` en bloques, como preparacion para la
version JACK en tiempo real:

- Frecuencia de muestreo: `48000 Hz`.
- Ventana Hann periodica: `1024` muestras.
- Salto de entrada: `512` muestras.
- Solapamiento: `50 %`.
- Metodos: Delay-and-Sum, Delay-and-Sum Hierarchical, SRP-PHAT y
  Multi-GCC-PHAT.

Por defecto procesa los casos limpios y ruidosos de dos y tres fuentes:

```octave
cd Octave/Localizacion
results = run_wola_localization_corpus();
```

Tambien se puede indicar cualquier conjunto de carpetas de `corpus48000`:

```octave
results = run_wola_localization_corpus( ...
    {"clean-2source", "clean-3source", "noisy-3source"});
```

El programa acumula matrices espectrales y espectros PHAT al recibir cada
bloque; no vuelve a procesar la senal completa al localizar. Los resultados
se guardan en `wola_corpus48000_localization_results.csv`.

## Delay-and-Sum con Dynamic Programming

`run_wola_das_dp_corpus.m` genera un espectro espacial por cada ventana WOLA
y aplica seguimiento Viterbi para conectar los angulos mas probables a lo
largo del tiempo. Compara Delay-and-Sum completo y jerarquico, con y sin
Dynamic Programming.

```octave
cd Octave/Localizacion
results = run_wola_das_dp_corpus();
```

Por defecto procesa `clean-3source` y `noisy-3source`. Tambien acepta una
lista explicita:

```octave
results = run_wola_das_dp_corpus( ...
    {"clean-2source", "noisy-3source"});
```

Las trayectorias angulares por ventana quedan disponibles en
`results(n).tracks_deg`. Los tiempos y errores se guardan en
`wola_das_dp_corpus48000_results.csv`.

## Ablacion de mascaras de voz

`run_wola_das_mask_ablation.m` compara ocho variantes para separar el efecto
del filtrado espectral del seguimiento temporal:

- DAS de `300-5000 Hz`, con y sin DP.
- DAS limitado a voz `300-4000 Hz`, con y sin DP.
- DAS con mascara SNR causal, con y sin DP.
- DAS con mascara SNR y coherencia espacial, con y sin DP.

La estimacion de ruido usa minimos temporales por frecuencia y no consulta
los archivos `pristine`. Por defecto se ejecutan los cuatro casos de tres
fuentes:

```octave
cd Octave/Localizacion
results = run_wola_das_mask_ablation();
```

El CSV `wola_das_mask_ablation_results.csv` incluye error, bins activos,
pesos medios y tiempos para facilitar el analisis de ablacion.

## Selector adaptativo DAS/SNR

`run_wola_das_adaptive_mask.m` utiliza siempre la banda `300-4000 Hz`.
Calcula DAS base y DAS ponderado dentro del mismo bucle de frecuencias, y
actualiza cada tres ventanas la decision de usar o no la mascara SNR.

La mascara debe superar umbrales de bins activos, bins efectivos, peso medio
y cobertura de subbandas. Despues se compara la confianza espacial de los
dos espectros. Se requieren dos decisiones consecutivas para cambiar de
modo.

```octave
cd Octave/Localizacion
results = run_wola_das_adaptive_mask();
```

El CSV `wola_das_adaptive_mask_results.csv` registra precision, porcentaje
de uso de mascara, conmutaciones y coste por ventana.

Tambien puede abrir y ejecutar directamente uno de estos scripts:

```text
run_corpus44100.m
run_corpus48000.m
```

El CSV se guarda por separado como:

```text
corpus44100_localization_results.csv
corpus48000_localization_results.csv
```

Para ejecutar solamente una carpeta concreta dentro de un corpus:

```octave
results = run_localization_single_corpus( ...
    "corpus48000", "clean-2source090");
```

Otros nombres validos incluyen `clean-1source`, `clean-3source`,
`noisy-1source` y `noisy-4source`. El nombre debe coincidir exactamente con
la carpeta. El CSV resultante incluye el corpus y el caso en su nombre.

Tambien puede abrir `run_single_example.m`. El archivo contiene una linea por
cada carpeta de ambos corpus; solo la primera esta activa y las demas estan
comentadas. Para cambiar de caso, comente la linea actual y descomente la que
desee ejecutar.

## Separacion guiada por DOA

El primer puente entre localizacion y separacion esta en:

```octave
cd Octave/Separacion
results = run_wola_source_separation();
```

Compara dos rutas con la misma geometria AIRA y WOLA de `1024/512`:

- DAS con selector adaptativo base/SNR para localizar, seguido de un
  beamformer Delay-and-Sum por fuente.
- SRP-PHAT para localizar, seguido de MVDR con covarianza de interferencia
  multitrama, mascaras espaciales suaves y carga diagonal.

Por defecto procesa `clean-2source`. Se pueden indicar otros casos:

```octave
results = run_wola_source_separation( ...
    {"clean-2source", "noisy-2source", "clean-3source"});
```

Las salidas WAV quedan en `Octave/Separacion/results/<caso>`. El CSV
`Octave/Separacion/wola_source_separation_results.csv` registra error DOA,
SI-SDR, mejora SI-SDR, correlacion y tiempos. Con tres microfonos, MVDR tiene
capacidad espacial limitada cuando hay tres o mas fuentes simultaneas; esos
casos deben interpretarse como una prueba de estres, no como una condicion
en la que se puedan imponer nulos independientes para todos los interferentes.

## Beamforming guiado por DAS adaptativo

Para comparar las cuatro familias de la diapositiva 49 de
`07.2-Beamforming` usando exclusivamente las direcciones del localizador DAS
adaptativo:

```octave
cd Octave/Separacion
results = run_das_guided_beamforming();
```

El programa llama directamente a `run_wola_das_adaptive_mask` y compara:

- Delay-and-Sum como referencia.
- MVDR.
- LCMV, usando las otras DOAs como restricciones de respuesta nula.
- GSC con LMS de paso fijo.
- GSC con paso dinamico.
- Frequency Masking binario basado en coherencia de fase.

Por defecto se ejecuta `clean-3source`, donde el localizador DAS adaptativo
ha dado sus mejores resultados. Los WAV quedan en
`Octave/Separacion/results/<caso>_das_guided` y las metricas en
`Octave/Separacion/das_guided_beamforming_results.csv`.

LCMV puede imponer como maximo tantas restricciones independientes como
microfonos disponibles. Con los tres microfonos de AIRA, tres fuentes usan
todos los grados de libertad. La mascara de fase extiende a tres microfonos
el ejemplo de dos canales de las diapositivas 121 a 140.

En las primeras pruebas, DAS fue el unico metodo que mejoro SI-SDR para
todas las fuentes tanto en `clean-2source` como en `clean-3source`. MVDR y
LCMV mostraron la sensibilidad a errores de direccion descrita en las
diapositivas 68 a 70 y 82 a 84. GSC dinamico mejoro algunas fuentes, pero
todavia requiere calibrar sus constantes y tiempo de adaptacion. La mascara
binaria de fase produjo los artefactos esperados de las diapositivas 139 y
140, por lo que se conserva como comparacion y no como metodo recomendado.

DAS maximiza la suma coherente de la direccion objetivo, pero no impone un
nulo en las otras direcciones. LCMV si puede anular el camino directo de una
DOA interferente; sin embargo, las reflexiones de esa misma fuente llegan
desde otras direcciones y permanecen en una grabacion reverberante. Por eso
conocer las DOAs es suficiente para mejorar la relacion espacial, pero no
garantiza por si solo una separacion completa de las voces.

## Interfaz de reproduccion por fuente

La demostracion interactiva de separacion DAS se inicia desde Octave con
interfaz grafica:

```octave
cd Octave/Separacion
run_das_realtime_gui("clean-2source");
```

El boton `Play` ejecuta primero una localizacion DAS adaptativa corta y
despues procesa el WAV causalmente mediante WOLA. `Pausa` detiene la
reproduccion, `Stop` termina el recorrido y el selector permite escuchar
cualquiera de las fuentes estimadas. El cambio de fuente se aplica al
siguiente bloque de audio, de aproximadamente `85 ms`.

La reproduccion y el procesamiento se solapan con `audioplayer`, pero esta
interfaz sigue siendo una demostracion sobre archivos WAV. No captura el
arreglo de microfonos en vivo ni sustituye la futura integracion con JACK.

Para elegir una carpeta sin escribir su nombre en la consola, abra:

```text
Octave/Separacion/run_single_separation_gui.m
```

El archivo contiene una llamada por cada carpeta de `corpus48000`. Deje
activa solamente una linea y mantenga las demas comentadas. Al ejecutar el
script se abre directamente la interfaz para la carpeta seleccionada.

## Guardar separacion completa

Para procesar todos los segundos de una grabacion y guardar un WAV final por
fuente:

```octave
cd Octave/Separacion
result = run_full_das_separation("clean-2source");
```

El localizador DAS adaptativo conserva su analisis de un segundo para
estimar las DOAs, pero el beamformer WOLA procesa todas las muestras de los
tres WAV. Las salidas se guardan en:

```text
Octave/Separacion/full_results/<caso>/source1.wav
Octave/Separacion/full_results/<caso>/source2.wav
Octave/Separacion/full_results/<caso>/separation_info.txt
```

Para elegir facilmente una sola carpeta, abra y ejecute:

```text
Octave/Separacion/run_single_full_separation.m
```

Deje activa una sola llamada y mantenga comentadas las demas, igual que en
los selectores de localizacion y de la interfaz grafica.

## DAS directo de las diapositivas 1 a 48

La variante que sigue literalmente el desarrollo inicial de
`07.2-Beamforming` aplica una sola FFT a la grabacion completa:

```octave
cd Octave/Separacion
result = run_full_das_slides_1_48("clean-2source");
```

Por cada DOA y frecuencia calcula el direction/steering vector, aplica la
Hermitiana y divide la suma entre los tres microfonos:

```text
S_hat(f) = W(f)^H X(f) / M
```

Finalmente aplica la IFFT y conserva la duracion completa del WAV. Se agrega
relleno antes de la FFT para evitar que los desfases circulares contaminen
los extremos. Los resultados se guardan separados de la variante WOLA:

```text
Octave/Separacion/full_results/slides_1_48/<caso>/source1.wav
Octave/Separacion/full_results/slides_1_48/<caso>/source2.wav
```

La salida alineada recibe por defecto una ganancia de `+6.0206 dB`, que
equivale a duplicar su amplitud. El parámetro editable es
`config.output_gain_db`; antes de guardar se limita la señal únicamente si
la ganancia causaría clipping.

La versión actual calcula un único DAS y guarda además una copia normalizada
a pico `0.95` y otra a un RMS objetivo configurable, `-20 dBFS` por defecto.
La normalización modifica el volumen y evita clipping, pero no cambia la
relación entre la fuente deseada y la interferencia.

También se prueba una normalización RMS común antes del beamforming. Se usa
el mismo factor para los tres micrófonos, por lo que no se alteran sus
diferencias relativas ni sus fases. Debido a la linealidad de DAS, esta
salida debe ser únicamente una versión escalada del DAS original; sirve para
controlar nivel, pero no para reducir la fuente interferente.

El selector con una sola carpeta activa es:

```text
Octave/Separacion/run_single_das_slides_1_48.m
```

## DAS con cancelacion sucesiva

La prueba SIC calcula primero la fuente DAS mas fuerte, reconstruye su
direction vector en los tres microfonos y resta parcialmente esa imagen
antes de calcular la siguiente fuente:

```octave
cd Octave/Separacion
result = run_full_das_sic("clean-2source");
```

El factor inicial de cancelacion es `0.70`. Puede indicarse como segundo
argumento, por ejemplo `run_full_das_sic("clean-2source", 0.50)`. Una resta
parcial reduce la propagacion de errores hacia las fuentes calculadas
despues. Los WAV completos, el residuo de cada microfono y el orden de
procesamiento quedan en:

```text
Octave/Separacion/full_results/das_sic/<caso>/
```

El selector de una carpeta es:

```text
Octave/Separacion/run_single_das_sic.m
```

En `clean-2source`, con cancelacion de `0.70`, la primera fuente permanece
igual y la segunda mejoro aproximadamente `1.92 dB` de SI-SDR respecto al
DAS sin cancelacion.
### Iterative DAS source cancellation

`Octave/Separacion/run_single_das_iterative_sic.m` runs full-recording DAS
separation followed by three interference-cancellation iterations for every
source. In each iteration, a source is recalculated from the original
microphone signals after subtracting the reconstructed images of all other
sources.

The outputs are saved in:

`Octave/Separacion/full_results/das_iterative_sic/<case>/`

`iteration_0_*` is the initial DAS result, `iteration_1_*` through
`iteration_3_*` allow direct listening comparisons, and `source*_final.wav`
contains the last iteration. `iteration_metrics.csv` reports SI-SDR for each
iteration when pristine references are available.

## DAS con mascara tiempo-frecuencia suave

`Octave/Separacion/run_single_das_soft_mask.m` localiza las fuentes con DAS
adaptativo y forma un haz DAS por cada DOA. Después compara la potencia de
los haces en cada bin tiempo-frecuencia y aplica una mascara suave:

```text
M_s = piso + (1 - piso) * P_s^p / sum(P_j^p)
```

La potencia se suaviza entre frecuencias y ventanas para reducir artefactos.
El selector permite modificar `mask_exponent` y `mask_floor`. Los audios DAS
sin mascara, los audios enmascarados y las metricas se guardan en:

```text
Octave/Separacion/full_results/das_soft_mask/<caso>/
```

## Suma de tres DAS

`Octave/Separacion/run_single_das_triple_sum.m` calcula tres haces DAS por
fuente y guarda tanto las pasadas individuales como su promedio coherente.
Repetir exactamente el mismo DAS tres veces solo multiplica la amplitud, por
lo que el selector usa por defecto offsets angulares `[-2, 0, 2]` grados
alrededor de cada DOA estimada. Los resultados se guardan en:

```text
Octave/Separacion/full_results/das_triple_sum/<caso>/
```
