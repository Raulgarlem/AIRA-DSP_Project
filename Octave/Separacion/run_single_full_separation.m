% Guarda la separacion completa de una sola carpeta de corpus48000.
%
% Deje activa solamente una linea. Para cambiar de ejemplo, comente la
% linea actual y quite el comentario de la carpeta deseada.
%
% Los WAV completos se guardan en:
%   Octave/Separacion/full_results/<carpeta>

% Casos limpios
% result = run_full_das_separation("clean-1source");
result = run_full_das_separation("clean-2source");
% result = run_full_das_separation("clean-2source090");
% result = run_full_das_separation("clean-2source090_2");
% result = run_full_das_separation("clean-3source");
% result = run_full_das_separation("clean-3source090180");
% result = run_full_das_separation("clean-4source");

% Casos con ruido
% result = run_full_das_separation("noisy-1source");
% result = run_full_das_separation("noisy-2source");
% result = run_full_das_separation("noisy-2source090");
% result = run_full_das_separation("noisy-3source");
% result = run_full_das_separation("noisy-3source090180");
% result = run_full_das_separation("noisy-4source");
