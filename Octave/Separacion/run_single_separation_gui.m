% Ejecuta la interfaz de separacion para una sola carpeta de corpus48000.
%
% Deje activa solamente una linea. Para cambiar de ejemplo, comente la
% linea actual y quite el comentario de la carpeta deseada.
%
% La interfaz permite iniciar la separacion con Play y cambiar la fuente
% escuchada durante la reproduccion.

% Casos limpios
% run_das_realtime_gui("clean-1source");
run_das_realtime_gui("clean-2source");
% run_das_realtime_gui("clean-2source090");
% run_das_realtime_gui("clean-2source090_2");
% run_das_realtime_gui("clean-3source");
% run_das_realtime_gui("clean-3source090180");
% run_das_realtime_gui("clean-4source");

% Casos con ruido
% run_das_realtime_gui("noisy-1source");
% run_das_realtime_gui("noisy-2source");
% run_das_realtime_gui("noisy-2source090");
% run_das_realtime_gui("noisy-3source");
% run_das_realtime_gui("noisy-3source090180");
% run_das_realtime_gui("noisy-4source");
