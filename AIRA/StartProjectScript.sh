#!/usr/bin/env bash

set -u

if [[ $# -ne 5 ]]; then
  echo "Uso: $0 CARPETA_GRABACIONES SOCKET_RESULTADOS MAX_FUENTES UMBRAL_RELATIVO METODO" >&2
  exit 2
fi

case_directory=$1
result_socket=$2
max_sources=$3
relative_peak_threshold=$4
method=$5
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_directory="${script_directory}/build"
localizer_pid=
reader_pid=

cleanup() {
  trap - EXIT INT TERM
  if [[ -n "${reader_pid}" ]] && kill -0 "${reader_pid}" 2>/dev/null; then
    kill "${reader_pid}" 2>/dev/null || true
    wait "${reader_pid}" 2>/dev/null || true
  fi
  if [[ -n "${localizer_pid}" ]] && kill -0 "${localizer_pid}" 2>/dev/null; then
    kill "${localizer_pid}" 2>/dev/null || true
    wait "${localizer_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ ! "${max_sources}" =~ ^[1-4]$ ]]; then
  echo "MAX_FUENTES debe estar entre 1 y 4." >&2
  exit 2
fi

if ! awk -v threshold="${relative_peak_threshold}" \
  'BEGIN { exit !(threshold > 0.0 && threshold <= 1.0) }'; then
  echo "UMBRAL_RELATIVO debe estar en el intervalo (0, 1]." >&2
  exit 2
fi

if [[ "${method}" != "adaptive" && "${method}" != "srp-phat" ]]; then
  echo "METODO debe ser adaptive o srp-phat." >&2
  exit 2
fi

if ! jack_lsp >/dev/null 2>&1; then
  echo "JACK no esta iniciado o no es accesible." >&2
  exit 1
fi

for playback_port in system:playback_1 system:playback_2; do
  if ! jack_lsp | grep -Fxq "${playback_port}"; then
    echo "No existe el puerto JACK ${playback_port}." >&2
    exit 1
  fi
done

for required_file in info.txt wav_mic1.wav wav_mic2.wav wav_mic3.wav; do
  if [[ ! -f "${case_directory}/${required_file}" ]]; then
    echo "Falta ${case_directory}/${required_file}" >&2
    exit 1
  fi
done

if [[ ! -x "${build_directory}/jack_das_localizer" ]] ||
   [[ ! -x "${build_directory}/ReadMicWavs" ]]; then
  echo "Compile primero el proyecto en ${build_directory}." >&2
  exit 1
fi

microphone_distance=$(head -n 1 "${case_directory}/info.txt" | tr -d '[:space:]')
if [[ -z "${microphone_distance}" ]]; then
  echo "No se pudo leer la distancia desde info.txt." >&2
  exit 1
fi

"${build_directory}/jack_das_localizer" \
  "${result_socket}" "${microphone_distance}" "${max_sources}" \
  "${relative_peak_threshold}" "${method}" &
localizer_pid=$!
sleep 1

if ! kill -0 "${localizer_pid}" 2>/dev/null; then
  echo "El localizador DAS no pudo iniciar." >&2
  wait "${localizer_pid}" || true
  exit 1
fi

"${build_directory}/ReadMicWavs" \
  jack_das_localizer input_ "${case_directory}" 3 &
reader_pid=$!

for attempt in {1..50}; do
  if jack_lsp | grep -Fxq "ReadMicWavs:out_1"; then
    break
  fi
  if ! kill -0 "${reader_pid}" 2>/dev/null; then
    echo "ReadMicWavs termino antes de publicar sus salidas JACK." >&2
    wait "${reader_pid}" || true
    reader_pid=
    exit 1
  fi
  sleep 0.1
done

if ! jack_lsp | grep -Fxq "ReadMicWavs:out_1"; then
  echo "No aparecieron las salidas JACK de ReadMicWavs." >&2
  exit 1
fi

if ! jack_connect "ReadMicWavs:out_1" "system:playback_1" ||
   ! jack_connect "ReadMicWavs:out_1" "system:playback_2"; then
  echo "No se pudo conectar el audio a las salidas de reproduccion JACK." >&2
  exit 1
fi
echo "Monitor JACK activo: out_1 -> playback_1 y playback_2."

wait "${reader_pid}"
reader_status=$?
reader_pid=
exit "${reader_status}"
