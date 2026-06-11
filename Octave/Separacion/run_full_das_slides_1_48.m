function result = run_full_das_slides_1_48(case_name, target_rms_dbfs)
%RUN_FULL_DAS_SLIDES_1_48 Full-recording frequency-domain DAS.
%
% Implements the procedure from slides 1 to 48 of 07.2-Beamforming:
%   1. Obtain the known DOA of every source.
%   2. Calculate one steering vector per frequency and source.
%   3. Transform every microphone signal with the FFT.
%   4. Apply S_hat(f) = W(f)^H X(f) / M.
%   5. Return to time with the IFFT.
%
% Example:
%   result = run_full_das_slides_1_48("clean-2source");
%   result = run_full_das_slides_1_48("clean-2source", -20);

  if nargin < 1 || isempty(case_name)
    case_name = "clean-2source";
  endif
  if nargin < 2 || isempty(target_rms_dbfs)
    target_rms_dbfs = -20;
  endif
  config.fs = 48000;
  config.sound_speed = 343;
  config.padding_samples = 1024;
  config.peak_target = 0.95;
  config.target_rms_dbfs = target_rms_dbfs;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  localization_directory = fullfile(project_root, "Octave", "Localizacion");
  corpus_path = fullfile(project_root, "data", "corpus48000");
  case_path = fullfile(corpus_path, char(case_name));
  output_directory = fullfile( ...
      separation_directory, "full_results", "slides_1_48", ...
      char(case_name));
  localization_csv = fullfile( ...
      output_directory, "localization_results.csv");
  addpath(localization_directory);

  if !exist(case_path, "dir")
    error("No existe la carpeta: %s", case_path);
  endif
  if !exist(output_directory, "dir")
    mkdir(output_directory);
  endif

  printf("\nDAS completo segun diapositivas 1-48: %s\n", ...
         char(case_name));
  printf("1. Obteniendo DOAs con DAS adaptativo...\n");
  localization = run_wola_das_adaptive_mask( ...
      {char(case_name)}, localization_csv);
  if isempty(localization)
    error("El localizador no produjo resultados para %s.", case_name);
  endif

  estimated_angles_deg = localization(1).estimates_deg.adaptive;
  true_angles_deg = localization(1).true_angles_deg;
  if isempty(estimated_angles_deg)
    error("No se encontraron DOAs para %s.", case_name);
  endif

  [mic_distance_m, ~] = read_case_info( ...
      fullfile(case_path, "info.txt"));
  printf("2. Leyendo todos los WAV...\n");
  signals = read_complete_signals(case_path, config);
  [pre_normalized_signals, input_normalization_gain] = ...
      normalize_multichannel_rms( ...
          signals, config.target_rms_dbfs, config.peak_target);
  mic_positions = aira_microphone_positions(mic_distance_m);

  printf(["3. Aplicando DAS original y DAS con normalizacion ", ...
          "comun previa a %.3f segundos...\n"], ...
         columns(signals) / config.fs);
  timer_id = tic();
  separated = frequency_domain_delay_and_sum( ...
      signals, estimated_angles_deg, mic_positions, config);
  pre_normalized_separated = frequency_domain_delay_and_sum( ...
      pre_normalized_signals, estimated_angles_deg, ...
      mic_positions, config);
  processing_time_s = toc(timer_id);

  printf("4. Guardando audios completos en:\n%s\n", output_directory);
  output_paths.raw = cell(1, rows(separated));
  output_paths.peak = cell(1, rows(separated));
  output_paths.rms = cell(1, rows(separated));
  output_paths.pre_normalized = cell(1, rows(separated));
  level_statistics = struct([]);
  for source_id = 1:rows(separated)
    raw = prevent_clipping(separated(source_id, :));
    peak_normalized = normalize_peak( ...
        separated(source_id, :), config.peak_target);
    rms_normalized = normalize_rms( ...
        separated(source_id, :), config.target_rms_dbfs, ...
        config.peak_target);
    pre_normalized = prevent_clipping( ...
        pre_normalized_separated(source_id, :));

    output_paths.raw{source_id} = fullfile( ...
        output_directory, sprintf("source%d_das.wav", source_id));
    output_paths.peak{source_id} = fullfile( ...
        output_directory, ...
        sprintf("source%d_peak_normalized.wav", source_id));
    output_paths.rms{source_id} = fullfile( ...
        output_directory, ...
        sprintf("source%d_rms_%+03ddBFS.wav", ...
                source_id, round(config.target_rms_dbfs)));
    output_paths.pre_normalized{source_id} = fullfile( ...
        output_directory, ...
        sprintf("source%d_pre_normalized_das.wav", source_id));

    audiowrite(output_paths.raw{source_id}, raw', config.fs);
    audiowrite(output_paths.peak{source_id}, ...
               peak_normalized', config.fs);
    audiowrite(output_paths.rms{source_id}, ...
               rms_normalized', config.fs);
    audiowrite(output_paths.pre_normalized{source_id}, ...
               pre_normalized', config.fs);

    level_statistics(source_id).raw_peak = max(abs(raw));
    level_statistics(source_id).raw_rms_dbfs = rms_dbfs(raw);
    level_statistics(source_id).peak_normalized_peak = ...
        max(abs(peak_normalized));
    level_statistics(source_id).peak_normalized_rms_dbfs = ...
        rms_dbfs(peak_normalized);
    level_statistics(source_id).rms_normalized_peak = ...
        max(abs(rms_normalized));
    level_statistics(source_id).rms_normalized_rms_dbfs = ...
        rms_dbfs(rms_normalized);
    level_statistics(source_id).pre_normalized_peak = ...
        max(abs(pre_normalized));
    level_statistics(source_id).pre_normalized_rms_dbfs = ...
        rms_dbfs(pre_normalized);
    level_statistics(source_id).pre_vs_raw_correlation = ...
        normalized_correlation(raw, pre_normalized);
  endfor

  write_info_file( ...
      fullfile(output_directory, "separation_info.txt"), ...
      case_name, true_angles_deg, estimated_angles_deg, ...
      columns(signals), processing_time_s, output_paths, ...
      level_statistics, input_normalization_gain, config);

  result.case_name = char(case_name);
  result.method = "DAS diapositivas 1-48";
  result.true_angles_deg = true_angles_deg;
  result.estimated_angles_deg = estimated_angles_deg;
  result.duration_s = columns(signals) / config.fs;
  result.processing_time_s = processing_time_s;
  result.output_directory = output_directory;
  result.output_paths = output_paths;
  result.level_statistics = level_statistics;
  result.input_normalization_gain = input_normalization_gain;

  printf("Terminado en %.3f segundos.\n", processing_time_s);
  for source_id = 1:rows(separated)
    printf(["  Fuente %d, DOA %.1f grados: RMS original %.2f dBFS, ", ...
            "RMS normalizado %.2f dBFS\n"], ...
           source_id, estimated_angles_deg(source_id), ...
           level_statistics(source_id).raw_rms_dbfs, ...
           level_statistics(source_id).rms_normalized_rms_dbfs);
    printf(["    Normalizacion previa: RMS %.2f dBFS, ", ...
            "correlacion con DAS=%.9f\n"], ...
           level_statistics(source_id).pre_normalized_rms_dbfs, ...
           level_statistics(source_id).pre_vs_raw_correlation);
  endfor
endfunction

function outputs = frequency_domain_delay_and_sum( ...
    signals, angles_deg, mic_positions, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  padding = config.padding_samples;
  minimum_fft_length = samples + 2 * padding;
  fft_length = 2 ^ nextpow2(minimum_fft_length);
  padded_signals = zeros(number_mics, fft_length);
  original_range = padding + 1:padding + samples;
  padded_signals(:, original_range) = signals;
  captured_spectra = fft(padded_signals, [], 2);

  frequency_ids = [ ...
    0:(fft_length / 2), ...
    (-fft_length / 2 + 1):-1
  ];
  frequencies_hz = frequency_ids * config.fs / fft_length;
  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  outputs = zeros(number_sources, samples);

  for source_id = 1:number_sources
    direction_vector = exp( ...
        -1i * 2 * pi * ...
        delays_s(:, source_id) * frequencies_hz);

    % Octave's apostrophe applies the Hermitian operation from slide 31.
    source_spectrum = sum( ...
        conj(direction_vector) .* captured_spectra, 1) / number_mics;
    full_output = real(ifft(source_spectrum));
    outputs(source_id, :) = full_output(original_range);
  endfor
endfunction

function signals = read_complete_signals(case_path, config)
  paths = {
    fullfile(case_path, "wav_mic1.wav"), ...
    fullfile(case_path, "wav_mic2.wav"), ...
    fullfile(case_path, "wav_mic3.wav")
  };

  [first_signal, fs] = audioread(paths{1});
  if fs != config.fs
    error("%s tiene fs=%d; se esperaba %d.", paths{1}, fs, config.fs);
  endif
  samples = rows(first_signal);
  signals = zeros(3, samples);
  signals(1, :) = first_signal(:, 1)';

  for microphone_id = 2:3
    [signal, signal_fs] = audioread(paths{microphone_id});
    if signal_fs != config.fs || rows(signal) != samples
      error("Audio incompatible: %s", paths{microphone_id});
    endif
    signals(microphone_id, :) = signal(:, 1)';
  endfor
endfunction

function write_info_file( ...
    info_path, case_name, true_angles_deg, estimated_angles_deg, ...
    samples, processing_time_s, output_paths, level_statistics, ...
    input_normalization_gain, config)

  file_id = fopen(info_path, "w");
  if file_id < 0
    error("No se pudo crear %s.", info_path);
  endif
  unwind_protect
    fprintf(file_id, "Caso: %s\n", char(case_name));
    fprintf(file_id, ...
            "Metodo: DAS en frecuencia, diapositivas 1-48\n");
    fprintf(file_id, "Ecuacion: S_hat(f) = W(f)^H X(f) / M\n");
    fprintf(file_id, "Frecuencia de muestreo: %d Hz\n", config.fs);
    fprintf(file_id, "Muestras: %d\n", samples);
    fprintf(file_id, "Duracion: %.6f s\n", samples / config.fs);
    fprintf(file_id, "Relleno por extremo: %d muestras\n", ...
            config.padding_samples);
    fprintf(file_id, "Pico objetivo: %.4f\n", config.peak_target);
    fprintf(file_id, "RMS objetivo: %.2f dBFS\n", ...
            config.target_rms_dbfs);
    fprintf(file_id, "Ganancia comun previa al DAS: %.9f\n", ...
            input_normalization_gain);
    fprintf(file_id, "Angulos reales: %s\n", ...
            strtrim(sprintf("%.2f ", true_angles_deg)));
    fprintf(file_id, "Angulos estimados: %s\n", ...
            strtrim(sprintf("%.2f ", estimated_angles_deg)));
    fprintf(file_id, "Tiempo de separacion: %.6f s\n", ...
            processing_time_s);
    for source_id = 1:numel(output_paths.raw)
      statistics = level_statistics(source_id);
      fprintf(file_id, "Fuente %d, DOA %.2f grados\n", ...
              source_id, estimated_angles_deg(source_id));
      fprintf(file_id, "  DAS: pico=%.6f, RMS=%.3f dBFS, %s\n", ...
              statistics.raw_peak, statistics.raw_rms_dbfs, ...
              output_paths.raw{source_id});
      fprintf(file_id, ...
              "  Pico: pico=%.6f, RMS=%.3f dBFS, %s\n", ...
              statistics.peak_normalized_peak, ...
              statistics.peak_normalized_rms_dbfs, ...
              output_paths.peak{source_id});
      fprintf(file_id, ...
              "  RMS: pico=%.6f, RMS=%.3f dBFS, %s\n", ...
              statistics.rms_normalized_peak, ...
              statistics.rms_normalized_rms_dbfs, ...
              output_paths.rms{source_id});
      fprintf(file_id, ...
              ["  Normalizacion previa: pico=%.6f, RMS=%.3f dBFS, ", ...
               "correlacion=%.9f, %s\n"], ...
              statistics.pre_normalized_peak, ...
              statistics.pre_normalized_rms_dbfs, ...
              statistics.pre_vs_raw_correlation, ...
              output_paths.pre_normalized{source_id});
    endfor
  unwind_protect_cleanup
    fclose(file_id);
  end_unwind_protect
endfunction

function [normalized, gain] = normalize_multichannel_rms( ...
    signals, target_rms_dbfs, peak_limit)

  current_rms = sqrt(mean(signals(:) .^ 2));
  target_rms = 10 ^ (target_rms_dbfs / 20);
  if current_rms > eps
    gain = target_rms / current_rms;
  else
    gain = 1;
  endif

  normalized = gain * signals;
  peak = max(abs(normalized(:)));
  if peak > peak_limit
    gain *= peak_limit / peak;
    normalized = gain * signals;
  endif
endfunction

function normalized = normalize_peak(signal, target_peak)
  peak = max(abs(signal));
  if peak > eps
    normalized = target_peak * signal / peak;
  else
    normalized = signal;
  endif
endfunction

function normalized = normalize_rms( ...
    signal, target_rms_dbfs, peak_limit)

  current_rms = sqrt(mean(signal .^ 2));
  target_rms = 10 ^ (target_rms_dbfs / 20);
  if current_rms > eps
    normalized = signal * target_rms / current_rms;
  else
    normalized = signal;
  endif

  peak = max(abs(normalized));
  if peak > peak_limit
    normalized *= peak_limit / peak;
  endif
endfunction

function value = rms_dbfs(signal)
  value = 20 * log10(sqrt(mean(signal .^ 2)) + eps);
endfunction

function value = normalized_correlation(first, second)
  value = abs(first * second') / ...
      (sqrt(first * first' * second * second') + eps);
endfunction

function limited = prevent_clipping(signal)
  peak = max(abs(signal));
  if peak > 0.999
    limited = 0.999 * signal / peak;
  else
    limited = signal;
  endif
endfunction

function [mic_distance_m, angles_deg] = read_case_info(info_path)
  text = fileread(info_path);
  lines = strsplit(strtrim(text), {"\r\n", "\n", "\r"});
  mic_distance_m = str2double(strtrim(lines{1}));
  angles_deg = sscanf( ...
      strrep(strjoin(lines(2:end), " "), ",", " "), "%f")';
endfunction

function positions = aira_microphone_positions(distance_m)
  positions = [
     0.00,              0.00;
    -distance_m,        0.00;
    -distance_m / 2,   -sqrt(3) * distance_m / 2
  ];
  positions -= repmat(mean(positions, 1), rows(positions), 1);
endfunction
