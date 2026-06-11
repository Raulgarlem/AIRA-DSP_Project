function results = run_wola_das_adaptive_mask(case_names, output_csv)
%RUN_WOLA_DAS_ADAPTIVE_MASK Select base or SNR-weighted DAS every 3 frames.
%
% Both spectra share the same per-frequency beamformer power. The selector
% only adds mask diagnostics, peak confidence, and hysteresis.
%
% Examples:
%   results = run_wola_das_adaptive_mask();
%   results = run_wola_das_adaptive_mask({"noisy-3source"});
%   results = run_wola_das_adaptive_mask({"clean-3source"}, output_csv);

  if nargin < 1 || isempty(case_names)
    case_names = {
      "clean-3source", ...
      "clean-3source090180", ...
      "noisy-3source", ...
      "noisy-3source090180"
    };
  elseif ischar(case_names)
    case_names = {case_names};
  endif

  config.fs = 48000;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.segment_duration_s = 1.0;
  config.sound_speed = 343;
  config.min_frequency_hz = 300;
  config.max_frequency_hz = 4000;
  config.angle_grid_deg = -180:1:179;
  config.min_peak_separation_deg = 20;

  config.csd_smoothing = 0.90;
  config.power_smoothing = 0.70;
  config.noise_window_frames = 30;
  config.snr_threshold_db = 6;
  config.min_active_bins = 20;
  config.min_effective_bins = 12;
  config.min_mean_weight = 0.15;
  config.min_active_subbands = 3;
  config.subband_weight_threshold = 0.10;

  config.decision_interval_frames = 3;
  config.decision_history_frames = 12;
  config.decision_warmup_frames = 12;
  config.switch_confirmation_decisions = 2;
  config.mask_confidence_margin = 1.05;
  config.initial_mode = "base";
  config.output_history_frames = 20;

  localization_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(localization_directory));
  corpus_path = fullfile(project_root, "data", "corpus48000");
  if nargin < 2 || isempty(output_csv)
    output_csv = fullfile( ...
        localization_directory, "wola_das_adaptive_mask_results.csv");
  endif

  csv_file = fopen(output_csv, "w");
  if csv_file < 0
    error("No se pudo crear el archivo CSV: %s", output_csv);
  endif
  fprintf(csv_file, ...
      ["caso,metodo,angulos_reales,angulos_estimados,", ...
       "errores_por_fuente_grados,error_medio_grados,tramas,", ...
       "porcentaje_mascara,conmutaciones,decisiones_validas,", ...
       "bins_activos_medios,bins_efectivos_medios,peso_medio,", ...
       "analisis_ms,das_dual_ms,decision_ms,total_por_ventana_ms\n"]);

  printf("\nDAS adaptativo base/SNR\n");
  printf("Banda=%d-%d Hz, decision cada %d ventanas\n", ...
         config.min_frequency_hz, config.max_frequency_hz, ...
         config.decision_interval_frames);
  printf("Confirmacion para cambiar: %d decisiones consecutivas\n\n", ...
         config.switch_confirmation_decisions);

  results = struct([]);
  result_id = 0;
  unwind_protect
    for case_id = 1:numel(case_names)
      case_name = char(case_names{case_id});
      case_path = fullfile(corpus_path, case_name);
      if !exist(case_path, "dir")
        warning("No existe el caso %s; se omite.", case_name);
        continue;
      endif

      [mic_distance_m, true_angles_deg] = read_case_info( ...
          fullfile(case_path, "info.txt"));
      signals = read_case_signals(case_path, config);
      mic_positions = aira_microphone_positions(mic_distance_m);

      case_result = process_adaptive_case( ...
          signals, mic_positions, true_angles_deg, config);
      case_result.case_name = case_name;
      case_result.true_angles_deg = true_angles_deg;

      result_id += 1;
      results(result_id) = case_result;
      print_case_result(case_result);
      write_case_csv(csv_file, case_result);
    endfor
  unwind_protect_cleanup
    fclose(csv_file);
  end_unwind_protect

  printf("\nResultados guardados en:\n%s\n", output_csv);
endfunction

