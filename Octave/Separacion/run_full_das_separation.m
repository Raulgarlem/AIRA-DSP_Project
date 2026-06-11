function result = run_full_das_separation(case_name)
%RUN_FULL_DAS_SEPARATION Save complete DAS-separated recordings.
%
% The adaptive DAS localizer estimates the source directions from its
% standard one-second analysis segment. Those directions are then used to
% process every sample of the selected corpus recording with WOLA DAS.
%
% Example:
%   result = run_full_das_separation("clean-2source");

  if nargin < 1 || isempty(case_name)
    case_name = "clean-2source";
  endif

  config.fs = 48000;
  config.sound_speed = 343;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.frames_per_block = 64;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  localization_directory = fullfile(project_root, "Octave", "Localizacion");
  corpus_path = fullfile(project_root, "data", "corpus48000");
  case_path = fullfile(corpus_path, char(case_name));
  output_directory = fullfile( ...
      separation_directory, "full_results", char(case_name));
  localization_csv = fullfile( ...
      output_directory, "localization_results.csv");
  addpath(localization_directory);

  if !exist(case_path, "dir")
    error("No existe la carpeta: %s", case_path);
  endif
  if !exist(output_directory, "dir")
    mkdir(output_directory);
  endif

  printf("\nSeparacion DAS completa: %s\n", char(case_name));
  printf("1. Localizando fuentes...\n");
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

  printf("3. Procesando %.2f segundos, DOAs=%s grados...\n", ...
         columns(signals) / config.fs, ...
         strtrim(sprintf("%.1f ", estimated_angles_deg)));
  timer_id = tic();
  separated = apply_complete_wola_das( ...
      signals, estimated_angles_deg, mic_positions, config);
  processing_time_s = toc(timer_id);

  printf("4. Guardando WAV en:\n%s\n", output_directory);
  output_paths = cell(1, rows(separated));
  for source_id = 1:rows(separated)
    output_paths{source_id} = fullfile( ...
        output_directory, sprintf("source%d.wav", source_id));
    signal = prevent_clipping(separated(source_id, :));
    audiowrite(output_paths{source_id}, signal', config.fs);
  endfor
  write_info_file( ...
      fullfile(output_directory, "separation_info.txt"), ...
      case_name, true_angles_deg, estimated_angles_deg, ...
      columns(signals), processing_time_s, output_paths, config);

  result.case_name = char(case_name);
  result.true_angles_deg = true_angles_deg;
  result.estimated_angles_deg = estimated_angles_deg;
  result.duration_s = columns(signals) / config.fs;
  result.processing_time_s = processing_time_s;
  result.output_directory = output_directory;
  result.output_paths = output_paths;

  printf("Separacion terminada en %.2f segundos.\n", processing_time_s);
  for source_id = 1:numel(output_paths)
    printf("  Fuente %d (%.1f grados): %s\n", ...
           source_id, estimated_angles_deg(source_id), ...
           output_paths{source_id});
  endfor
endfunction

function outputs = apply_complete_wola_das( ...
    signals, angles_deg, mic_positions, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  number_bins = config.frame_length / 2 + 1;
  frequencies_hz = (0:number_bins - 1) * ...
                   config.fs / config.frame_length;
  window = periodic_hann(config.frame_length);

  padding = config.frame_length;
  padded_signals = [
    zeros(number_mics, padding), ...
    signals, ...
    zeros(number_mics, padding)
  ];
  padded_samples = columns(padded_signals);
  frame_starts = 1:config.frame_hop: ...
                 (padded_samples - config.frame_length + 1);

  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  steering = complex(zeros(number_mics, number_sources, number_bins));
  for frequency_id = 1:number_bins
    steering(:, :, frequency_id) = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
  endfor

  output_accumulator = zeros(number_sources, padded_samples);
  normalization = zeros(1, padded_samples);
  number_frames = numel(frame_starts);

  for block_start = 1:config.frames_per_block:number_frames
    block_end = min( ...
        number_frames, block_start + config.frames_per_block - 1);
    for frame_id = block_start:block_end
      frame_start = frame_starts(frame_id);
      frame_range = frame_start: ...
                    frame_start + config.frame_length - 1;
      frame = padded_signals(:, frame_range) .* ...
              repmat(window, number_mics, 1);
      spectrum = fft(frame, [], 2);
      one_sided = spectrum(:, 1:number_bins);

      for source_id = 1:number_sources
        output_spectrum = complex(zeros(1, config.frame_length));
        source_steering = squeeze( ...
            steering(:, source_id, :));
        output_spectrum(1:number_bins) = ...
            sum(conj(source_steering) .* one_sided, 1) / number_mics;
        output_spectrum(number_bins + 1:end) = ...
            conj(output_spectrum(number_bins - 1:-1:2));
        output_frame = real(ifft(output_spectrum)) .* window;
        output_accumulator(source_id, frame_range) += output_frame;
      endfor
      normalization(frame_range) += window .^ 2;
    endfor

    printf("   Progreso: %5.1f%%\r", 100 * block_end / number_frames);
  endfor
  printf("   Progreso: 100.0%%\n");

  valid = normalization > 1e-8;
  output_accumulator(:, valid) ./= repmat( ...
      normalization(valid), number_sources, 1);
  output_accumulator(:, !valid) = 0;

  original_range = padding + 1:padding + samples;
  outputs = output_accumulator(:, original_range);
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
    samples, processing_time_s, output_paths, config)

  file_id = fopen(info_path, "w");
  if file_id < 0
    error("No se pudo crear %s.", info_path);
  endif
  unwind_protect
    fprintf(file_id, "Caso: %s\n", char(case_name));
    fprintf(file_id, "Frecuencia de muestreo: %d Hz\n", config.fs);
    fprintf(file_id, "Muestras: %d\n", samples);
    fprintf(file_id, "Duracion: %.6f s\n", samples / config.fs);
    fprintf(file_id, "Ventana WOLA: %d\n", config.frame_length);
    fprintf(file_id, "Salto WOLA: %d\n", config.frame_hop);
    fprintf(file_id, "Angulos reales: %s\n", ...
            strtrim(sprintf("%.2f ", true_angles_deg)));
    fprintf(file_id, "Angulos estimados: %s\n", ...
            strtrim(sprintf("%.2f ", estimated_angles_deg)));
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

function window = periodic_hann(length_samples)
  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:length_samples - 1) / length_samples);
endfunction
