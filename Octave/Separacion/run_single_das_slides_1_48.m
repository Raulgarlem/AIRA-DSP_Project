% Ejecuta DAS completo segun las diapositivas 1 a 48 para un solo caso.
%
% Deje activa solamente una linea. Para cambiar de ejemplo, comente la
% linea actual y quite el comentario de la carpeta deseada.
%
% Los resultados se guardan en:
%   Octave/Separacion/full_results/slides_1_48/<carpeta>

% Nivel RMS solicitado después de calcular un único DAS.
target_rms_dbfs = -20;

% Casos limpios
% result = run_full_das_slides_1_48("clean-1source", target_rms_dbfs);
result = run_full_das_slides_1_48("clean-2source", target_rms_dbfs);
% result = run_full_das_slides_1_48("clean-2source090", target_rms_dbfs);
% result = run_full_das_slides_1_48("clean-2source090_2", target_rms_dbfs);
% result = run_full_das_slides_1_48("clean-3source", target_rms_dbfs);
% result = run_full_das_slides_1_48("clean-3source090180", target_rms_dbfs);
% result = run_full_das_slides_1_48("clean-4source", target_rms_dbfs);

% Casos con ruido
% result = run_full_das_slides_1_48("noisy-1source", target_rms_dbfs);
% result = run_full_das_slides_1_48("noisy-2source", target_rms_dbfs);
% result = run_full_das_slides_1_48("noisy-2source090", target_rms_dbfs);
% result = run_full_das_slides_1_48("noisy-3source", target_rms_dbfs);
% result = run_full_das_slides_1_48("noisy-3source090180", target_rms_dbfs);
% result = run_full_das_slides_1_48("noisy-4source", target_rms_dbfs);
