clear;
clc;

% Deja sin comentar solamente el caso que quieres procesar.
case_name = "clean-2source";
% case_name = "clean-3source";
% case_name = "clean-4source";
% case_name = "noisy-2source";
% case_name = "noisy-3source";
% case_name = "noisy-4source";

% Mayor exponente: mas separacion, pero mayor riesgo de artefactos.
mask_exponent = 1.5;

% Atenuacion maxima de una fuente no dominante:
% 0.05 equivale aproximadamente a -26 dB en amplitud.
mask_floor = 0.05;

result = run_full_das_soft_mask( ...
    case_name, mask_exponent, mask_floor);