function result = process_adaptive_case( ...
    signals, mic_positions, true_angles_deg, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(true_angles_deg);
  number_bins = config.frame_length / 2 + 1;
  all_frequencies_hz = (0:number_bins - 1) * ...
                       config.fs / config.frame_length;
  frequency_mask = all_frequencies_hz >= config.min_frequency_hz & ...
                   all_frequencies_hz <= config.max_frequency_hz;
  frequencies_hz = all_frequencies_hz(frequency_mask);
  selected_bins = numel(frequencies_hz);
  maximum_frames = floor(samples / config.frame_hop) - 1;

  spectra.base = zeros(maximum_frames, numel(config.angle_grid_deg));
  spectra.snr = zeros(size(spectra.base));
  spectra.adaptive = zeros(size(spectra.base));
  selected_mask = false(1, maximum_frames);
  mask_valid_history = false(1, maximum_frames);
  active_bins_history = zeros(1, maximum_frames);
  effective_bins_history = zeros(1, maximum_frames);
  mean_weight_history = zeros(1, maximum_frames);
  active_subbands_history = zeros(1, maximum_frames);
  confidence_base_history = NaN(1, maximum_frames);
  confidence_snr_history = NaN(1, maximum_frames);

  frame_buffer = zeros(number_mics, config.frame_length);
  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:config.frame_length - 1) / config.frame_length);
  smoothed_csd = [];
  smoothed_power = [];
  power_history = zeros(config.noise_window_frames, selected_bins);
  history_count = 0;
  history_position = 0;
  frame_id = 0;

  current_mode = config.initial_mode;
  pending_mode = current_mode;
  pending_count = 0;
  switch_count = 0;
  valid_decisions = 0;

  timing.analysis_s = 0;
  timing.dual_das_s = 0;
  timing.decision_s = 0;

  for block_start = 1:config.frame_hop:samples
    block_end = block_start + config.frame_hop - 1;
    if block_end > samples
      break;
    endif

    frame_buffer(:, 1:config.frame_length - config.frame_hop) = ...
        frame_buffer(:, config.frame_hop + 1:config.frame_length);
    frame_buffer(:, config.frame_length - config.frame_hop + 1:end) = ...
        signals(:, block_start:block_end);
    if block_end < config.frame_length
      continue;
    endif
    frame_id += 1;

    timer_id = tic();
    windowed_frame = frame_buffer .* repmat(window, number_mics, 1);
    frame_spectrum = fft(windowed_frame, [], 2);
    frame_spectrum = frame_spectrum(:, 1:number_bins);
    frame_spectrum = frame_spectrum(:, frequency_mask);

    instantaneous_csd = complex(zeros( ...
        number_mics, number_mics, selected_bins));
    for frequency_id = 1:selected_bins
      frequency_vector = frame_spectrum(:, frequency_id);
      instantaneous_csd(:, :, frequency_id) = ...
          frequency_vector * frequency_vector';
    endfor

    current_power = mean(abs(frame_spectrum) .^ 2, 1);
    if isempty(smoothed_csd)
      smoothed_csd = instantaneous_csd;
      smoothed_power = current_power;
    else
      smoothed_csd = config.csd_smoothing * smoothed_csd + ...
          (1 - config.csd_smoothing) * instantaneous_csd;
      smoothed_power = config.power_smoothing * smoothed_power + ...
          (1 - config.power_smoothing) * current_power;
    endif

    history_position = mod(history_position, ...
                           config.noise_window_frames) + 1;
    power_history(history_position, :) = smoothed_power;
    history_count = min(history_count + 1, config.noise_window_frames);
    noise_floor = min(power_history(1:history_count, :), [], 1);
    snr_ratio = smoothed_power ./ (noise_floor + eps);
    threshold_ratio = 10 ^ (config.snr_threshold_db / 10);
    snr_weights = max(0, 1 - threshold_ratio ./ (snr_ratio + eps));

    active_bins = sum(snr_weights > 0);
    effective_bins = (sum(snr_weights) ^ 2) / ...
                     (sum(snr_weights .^ 2) + eps);
    mean_weight = mean(snr_weights);
    active_subbands = count_active_subbands( ...
        frequencies_hz, snr_weights, config);
    mask_valid = active_bins >= config.min_active_bins && ...
                 effective_bins >= config.min_effective_bins && ...
                 mean_weight >= config.min_mean_weight && ...
                 active_subbands >= config.min_active_subbands;

    active_bins_history(frame_id) = active_bins;
    effective_bins_history(frame_id) = effective_bins;
    mean_weight_history(frame_id) = mean_weight;
    active_subbands_history(frame_id) = active_subbands;
    mask_valid_history(frame_id) = mask_valid;
    timing.analysis_s += toc(timer_id);

    timer_id = tic();
    [base_spectrum, snr_spectrum] = evaluate_dual_das( ...
        smoothed_csd, frequencies_hz, snr_weights, ...
        mic_positions, config);
    spectra.base(frame_id, :) = normalize_spectrum(base_spectrum);
    spectra.snr(frame_id, :) = normalize_spectrum(snr_spectrum);
    timing.dual_das_s += toc(timer_id);

    if mod(frame_id, config.decision_interval_frames) == 0 && ...
       frame_id > config.decision_warmup_frames
      timer_id = tic();
      decision_start = max(1, ...
          frame_id - config.decision_history_frames + 1);
      base_decision_spectrum = normalize_spectrum(mean( ...
          spectra.base(decision_start:frame_id, :), 1));
      snr_decision_spectrum = normalize_spectrum(mean( ...
          spectra.snr(decision_start:frame_id, :), 1));
      confidence_base = spatial_confidence( ...
          base_decision_spectrum, number_sources, config);
      confidence_snr = spatial_confidence( ...
          snr_decision_spectrum, number_sources, config);
      confidence_base_history(frame_id) = confidence_base;
      confidence_snr_history(frame_id) = confidence_snr;

      requested_mode = current_mode;
      if mask_valid
        valid_decisions += 1;
        if confidence_snr > ...
            config.mask_confidence_margin * confidence_base
          requested_mode = "snr";
        else
          requested_mode = "base";
        endif
      endif

      if strcmp(requested_mode, current_mode)
        pending_mode = current_mode;
        pending_count = 0;
      else
        if strcmp(requested_mode, pending_mode)
          pending_count += 1;
        else
          pending_mode = requested_mode;
          pending_count = 1;
        endif
        if pending_count >= config.switch_confirmation_decisions
          current_mode = requested_mode;
          pending_mode = current_mode;
          pending_count = 0;
          switch_count += 1;
        endif
      endif
      timing.decision_s += toc(timer_id);
    endif

    selected_mask(frame_id) = strcmp(current_mode, "snr");
    if selected_mask(frame_id)
      spectra.adaptive(frame_id, :) = spectra.snr(frame_id, :);
    else
      spectra.adaptive(frame_id, :) = spectra.base(frame_id, :);
    endif
  endfor

  names = fieldnames(spectra);
  for name_id = 1:numel(names)
    name = names{name_id};
    spectra.(name) = spectra.(name)(1:frame_id, :);
  endfor

  estimates = struct();
  errors = struct();
  base_accumulated = normalize_spectrum(mean(spectra.base, 1));
  snr_accumulated = normalize_spectrum(mean(spectra.snr, 1));
  estimates.base = find_spatial_peaks( ...
      base_accumulated, config.angle_grid_deg, number_sources, ...
      config.min_peak_separation_deg);
  estimates.snr = find_spatial_peaks( ...
      snr_accumulated, config.angle_grid_deg, number_sources, ...
      config.min_peak_separation_deg);
  estimates.adaptive = estimates.(current_mode);

  names = fieldnames(estimates);
  for name_id = 1:numel(names)
    name = names{name_id};
    errors.(name) = match_doa_errors( ...
        true_angles_deg, estimates.(name));
  endfor

  result.estimates_deg = estimates;
  result.errors_deg = errors;
  result.spectra = spectra;
  result.number_frames = frame_id;
  result.selected_mask = selected_mask(1:frame_id);
  result.mask_valid_history = mask_valid_history(1:frame_id);
  result.active_bins_history = active_bins_history(1:frame_id);
  result.effective_bins_history = effective_bins_history(1:frame_id);
  result.mean_weight_history = mean_weight_history(1:frame_id);
  result.active_subbands_history = active_subbands_history(1:frame_id);
  result.confidence_base_history = confidence_base_history(1:frame_id);
  result.confidence_snr_history = confidence_snr_history(1:frame_id);
  result.switch_count = switch_count;
  result.valid_decisions = valid_decisions;
  result.final_mode = current_mode;
  result.timing = timing;
