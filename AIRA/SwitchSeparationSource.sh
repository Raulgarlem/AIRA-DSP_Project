#!/usr/bin/env bash

set -u

if [[ $# -ne 1 || ! $1 =~ ^[1-3]$ ]]; then
  echo "Uso: $0 NUMERO_FUENTE" >&2
  exit 2
fi

selected_port="jack_das_separator:output_$1"

for source in 1 2 3; do
  port="jack_das_separator:output_${source}"
  jack_disconnect "${port}" system:playback_1 2>/dev/null || true
  jack_disconnect "${port}" system:playback_2 2>/dev/null || true
done

if ! jack_lsp | grep -Fxq "${selected_port}"; then
  echo "No existe la salida ${selected_port}." >&2
  exit 1
fi

jack_connect "${selected_port}" system:playback_1
jack_connect "${selected_port}" system:playback_2
