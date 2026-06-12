#!/usr/bin/env bash

set -u

if [[ $# -ne 4 ]]; then
  echo "Uso: $0 CARPETA_GRABACIONES SOCKET_RESULTADOS NUMERO_FUENTES METODO" >&2
  exit 2
fi

case_directory=$1
result_socket=$2
source_count=$3
method=$4
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

if [[ ! "${source_count}" =~ ^[1-4]$ ]]; then
  echo "NUMERO_FUENTES debe estar entre 1 y 4." >&2
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
  "${result_socket}" "${microphone_distance}" "${source_count}" "${method}" &
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

wait "${reader_pid}"
reader_status=$?
reader_pid=
exit "${reader_status}"
