clear all; close all; clc;

pkg load signal;

% =========================
% Parámetros
% =========================
fs = 48000;
c = 343;
d = 0.18;              % distancia entre micrófonos [m]
theta_real = 60;       % ángulo real en grados
theta = deg2rad(theta_real);

dur = 0.1;
t = 0:1/fs:dur;

% Fuente simulada
s = chirp(t, 300, dur, 3000);

% =========================
% Geometría tipo AIRA
% Mic 1 como referencia
% Triángulo equilátero
% =========================
mic1 = [0, 0];
mic2 = [-d, 0];
mic3 = [-d/2, -sqrt(3)*d/2];

mics = [mic1; mic2; mic3];

% Vector de dirección de llegada
u = [sin(theta), cos(theta)];

% Delays relativos respecto a mic 1
tau = zeros(3,1);

for m = 1:3
    tau(m) = dot(mics(m,:) - mic1, u) / c;
end

delay_samples = round(tau * fs);

disp("Delays reales en muestras:");
disp(delay_samples);

% =========================
% Crear señales de micrófonos
% =========================
Npad = 1000;
s_pad = [zeros(1,Npad), s, zeros(1,Npad)];

x = zeros(3, length(s_pad));

for m = 1:3
    shift = delay_samples(m);

    if shift >= 0
        x(m,:) = [zeros(1,shift), s_pad(1:end-shift)];
    else
        shift = abs(shift);
        x(m,:) = [s_pad(shift+1:end), zeros(1,shift)];
    end
end

% Ruido opcional
noise_w = 0.005;
x = x + noise_w * randn(size(x));

% =========================
% Función GCC
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

% =========================
% Estimar delays respecto a mic1
% =========================
[d21, cc21, lags21] = gcc(x(2,:), x(1,:));
[d31, cc31, lags31] = gcc(x(3,:), x(1,:));

printf("Delay estimado mic2-mic1: %d muestras\n", d21);
printf("Delay estimado mic3-mic1: %d muestras\n", d31);

% =========================
% Estimar ángulo
% Usamos mic2 vs mic1:
% tau21 = -d*sin(theta)/c
% =========================
tau21_est = d21 / fs;

sin_theta_est = -tau21_est * c / d;

% Limitar por errores numéricos
sin_theta_est = max(min(sin_theta_est, 1), -1);

theta_est = rad2deg(asin(sin_theta_est));

printf("Ángulo real: %.2f grados\n", theta_real);
printf("Ángulo estimado usando mic2-mic1: %.2f grados\n", theta_est);

% =========================
% Gráficas
% =========================
figure;
plot(x(1,:)); hold on;
plot(x(2,:));
plot(x(3,:));
legend("Mic 1", "Mic 2", "Mic 3");
title("Señales simuladas en arreglo AIRA");

figure;
plot(lags21, cc21);
title("GCC-PHAT Mic 2 vs Mic 1");
xlabel("Lag [muestras]");
ylabel("Correlación");

figure;
plot(lags31, cc31);
title("GCC-PHAT Mic 3 vs Mic 1");
xlabel("Lag [muestras]");
ylabel("Correlación");