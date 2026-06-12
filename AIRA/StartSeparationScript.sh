#!/usr/bin/env bash

set -u

if [[ $# -lt 3 || $# -gt 5 ]]; then
  echo "Uso: $0 CARPETA_GRABACIONES METODO ANGULO_1 [ANGULO_2 ANGULO_3]" >&2
  exit 2
fi

case_directory=$1
method=$2
shift 2
angles=("$@")
source_count=${#angles[@]}
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_directory="${script_directory}/build"
separator_pid=
reader_pid=

cleanup() {
  trap - EXIT INT TERM
  if [[ -n "${reader_pid}" ]] && kill -0 "${reader_pid}" 2>/dev/null; then
    kill "${reader_pid}" 2>/dev/null || true
    wait "${reader_pid}" 2>/dev/null || true
  fi
  if [[ -n "${separator_pid}" ]] &&
     kill -0 "${separator_pid}" 2>/dev/null; then
    kill "${separator_pid}" 2>/dev/null || true
    wait "${separator_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ "${method}" != "das" && "${method}" != "lcmv" ]]; then
  echo "METODO debe ser das o lcmv." >&2
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

if [[ ! -x "${build_directory}/jack_das_separator" ]] ||
   [[ ! -x "${build_directory}/ReadMicWavs" ]]; then
  echo "Compile primero el proyecto en ${build_directory}." >&2
  exit 1
fi

microphone_distance=$(head -n 1 "${case_directory}/info.txt" | tr -d '[:space:]')
"${build_directory}/jack_das_separator" \
  "${method}" "${microphone_distance}" "${source_count}" "${angles[@]}" &
separator_pid=$!

for attempt in {1..50}; do
  if jack_lsp | grep -Fxq "jack_das_separator:input_1" &&
     jack_lsp | grep -Fxq "jack_das_separator:output_1"; then
    break
  fi
  if ! kill -0 "${separator_pid}" 2>/dev/null; then
    echo "El separador ${method^^} no pudo iniciar." >&2
    wait "${separator_pid}" || true
    separator_pid=
    exit 1
  fi
  sleep 0.1
done

"${script_directory}/SwitchSeparationSource.sh" 1

"${build_directory}/ReadMicWavs" \
  jack_das_separator input_ "${case_directory}" 3 &
reader_pid=$!

wait "${reader_pid}"
reader_status=$?
reader_pid=
exit "${reader_status}"
