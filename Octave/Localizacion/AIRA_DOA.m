clear all; close all; clc;

pkg load signal;

% =========================
% Funciones Correlación
% =========================
function [delay_samp, cc, lags] = gcc(sig, refsig)
    n = length(sig) + length(refsig);

    SIG = fft(sig, n);
    REF = fft(refsig, n);

    R = SIG .* conj(REF);


    cc = real(ifft(R));
    cc = fftshift(cc);

    max_shift = floor(n/2);
    lags = -max_shift:(max_shift-1);

    [~, idx] = max(abs(cc));
    delay_samp = lags(idx);
endfunction

function [delay_samp, cc, lags] = gcc_phat(sig, refsig)
    n = length(sig) + length(refsig);

    SIG = fft(sig, n);
    REF = fft(refsig, n);

    R = SIG .* conj(REF);
    R = R ./ (abs(R) + eps);

    cc = real(ifft(R));
    cc = fftshift(cc);

    max_shift = floor(n/2);
    lags = -max_shift:(max_shift-1);

    [~, idx] = max(abs(cc));
    delay_samp = lags(idx);
endfunction

function [delay_samp, cc, lags] = pearson_corr(sig, refsig)

    % Quitar DC / media
    sig = sig - mean(sig);
    refsig = refsig - mean(refsig);

    % Correlación cruzada normalizada tipo Pearson
    [cc, lags] = xcorr(sig, refsig, "coeff");

    % Buscar pico máximo
    [~, idx] = max(abs(cc));

    % Delay estimado en muestras
    delay_samp = lags(idx);
endfunction

% =========================
% Cargar señales AIRA
% =========================
[x1, fs] = audioread("corpus48000/clean-1source/wav_mic1.wav");
[x2, fs] = audioread("corpus48000/clean-1source/wav_mic2.wav");
[x3, fs] = audioread("corpus48000/clean-1source/wav_mic3.wav");

N = 48000; % 1 segundo

x1 = x1(1:N);
x2 = x2(1:N);
x3 = x3(1:N);

% =========================
% Verificando Longitud
% =========================
length(x1)
length(x2)
length(x3)


% =========================
% Graficando señales originales
% =========================
figure;
plot(x1);
hold on;
plot(x2);
plot(x3);

legend("Mic1","Mic2","Mic3");
title("Señales reales AIRA");


% =========================
% Aplicando Pearson
% =========================
[d21, cc21, lags21] = pearson_corr(x2, x1);
[d31, cc31, lags31] = pearson_corr(x3, x1);

printf("Pearson delay mic2-mic1: %d muestras\n", d21);
printf("Pearson delay mic3-mic1: %d muestras\n", d31);


% =========================
% Aplicando GCC
% =========================
[d21g, cc21g, lags21g] = gcc(x2, x1);
[d31g, cc31g, lags31g] = gcc(x3, x1);

printf("GCC delay mic2-mic1: %d muestras\n", d21g);
printf("GCC delay mic3-mic1: %d muestras\n", d31g);


% =========================
% Aplicando GCC-PHAT
% =========================
[d21p, cc21p, lags21p] = gcc_phat(x2, x1);
[d31p, cc31p, lags31p] = gcc_phat(x3, x1);

printf("PHAT delay mic2-mic1: %d muestras\n", d21p);
printf("PHAT delay mic3-mic1: %d muestras\n", d31p);


% =========================
% Graficando Comparaciones
% =========================
figure;
plot(lags21, cc21);
title("Pearson Mic2 vs Mic1");

figure;
plot(lags21g, cc21g);
title("GCC Mic2 vs Mic1");

figure;
plot(lags21p, cc21p);
title("GCC-PHAT Mic2 vs Mic1");