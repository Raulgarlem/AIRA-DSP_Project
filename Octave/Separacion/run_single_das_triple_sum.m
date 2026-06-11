clear;
clc;

% Deja sin comentar solamente el caso que quieres procesar.
case_name = "clean-2source";
% case_name = "clean-3source";
% case_name = "clean-4source";
% case_name = "noisy-2source";
% case_name = "noisy-3source";
% case_name = "noisy-4source";

% Tres apuntamientos alrededor de cada DOA estimada.
% Usar [0, 0, 0] demuestra que repetir el mismo DAS solo cambia amplitud.
angle_offsets_deg = [-2, 0, 2];

result = run_full_das_triple_sum(case_name, angle_offsets_deg);