endfunction

function [base_spectrum, snr_spectrum] = evaluate_dual_das( ...
    csd, frequencies_hz, snr_weights, mic_positions, config)

  directions = [
    sind(config.angle_grid_deg);
    cosd(config.angle_grid_deg)
  ];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(mic_positions);
  base_spectrum = zeros(size(config.angle_grid_deg));
  snr_spectrum = zeros(size(config.angle_grid_deg));
  snr_weight_sum = sum(snr_weights) + eps;

  for frequency_id = 1:numel(frequencies_hz)
    steering = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
    steered_covariance = csd(:, :, frequency_id) * steering;
    frequency_power = real(sum( ...
        conj(steering) .* steered_covariance, 1)) / (number_mics ^ 2);
    base_spectrum += frequency_power;
    snr_spectrum += snr_weights(frequency_id) * frequency_power;
  endfor

  base_spectrum /= numel(frequencies_hz);
  snr_spectrum /= snr_weight_sum;
endfunction

function count = count_active_subbands(frequencies_hz, weights, config)
  edges = [300, 800, 1600, 2800, 4000];
  count = 0;
  for band_id = 1:4
    if band_id < 4
      mask = frequencies_hz >= edges(band_id) & ...
             frequencies_hz < edges(band_id + 1);
    else
      mask = frequencies_hz >= edges(band_id) & ...
             frequencies_hz <= edges(band_id + 1);
    endif
    if any(mask) && mean(weights(mask)) >= ...
        config.subband_weight_threshold
      count += 1;
    endif
  endfor
