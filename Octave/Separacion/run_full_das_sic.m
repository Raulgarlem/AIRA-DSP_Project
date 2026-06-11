function result = run_full_das_sic(case_name, cancellation_factor)
%RUN_FULL_DAS_SIC Full-recording DAS with successive interference cancellation.
%
% At each stage:
%   1. Apply DAS to every remaining DOA.
%   2. Select the strongest remaining source.
%   3. Reconstruct its contribution at every microphone.
%   4. Subtract a fraction of that contribution from the microphone mixture.
%
% Example:
%   result = run_full_das_sic("clean-2source");
%   result = run_full_das_sic("clean-2source", 0.70);

  if nargin < 1 || isempty(case_name)
    case_name = "clean-2source";
  endif
  if nargin < 2 || isempty(cancellation_factor)
    cancellation_factor = 0.70;
  endif
  if cancellation_factor < 0 || cancellation_factor > 1
    error("El factor de cancelacion debe estar entre 0 y 1.");
  endif

  config.fs = 48000;
  config.sound_speed = 343;
  config.padding_samples = 1024;
  config.cancellation_factor = cancellation_factor;
  config.output_gain_db = 6.0206;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  localization_directory = fullfile(project_root, "Octave", "Localizacion");
  corpus_path = fullfile(project_root, "data", "corpus48000");
  case_path = fullfile(corpus_path, char(case_name));
  output_directory = fullfile( ...
      separation_directory, "full_results", "das_sic", char(case_name));
  localization_csv = fullfile( ...
      output_directory, "localization_results.csv");
  addpath(localization_directory);

  if !exist(case_path, "dir")
    error("No existe la carpeta: %s", case_path);
  endif
  if !exist(output_directory, "dir")
    mkdir(output_directory);
  endif

  printf("\nDAS con cancelacion sucesiva: %s\n", char(case_name));
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
  printf("2. Leyendo grabacion completa...\n");
  signals = read_complete_signals(case_path, config);
  mic_positions = aira_microphone_positions(mic_distance_m);

  printf(["3. Aplicando DAS-SIC a %.3f segundos, ", ...
          "cancelacion=%.0f%%...\n"], ...
         columns(signals) / config.fs, ...
         100 * config.cancellation_factor);
  timer_id = tic();
  [separated, processing_order, residual] = ...
      frequency_domain_das_sic( ...
          signals, estimated_angles_deg, mic_positions, config);
  processing_time_s = toc(timer_id);

  printf("4. Guardando audios completos en:\n%s\n", output_directory);
  output_paths = cell(1, rows(separated));
  for source_id = 1:rows(separated)
    output_paths{source_id} = fullfile( ...
        output_directory, sprintf("source%d.wav", source_id));
    amplified = apply_output_gain( ...
        separated(source_id, :), config.output_gain_db);
    audiowrite( ...
        output_paths{source_id}, prevent_clipping(amplified)', config.fs);
  endfor

  for microphone_id = 1:rows(residual)
    residual_path = fullfile( ...
        output_directory, sprintf("residual_mic%d.wav", microphone_id));
    audiowrite(residual_path, ...
               prevent_clipping(residual(microphone_id, :))', config.fs);
  endfor

  write_info_file( ...
      fullfile(output_directory, "separation_info.txt"), ...
      case_name, true_angles_deg, estimated_angles_deg, ...
      processing_order, columns(signals), processing_time_s, ...
      output_paths, config);

  result.case_name = char(case_name);
  result.method = "DAS-SIC";
  result.true_angles_deg = true_angles_deg;
  result.estimated_angles_deg = estimated_angles_deg;
  result.processing_order = processing_order;
  result.duration_s = columns(signals) / config.fs;
  result.processing_time_s = processing_time_s;
  result.output_directory = output_directory;
  result.output_paths = output_paths;

  printf("Terminado en %.3f segundos.\n", processing_time_s);
  printf("Orden SIC: %s\n", mat2str(processing_order));
  for source_id = 1:numel(output_paths)
    printf("  Fuente %d, DOA %.1f grados: %s\n", ...
           source_id, estimated_angles_deg(source_id), ...
           output_paths{source_id});
  endfor
endfunction

function [outputs, processing_order, residual_time] = ...
    frequency_domain_das_sic(signals, angles_deg, mic_positions, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  padding = config.padding_samples;
  fft_length = 2 ^ nextpow2(samples + 2 * padding);
  original_range = padding + 1:padding + samples;
  padded_signals = zeros(number_mics, fft_length);
  padded_signals(:, original_range) = signals;
  residual_spectra = fft(padded_signals, [], 2);

  frequency_ids = [ ...
    0:(fft_length / 2), ...
    (-fft_length / 2 + 1):-1
  ];
  frequencies_hz = frequency_ids * config.fs / fft_length;
  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  direction_vectors = complex(zeros( ...
      number_mics, fft_length, number_sources));
  for source_id = 1:number_sources
    direction_vectors(:, :, source_id) = exp( ...
        -1i * 2 * pi * ...
        delays_s(:, source_id) * frequencies_hz);
  endfor

  outputs = zeros(number_sources, samples);
  processing_order = zeros(1, number_sources);
  remaining = true(1, number_sources);

  for stage_id = 1:number_sources
    candidate_spectra = complex(zeros(number_sources, fft_length));
    candidate_energy = -Inf(1, number_sources);
    for source_id = find(remaining)
      direction_vector = direction_vectors(:, :, source_id);
      candidate_spectra(source_id, :) = sum( ...
          conj(direction_vector) .* residual_spectra, 1) / number_mics;
      candidate_time = real(ifft(candidate_spectra(source_id, :)));
      candidate = candidate_time(original_range);
      candidate_energy(source_id) = mean(candidate .^ 2);
    endfor

    [~, selected_source] = max(candidate_energy);
    processing_order(stage_id) = selected_source;
    selected_spectrum = candidate_spectra(selected_source, :);
    selected_time = real(ifft(selected_spectrum));
    outputs(selected_source, :) = selected_time(original_range);

    source_image = ...
        direction_vectors(:, :, selected_source) .* ...
        repmat(selected_spectrum, number_mics, 1);
    residual_spectra -= config.cancellation_factor * source_image;
    remaining(selected_source) = false;

    printf("   Etapa %d: fuente %d, DOA %.1f grados\n", ...
           stage_id, selected_source, angles_deg(selected_source));
  endfor

  residual_padded = real(ifft(residual_spectra, [], 2));
  residual_time = residual_padded(:, original_range);
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
    processing_order, samples, processing_time_s, output_paths, config)

  file_id = fopen(info_path, "w");
  if file_id < 0
    error("No se pudo crear %s.", info_path);
  endif
  unwind_protect
    fprintf(file_id, "Caso: %s\n", char(case_name));
    fprintf(file_id, "Metodo: DAS con cancelacion sucesiva\n");
    fprintf(file_id, "Factor de cancelacion: %.4f\n", ...
            config.cancellation_factor);
    fprintf(file_id, "Ganancia de salida: %.4f dB\n", ...
            config.output_gain_db);
    fprintf(file_id, "Frecuencia de muestreo: %d Hz\n", config.fs);
    fprintf(file_id, "Muestras: %d\n", samples);
    fprintf(file_id, "Duracion: %.6f s\n", samples / config.fs);
    fprintf(file_id, "Angulos reales: %s\n", ...
            strtrim(sprintf("%.2f ", true_angles_deg)));
    fprintf(file_id, "Angulos estimados: %s\n", ...
            strtrim(sprintf("%.2f ", estimated_angles_deg)));
    fprintf(file_id, "Orden SIC: %s\n", mat2str(processing_order));
    fprintf(file_id, "Tiempo de separacion: %.6f s\n", ...
            processing_time_s);
    for source_id = 1:numel(output_paths)
      fprintf(file_id, "Fuente %d: %.2f grados, %s\n", ...
              source_id, estimated_angles_deg(source_id), ...
              output_paths{source_id});
    endfor
  unwind_protect_cleanup
    fclose(file_id);
  end_unwind_protect
endfunction

function amplified = apply_output_gain(signal, gain_db)
  amplified = (10 ^ (gain_db / 20)) * signal;
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
