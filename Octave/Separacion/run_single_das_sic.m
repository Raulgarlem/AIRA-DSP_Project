% Ejecuta DAS-SIC completo para una sola carpeta de corpus48000.
%
% Deje activa solamente una linea. Para cambiar de ejemplo, comente la
% linea actual y quite el comentario de la carpeta deseada.
%
% Los resultados se guardan en:
%   Octave/Separacion/full_results/das_sic/<carpeta>

% Casos limpios
% result = run_full_das_sic("clean-1source");
result = run_full_das_sic("clean-2source");
% result = run_full_das_sic("clean-2source090");
% result = run_full_das_sic("clean-2source090_2");
% result = run_full_das_sic("clean-3source");
% result = run_full_das_sic("clean-3source090180");
% result = run_full_das_sic("clean-4source");

% Casos con ruido
% result = run_full_das_sic("noisy-1source");
% result = run_full_das_sic("noisy-2source");
% result = run_full_das_sic("noisy-2source090");
% result = run_full_das_sic("noisy-3source");
% result = run_full_das_sic("noisy-3source090180");
% result = run_full_das_sic("noisy-4source");