endfunction

function confidence = spatial_confidence( ...
    spectrum, number_sources, config)

  [peak_ids, peak_values] = find_peak_ids( ...
      spectrum, number_sources, config.min_peak_separation_deg);
  if numel(peak_ids) < number_sources
    confidence = 0;
    return;
  endif

  prominences = zeros(1, number_sources);
  for peak_id = 1:number_sources
    index = peak_ids(peak_id);
    radius = round(config.min_peak_separation_deg / 2);
    left_ids = mod(index - 1 - (1:radius), numel(spectrum)) + 1;
    right_ids = mod(index - 1 + (1:radius), numel(spectrum)) + 1;
    local_floor = min([spectrum(left_ids), spectrum(right_ids)]);
    prominences(peak_id) = max(0, spectrum(index) - local_floor);
  endfor

  sorted_values = sort(peak_values, "descend");
  weakest_ratio = sorted_values(end) / (sorted_values(1) + eps);
  confidence = mean(prominences) * (0.5 + 0.5 * weakest_ratio);
endfunction

function [peak_ids, peak_values] = find_peak_ids( ...
    spectrum, number_peaks, minimum_separation_deg)

  candidates = find( ...
      spectrum >= circshift(spectrum, [0, 1]) & ...
      spectrum >= circshift(spectrum, [0, -1]));

  [~, order] = sort(spectrum(candidates), "descend");
  peak_ids = [];
  peak_angles = [];
  for order_id = 1:numel(order)
    candidate_id = candidates(order(order_id));
    candidate_angle = candidate_id - 181;
    if isempty(peak_angles) || all(angular_distance( ...
        candidate_angle, peak_angles) >= minimum_separation_deg)
      peak_ids(end + 1) = candidate_id;
      peak_angles(end + 1) = candidate_angle;
      if numel(peak_ids) == number_peaks
        break;
      endif
    endif
  endfor
  peak_values = spectrum(peak_ids);
endfunction

function write_case_csv(csv_file, result)
  method_names = {"base", "snr", "adaptive"};
  mask_percentage = 100 * mean(result.selected_mask);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    total_per_frame_ms = 1000 * ...
        (result.timing.analysis_s + result.timing.dual_das_s + ...
         result.timing.decision_s) / result.number_frames;
    fprintf(csv_file, ...
        "%s,%s,\"%s\",\"%s\",\"%s\",%.6f,%d,%.3f,%d,%d,", ...
        result.case_name, method_label(method_name), ...
        angle_list_text(result.true_angles_deg), ...
        angle_list_text(result.estimates_deg.(method_name)), ...
        angle_list_text(result.errors_deg.(method_name)), ...
        mean(result.errors_deg.(method_name)), result.number_frames, ...
        mask_percentage, result.switch_count, result.valid_decisions);
    fprintf(csv_file, "%.3f,%.3f,%.6f,%.6f,%.6f,%.6f,%.6f\n", ...
        mean(result.active_bins_history), ...
        mean(result.effective_bins_history), ...
        mean(result.mean_weight_history), ...
        result.timing.analysis_s * 1000, ...
        result.timing.dual_das_s * 1000, ...
        result.timing.decision_s * 1000, total_per_frame_ms);
  endfor
endfunction

function print_case_result(result)
  printf("[OK] %s, reales=%s\n", ...
         result.case_name, mat2str(result.true_angles_deg));
  method_names = {"base", "snr", "adaptive"};
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    printf("     %-18s estimado=%-18s error=%.2f grados\n", ...
           method_label(method_name), ...
           mat2str(result.estimates_deg.(method_name)), ...
           mean(result.errors_deg.(method_name)));
  endfor
  printf(["     mascara=%.1f%%, cambios=%d, decisiones validas=%d, ", ...
          "modo final=%s, bins=%.1f, efectivos=%.1f\n"], ...
         100 * mean(result.selected_mask), result.switch_count, ...
         result.valid_decisions, result.final_mode, ...
         mean(result.active_bins_history), ...
         mean(result.effective_bins_history));
endfunction

