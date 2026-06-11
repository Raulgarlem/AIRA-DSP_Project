function result = run_full_das_soft_mask( ...
    case_name, mask_exponent, mask_floor)
%RUN_FULL_DAS_SOFT_MASK Full-recording DAS with soft time-frequency masks.
%
% For every WOLA time-frequency bin:
%   1. Form one DAS beam for each localized DOA.
%   2. Compare the smoothed beam powers.
%   3. Apply a soft Wiener-like mask to every beam.
%
% Examples:
%   result = run_full_das_soft_mask("clean-2source");
%   result = run_full_das_soft_mask("clean-2source", 1.5, 0.05);

  pkg load signal;

  if nargin < 1 || isempty(case_name)
    case_name = "clean-2source";
  endif
  if nargin < 2 || isempty(mask_exponent)
    mask_exponent = 1.5;
  endif
  if nargin < 3 || isempty(mask_floor)
    mask_floor = 0.05;
  endif
  if mask_exponent <= 0
    error("mask_exponent debe ser mayor que cero.");
  endif
  if mask_floor < 0 || mask_floor >= 1
    error("mask_floor debe estar en el intervalo [0, 1).");
  endif

  config.fs = 48000;
  config.sound_speed = 343;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.temporal_power_smoothing = 0.65;
  config.mask_exponent = mask_exponent;
  config.mask_floor = mask_floor;
  config.output_gain_db = 6.0206;
  config.evaluation_max_delay_s = 0.10;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  localization_directory = fullfile(project_root, "Octave", "Localizacion");
  corpus_path = fullfile(project_root, "data", "corpus48000");
  case_path = fullfile(corpus_path, char(case_name));
  output_directory = fullfile( ...
      separation_directory, "full_results", "das_soft_mask", ...
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

  printf("\nDAS con mascara tiempo-frecuencia suave: %s\n", ...
         char(case_name));
  printf("1. Obteniendo DOAs con DAS adaptativo...\n");
  localization = run_wola_das_adaptive_mask( ...
      {char(case_name)}, localization_csv);
  if isempty(localization)
    error("El localizador no produjo resultados para %s.", case_name);
  endif

  estimated_angles_deg = localization(1).estimates_deg.adaptive(:)';
  true_angles_deg = localization(1).true_angles_deg(:)';
  if isempty(estimated_angles_deg)
    error("No se encontraron DOAs para %s.", case_name);
  endif

  [mic_distance_m, ~] = read_case_info( ...
      fullfile(case_path, "info.txt"));
  [signals, references] = read_complete_audio( ...
      case_path, numel(true_angles_deg), config);
  mic_positions = aira_microphone_positions(mic_distance_m);

  printf(["2. Procesando %.3f segundos con WOLA %d/%d, ", ...
          "exponente=%.2f, piso=%.2f...\n"], ...
         columns(signals) / config.fs, config.frame_length, ...
         config.frame_hop, config.mask_exponent, config.mask_floor);
  timer_id = tic();
  [das_outputs, masked_outputs, mask_diagnostics] = ...
      wola_das_soft_mask( ...
          signals, estimated_angles_deg, mic_positions, config);
  processing_time_s = toc(timer_id);

  das_metrics = evaluate_estimates( ...
      das_outputs, references, estimated_angles_deg, ...
      true_angles_deg, config);
  masked_metrics = evaluate_estimates( ...
      masked_outputs, references, estimated_angles_deg, ...
      true_angles_deg, config);

  printf("3. Guardando audios completos en:\n%s\n", output_directory);
  output_paths = write_audio_outputs( ...
      output_directory, das_outputs, masked_outputs, ...
      estimated_angles_deg, config);
  write_metrics_csv( ...
      fullfile(output_directory, "separation_metrics.csv"), ...
      das_metrics, masked_metrics, true_angles_deg);
  write_info_file( ...
      fullfile(output_directory, "separation_info.txt"), ...
      case_name, true_angles_deg, estimated_angles_deg, ...
      columns(signals), processing_time_s, mask_diagnostics, ...
      das_metrics, masked_metrics, config);

  result.case_name = char(case_name);
  result.method = "DAS con mascara tiempo-frecuencia suave";
  result.true_angles_deg = true_angles_deg;
  result.estimated_angles_deg = estimated_angles_deg;
  result.das_metrics = das_metrics;
  result.masked_metrics = masked_metrics;
  result.mask_diagnostics = mask_diagnostics;
  result.duration_s = columns(signals) / config.fs;
  result.processing_time_s = processing_time_s;
  result.output_directory = output_directory;
  result.output_paths = output_paths;

  printf("Terminado en %.3f segundos.\n", processing_time_s);
  print_metric_comparison(das_metrics, masked_metrics);
endfunction

function [das_outputs, masked_outputs, diagnostics] = ...
    wola_das_soft_mask(signals, angles_deg, mic_positions, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  frame_length = config.frame_length;
  frame_hop = config.frame_hop;
  number_bins = frame_length / 2 + 1;
  frequencies_hz = (0:number_bins - 1) * config.fs / frame_length;
  window = periodic_hann(frame_length);

  left_padding = frame_length / 2;
  padded = [zeros(number_mics, left_padding), ...
            signals, zeros(number_mics, left_padding)];
  extra_padding = mod( ...
      -(columns(padded) - frame_length), frame_hop);
  padded = [padded, zeros(number_mics, extra_padding)];
  padded_samples = columns(padded);
  frame_starts = 1:frame_hop:(padded_samples - frame_length + 1);

  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  steering = complex(zeros(number_mics, number_sources, number_bins));
  for frequency_id = 1:number_bins
    steering(:, :, frequency_id) = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
  endfor

  das_padded = zeros(number_sources, padded_samples);
  masked_padded = zeros(number_sources, padded_samples);
  normalization = zeros(1, padded_samples);
  smoothed_power = [];
  mask_sum = zeros(1, number_sources);
  mask_squared_sum = zeros(1, number_sources);
  dominance_sum = 0;
  mask_value_count = 0;

  for frame_id = 1:numel(frame_starts)
    frame_range = frame_starts(frame_id): ...
                  frame_starts(frame_id) + frame_length - 1;
    frame = padded(:, frame_range) .* repmat(window, number_mics, 1);
    spectrum = fft(frame, [], 2);
    one_sided = spectrum(:, 1:number_bins);
    beam_spectra = complex(zeros(number_sources, number_bins));

    for source_id = 1:number_sources
      source_steering = reshape( ...
          steering(:, source_id, :), number_mics, number_bins);
      beam_spectra(source_id, :) = sum( ...
          conj(source_steering) .* one_sided, 1) / number_mics;
    endfor

    current_power = abs(beam_spectra) .^ 2;
    for source_id = 1:number_sources
      current_power(source_id, :) = conv( ...
          current_power(source_id, :), [0.25, 0.50, 0.25], "same");
    endfor
    if isempty(smoothed_power)
      smoothed_power = current_power;
    else
      smoothed_power = config.temporal_power_smoothing * smoothed_power + ...
          (1 - config.temporal_power_smoothing) * current_power;
    endif

    powered = smoothed_power .^ config.mask_exponent;
    masks = powered ./ repmat(sum(powered, 1) + eps, number_sources, 1);
    masks = config.mask_floor + (1 - config.mask_floor) * masks;

    mask_sum += sum(masks, 2)';
    mask_squared_sum += sum(masks .^ 2, 2)';
    dominance_sum += sum(max(masks, [], 1));
    mask_value_count += number_bins;

    for source_id = 1:number_sources
      das_spectrum = complete_spectrum( ...
          beam_spectra(source_id, :), frame_length);
      masked_spectrum = complete_spectrum( ...
          masks(source_id, :) .* beam_spectra(source_id, :), ...
          frame_length);
      das_frame = real(ifft(das_spectrum)) .* window;
      masked_frame = real(ifft(masked_spectrum)) .* window;
      das_padded(source_id, frame_range) += das_frame;
      masked_padded(source_id, frame_range) += masked_frame;
    endfor

    normalization(frame_range) += window .^ 2;
  endfor

  valid = normalization > 1e-8;
  das_padded(:, valid) ./= repmat( ...
      normalization(valid), number_sources, 1);
  masked_padded(:, valid) ./= repmat( ...
      normalization(valid), number_sources, 1);
  original_range = left_padding + 1:left_padding + samples;
  das_outputs = das_padded(:, original_range);
  masked_outputs = masked_padded(:, original_range);

  diagnostics.mean_mask = mask_sum / mask_value_count;
  diagnostics.rms_mask = sqrt(mask_squared_sum / mask_value_count);
  diagnostics.mean_dominant_mask = dominance_sum / mask_value_count;
  diagnostics.frames = numel(frame_starts);
endfunction

function spectrum = complete_spectrum(one_sided, frame_length)
  number_bins = frame_length / 2 + 1;
  spectrum = complex(zeros(1, frame_length));
  spectrum(1:number_bins) = one_sided;
  spectrum(number_bins + 1:end) = ...
      conj(one_sided(number_bins - 1:-1:2));
endfunction

function metrics = evaluate_estimates( ...
    estimates, references, estimated_angles_deg, true_angles_deg, config)

  number_sources = rows(references);
  score_matrix = -Inf(number_sources, number_sources);
  correlation_matrix = zeros(number_sources, number_sources);
  for estimated_id = 1:number_sources
    for reference_id = 1:number_sources
      [score_matrix(estimated_id, reference_id), ...
       correlation_matrix(estimated_id, reference_id)] = ...
          aligned_si_sdr( ...
              estimates(estimated_id, :), ...
              references(reference_id, :), config);
    endfor
  endfor

  candidate_orders = perms(1:number_sources);
  best_score = -Inf;
  best_order = 1:number_sources;
  for order_id = 1:rows(candidate_orders)
    order = candidate_orders(order_id, :);
    score = 0;
    for reference_id = 1:number_sources
      score += score_matrix(order(reference_id), reference_id);
    endfor
    if score > best_score
      best_score = score;
      best_order = order;
    endif
  endfor

  metrics.si_sdr_db = zeros(1, number_sources);
  metrics.correlation = zeros(1, number_sources);
  metrics.estimated_angles_deg = zeros(1, number_sources);
  metrics.permutation = best_order;
  for reference_id = 1:number_sources
    estimated_id = best_order(reference_id);
    metrics.si_sdr_db(reference_id) = ...
        score_matrix(estimated_id, reference_id);
    metrics.correlation(reference_id) = ...
        correlation_matrix(estimated_id, reference_id);
    metrics.estimated_angles_deg(reference_id) = ...
        estimated_angles_deg(estimated_id);
  endfor
endfunction

function [score_db, correlation] = aligned_si_sdr(estimate, reference, config)
  estimate = estimate(:)';
  reference = reference(:)';
  samples = min(numel(estimate), numel(reference));
  estimate = estimate(1:samples);
  reference = reference(1:samples);
  max_lag = min(round(config.evaluation_max_delay_s * config.fs), ...
                floor(samples / 4));
  [cross_correlation, lags] = xcorr(estimate, reference, max_lag);
  [~, best_id] = max(abs(cross_correlation));
  lag = lags(best_id);

  if lag >= 0
    estimate = estimate(1 + lag:end);
    reference = reference(1:end - lag);
  else
    estimate = estimate(1:end + lag);
    reference = reference(1 - lag:end);
  endif

  estimate -= mean(estimate);
  reference -= mean(reference);
  scale = (estimate * reference') / (reference * reference' + eps);
  target = scale * reference;
  residual = estimate - target;
  score_db = 10 * log10( ...
      (target * target' + eps) / (residual * residual' + eps));
  correlation = abs(estimate * reference') / ...
      (sqrt(estimate * estimate' * reference * reference') + eps);
endfunction

function [signals, references] = read_complete_audio( ...
    case_path, number_references, config)

  microphone_paths = {
    fullfile(case_path, "wav_mic1.wav"), ...
    fullfile(case_path, "wav_mic2.wav"), ...
    fullfile(case_path, "wav_mic3.wav")
  };
  [first_signal, fs] = audioread(microphone_paths{1});
  if fs != config.fs
    error("%s tiene fs=%d; se esperaba %d.", ...
          microphone_paths{1}, fs, config.fs);
  endif
  samples = rows(first_signal);
  signals = zeros(3, samples);
  signals(1, :) = first_signal(:, 1)';
  for microphone_id = 2:3
    [signal, signal_fs] = audioread(microphone_paths{microphone_id});
    if signal_fs != config.fs || rows(signal) != samples
      error("Audio incompatible: %s", microphone_paths{microphone_id});
    endif
    signals(microphone_id, :) = signal(:, 1)';
  endfor

  references = zeros(number_references, samples);
  for reference_id = 1:number_references
    reference_path = fullfile( ...
        case_path, sprintf("pristine_channel%d.wav", reference_id));
    [reference, reference_fs] = audioread(reference_path);
    if reference_fs != config.fs
      error("%s tiene fs=%d; se esperaba %d.", ...
            reference_path, reference_fs, config.fs);
    endif
    copied_samples = min(samples, rows(reference));
    references(reference_id, 1:copied_samples) = ...
        reference(1:copied_samples, 1)';
  endfor
endfunction

function output_paths = write_audio_outputs( ...
    output_directory, das_outputs, masked_outputs, angles_deg, config)

  number_sources = rows(das_outputs);
  output_paths.das = cell(1, number_sources);
  output_paths.masked = cell(1, number_sources);
  for source_id = 1:number_sources
    angle = round(angles_deg(source_id));
    output_paths.das{source_id} = fullfile( ...
        output_directory, ...
        sprintf("das_source%d_angle_%+04d.wav", source_id, angle));
    output_paths.masked{source_id} = fullfile( ...
        output_directory, ...
        sprintf("masked_source%d_angle_%+04d.wav", source_id, angle));
    audiowrite(output_paths.das{source_id}, ...
      prepare_output(das_outputs(source_id, :), config)', config.fs);
    audiowrite(output_paths.masked{source_id}, ...
      prepare_output(masked_outputs(source_id, :), config)', config.fs);
  endfor
endfunction

function output = prepare_output(signal, config)
  output = (10 ^ (config.output_gain_db / 20)) * signal;
  peak = max(abs(output));
  if peak > 0.999
    output = 0.999 * output / peak;
  endif
endfunction

function write_metrics_csv( ...
    output_path, das_metrics, masked_metrics, true_angles_deg)

  file_id = fopen(output_path, "w");
  fprintf(file_id, ...
      "method,source,true_angle_deg,estimated_angle_deg,si_sdr_db,correlation\n");
  for source_id = 1:numel(true_angles_deg)
    fprintf(file_id, "das,%d,%.2f,%.2f,%.6f,%.6f\n", ...
            source_id, true_angles_deg(source_id), ...
            das_metrics.estimated_angles_deg(source_id), ...
            das_metrics.si_sdr_db(source_id), ...
            das_metrics.correlation(source_id));
    fprintf(file_id, "soft_mask,%d,%.2f,%.2f,%.6f,%.6f\n", ...
            source_id, true_angles_deg(source_id), ...
            masked_metrics.estimated_angles_deg(source_id), ...
            masked_metrics.si_sdr_db(source_id), ...
            masked_metrics.correlation(source_id));
  endfor
  fclose(file_id);
endfunction

function write_info_file( ...
    output_path, case_name, true_angles_deg, estimated_angles_deg, ...
    samples, processing_time_s, diagnostics, das_metrics, ...
    masked_metrics, config)

  file_id = fopen(output_path, "w");
  fprintf(file_id, "Caso: %s\n", char(case_name));
  fprintf(file_id, "Metodo: DAS WOLA con mascara tiempo-frecuencia suave\n");
  fprintf(file_id, "Ventana/salto: %d/%d\n", ...
          config.frame_length, config.frame_hop);
  fprintf(file_id, "Suavizado temporal de potencia: %.3f\n", ...
          config.temporal_power_smoothing);
  fprintf(file_id, "Exponente de mascara: %.3f\n", ...
          config.mask_exponent);
  fprintf(file_id, "Piso de mascara: %.3f\n", config.mask_floor);
  fprintf(file_id, "Ganancia de salida: %.4f dB\n", ...
          config.output_gain_db);
  fprintf(file_id, "Muestras: %d\n", samples);
  fprintf(file_id, "Duracion: %.6f s\n", samples / config.fs);
  fprintf(file_id, "Angulos reales: %s\n", ...
          strtrim(sprintf("%.2f ", true_angles_deg)));
  fprintf(file_id, "Angulos estimados: %s\n", ...
          strtrim(sprintf("%.2f ", estimated_angles_deg)));
  fprintf(file_id, "Mascara media: %s\n", ...
          strtrim(sprintf("%.4f ", diagnostics.mean_mask)));
  fprintf(file_id, "Mascara dominante media: %.4f\n", ...
          diagnostics.mean_dominant_mask);
  fprintf(file_id, "SI-SDR DAS: %s\n", ...
          strtrim(sprintf("%.4f ", das_metrics.si_sdr_db)));
  fprintf(file_id, "SI-SDR mascara: %s\n", ...
          strtrim(sprintf("%.4f ", masked_metrics.si_sdr_db)));
  fprintf(file_id, "Tiempo de separacion: %.6f s\n", processing_time_s);
  fclose(file_id);
endfunction

function print_metric_comparison(das_metrics, masked_metrics)
  for source_id = 1:numel(das_metrics.si_sdr_db)
    improvement = masked_metrics.si_sdr_db(source_id) - ...
                  das_metrics.si_sdr_db(source_id);
    printf(["  Fuente %d: DAS %.3f dB, mascara %.3f dB, ", ...
            "cambio %+.3f dB\n"], ...
           source_id, das_metrics.si_sdr_db(source_id), ...
           masked_metrics.si_sdr_db(source_id), improvement);
  endfor
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
  sample_ids = 0:length_samples - 1;
  window = 0.5 - 0.5 * cos(2 * pi * sample_ids / length_samples);
endfunction