function [mic_distance_m, angles_deg] = read_case_info(info_path)
  file_id = fopen(info_path, "r");
  if file_id < 0
    error("No se pudo leer %s", info_path);
  endif
  lines = textscan(file_id, "%s", "delimiter", "\n");
  fclose(file_id);
  lines = lines{1};
  mic_distance_m = str2double(strtrim(lines{1}));
  angles_deg = sscanf(strrep(strjoin(lines(2:end), " "), ",", " "), "%f")';
endfunction

function signals = read_case_signals(case_path, config)
  number_mics = 3;
  available_samples = zeros(1, number_mics);
  for mic_id = 1:number_mics
    wav_path = fullfile(case_path, sprintf("wav_mic%d.wav", mic_id));
    wav_info = audioinfo(wav_path);
    if wav_info.SampleRate != config.fs
      error("Todos los WAV deben estar muestreados a %d Hz.", config.fs);
    endif
    available_samples(mic_id) = wav_info.TotalSamples;
  endfor
  samples = min(min(available_samples), ...
                round(config.segment_duration_s * config.fs));
  first_sample = floor((min(available_samples) - samples) / 2) + 1;
  last_sample = first_sample + samples - 1;
  signals = zeros(number_mics, samples);
  for mic_id = 1:number_mics
    audio = audioread(fullfile( ...
        case_path, sprintf("wav_mic%d.wav", mic_id)), ...
        [first_sample, last_sample]);
    signals(mic_id, :) = audio(:, 1)';
  endfor
endfunction

function positions = aira_microphone_positions(distance_m)
  positions = [
    0, 0;
    -distance_m, 0;
    -distance_m / 2, -sqrt(3) * distance_m / 2
  ];
endfunction

function estimates = find_spatial_peaks( ...
    spectrum, angle_grid_deg, number_peaks, minimum_separation_deg)

  candidates = [];
  samples = numel(spectrum);
  for index = 1:samples
    previous = mod(index - 2, samples) + 1;
    following = mod(index, samples) + 1;
    if spectrum(index) >= spectrum(previous) && ...
       spectrum(index) >= spectrum(following)
      candidates(end + 1) = index;
    endif
  endfor
  [~, order] = sort(spectrum(candidates), "descend");
  estimates = [];
  for order_id = 1:numel(order)
    candidate = angle_grid_deg(candidates(order(order_id)));
    if isempty(estimates) || all( ...
        angular_distance(candidate, estimates) >= minimum_separation_deg)
      estimates(end + 1) = candidate;
      if numel(estimates) == number_peaks
        break;
      endif
    endif
  endfor
  estimates = sort(estimates);
endfunction

function errors = match_doa_errors(true_angles, estimated_angles)
  number_true = numel(true_angles);
  number_estimated = numel(estimated_angles);
  if number_estimated == 0
    errors = 180 * ones(size(true_angles));
    return;
  endif
  if number_estimated >= number_true
    estimate_orders = perms(estimated_angles);
    best_mean = Inf;
    errors = 180 * ones(size(true_angles));
    for order_id = 1:rows(estimate_orders)
      candidate_errors = angular_distance( ...
          true_angles, estimate_orders(order_id, 1:number_true));
      if mean(candidate_errors) < best_mean
        best_mean = mean(candidate_errors);
        errors = candidate_errors;
      endif
    endfor
    return;
  endif
  true_assignments = perms(1:number_true);
  best_mean = Inf;
  errors = 180 * ones(size(true_angles));
  for assignment_id = 1:rows(true_assignments)
    assigned_ids = true_assignments(assignment_id, 1:number_estimated);
    candidate_errors = 180 * ones(size(true_angles));
    candidate_errors(assigned_ids) = angular_distance( ...
        true_angles(assigned_ids), estimated_angles);
    if mean(candidate_errors) < best_mean
      best_mean = mean(candidate_errors);
      errors = candidate_errors;
    endif
  endfor
endfunction

function distances = angular_distance(angle_a, angle_b)
  distances = abs(mod(angle_a - angle_b + 180, 360) - 180);
endfunction

function normalized = normalize_spectrum(spectrum)
  spectrum = real(spectrum);
  spectrum -= min(spectrum);
  normalized = spectrum / (max(spectrum) + eps);
endfunction

function text = angle_list_text(angles)
  if isempty(angles)
    text = "N/A";
  else
    text = strtrim(sprintf("%.2f ", angles));
  endif
endfunction

function label = method_label(method_name)
  switch method_name
    case "base"
      label = "DAS base";
    case "snr"
      label = "DAS + SNR";
    case "adaptive"
      label = "DAS adaptativo";
    otherwise
      label = method_name;
  endswitch
endfunction
