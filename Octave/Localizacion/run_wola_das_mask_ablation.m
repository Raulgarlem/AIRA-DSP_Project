function results = run_wola_das_mask_ablation(case_names)
%RUN_WOLA_DAS_MASK_ABLATION Compare DAS frequency masks and DP tracking.
%
% Variants:
%   1. Unweighted DAS.
%   2. DAS with a causal SNR mask.
%   3. DAS with causal SNR and spatial-coherence masks.
% Each variant is evaluated with accumulated peaks and with Viterbi DP.
%
% Examples:
%   results = run_wola_das_mask_ablation();
%   results = run_wola_das_mask_ablation({"noisy-3source"});

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
  config.max_frequency_hz = 5000;
  config.voice_max_frequency_hz = 4000;
  config.angle_grid_deg = -180:1:179;
  config.min_peak_separation_deg = 20;

  config.csd_smoothing = 0.90;
  config.power_smoothing = 0.70;
  config.noise_window_frames = 30;
  config.snr_threshold_db = 6;
  config.coherence_low = 0.35;
  config.coherence_high = 0.75;
  config.min_active_bins = 8;

  config.temporal_smoothing = 0.50;
  config.dp_warmup_frames = 12;
  config.dp_output_history_frames = 20;
  config.dp_max_step_deg = 8;
  config.dp_transition_weight = 0.06;
  config.dp_suppression_radius_deg = 18;
  config.dp_emission_floor = 0.03;

  localization_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(localization_directory));
  corpus_path = fullfile(project_root, "data", "corpus48000");
  output_csv = fullfile( ...
      localization_directory, "wola_das_mask_ablation_results.csv");

  csv_file = fopen(output_csv, "w");
  if csv_file < 0
    error("No se pudo crear el archivo CSV: %s", output_csv);
  endif
  fprintf(csv_file, ...
      ["caso,metodo,usa_dp,angulos_reales,angulos_estimados,", ...
       "errores_por_fuente_grados,error_medio_grados,tramas,", ...
       "bins_activos_medios,peso_medio,analisis_ms,escaneo_ms,", ...
       "dp_ms,total_por_ventana_ms\n"]);

  printf("\nAblacion DAS: mascara SNR, coherencia y Dynamic Programming\n");
  printf("fs=%d Hz, ventana=%d, salto=%d, banda=%d-%d Hz\n", ...
         config.fs, config.frame_length, config.frame_hop, ...
         config.min_frequency_hz, config.max_frequency_hz);
  printf("Banda de voz para mascaras: %d-%d Hz\n", ...
         config.min_frequency_hz, config.voice_max_frequency_hz);
  printf("Umbral SNR=%.1f dB, coherencia suave=%.2f..%.2f\n\n", ...
         config.snr_threshold_db, config.coherence_low, ...
         config.coherence_high);

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

      [spectra, diagnostics, timing] = calculate_masked_spectra( ...
          signals, mic_positions, config);
      case_result = evaluate_variants( ...
          spectra, diagnostics, timing, true_angles_deg, config);
      case_result.case_name = case_name;
      case_result.true_angles_deg = true_angles_deg;
      case_result.number_frames = rows(spectra.base);

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

function [spectra, diagnostics, timing] = calculate_masked_spectra( ...
    signals, mic_positions, config)

  [number_mics, samples] = size(signals);
  number_bins = config.frame_length / 2 + 1;
  all_frequencies_hz = (0:number_bins - 1) * ...
                       config.fs / config.frame_length;
  frequency_mask = all_frequencies_hz >= config.min_frequency_hz & ...
                   all_frequencies_hz <= config.max_frequency_hz;
  frequencies_hz = all_frequencies_hz(frequency_mask);
  selected_bins = numel(frequencies_hz);
  voice_frequency_mask = ...
      frequencies_hz <= config.voice_max_frequency_hz;
  voice_weights = double(voice_frequency_mask);
  maximum_frames = floor(samples / config.frame_hop) - 1;

  spectra.wideband = zeros(maximum_frames, numel(config.angle_grid_deg));
  spectra.base = zeros(size(spectra.wideband));
  spectra.snr = zeros(size(spectra.base));
  spectra.snr_coherence = zeros(size(spectra.base));
  diagnostics.snr_active_bins = zeros(1, maximum_frames);
  diagnostics.coherence_active_bins = zeros(1, maximum_frames);
  diagnostics.snr_mean_weight = zeros(1, maximum_frames);
  diagnostics.coherence_mean_weight = zeros(1, maximum_frames);
  diagnostics.total_frequency_bins = ...
      sum(voice_frequency_mask) * ones(1, maximum_frames);

  frame_buffer = zeros(number_mics, config.frame_length);
  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:config.frame_length - 1) / config.frame_length);
  smoothed_csd = [];
  smoothed_power = [];
  power_history = zeros(config.noise_window_frames, selected_bins);
  history_count = 0;
  history_position = 0;
  frame_id = 0;

  timing.analysis_s = 0;
  timing.wideband_scan_s = 0;
  timing.base_scan_s = 0;
  timing.snr_scan_s = 0;
  timing.snr_coherence_scan_s = 0;

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
    snr_weights .*= voice_weights;
    snr_scores = snr_ratio;
    snr_scores(!voice_frequency_mask) = -Inf;
    snr_weights = ensure_minimum_bins( ...
        snr_weights, snr_scores, config.min_active_bins);

    coherence = mean_pair_coherence(smoothed_csd);
    coherence_weights = clamp( ...
        (coherence - config.coherence_low) / ...
        (config.coherence_high - config.coherence_low), 0, 1);
    combined_weights = snr_weights .* coherence_weights;
    combined_scores = snr_ratio .* max(coherence, eps);
    combined_scores(!voice_frequency_mask) = -Inf;
    combined_weights = ensure_minimum_bins( ...
        combined_weights, combined_scores, config.min_active_bins);

    diagnostics.snr_active_bins(frame_id) = sum(snr_weights > 0);
    diagnostics.coherence_active_bins(frame_id) = ...
        sum(combined_weights > 0);
    diagnostics.snr_mean_weight(frame_id) = mean(snr_weights);
    diagnostics.coherence_mean_weight(frame_id) = mean(combined_weights);
    timing.analysis_s += toc(timer_id);

    timer_id = tic();
    spectra.wideband(frame_id, :) = normalize_spectrum( ...
        evaluate_weighted_das(smoothed_csd, frequencies_hz, ...
        ones(1, selected_bins), mic_positions, config));
    timing.wideband_scan_s += toc(timer_id);

    timer_id = tic();
    spectra.base(frame_id, :) = normalize_spectrum(evaluate_weighted_das( ...
        smoothed_csd, frequencies_hz, voice_weights, ...
        mic_positions, config));
    timing.base_scan_s += toc(timer_id);

    timer_id = tic();
    spectra.snr(frame_id, :) = normalize_spectrum(evaluate_weighted_das( ...
        smoothed_csd, frequencies_hz, snr_weights, ...
        mic_positions, config));
    timing.snr_scan_s += toc(timer_id);

    timer_id = tic();
    spectra.snr_coherence(frame_id, :) = normalize_spectrum( ...
        evaluate_weighted_das(smoothed_csd, frequencies_hz, ...
        combined_weights, mic_positions, config));
    timing.snr_coherence_scan_s += toc(timer_id);
  endfor

  variant_names = fieldnames(spectra);
  for variant_id = 1:numel(variant_names)
    variant_name = variant_names{variant_id};
    spectra.(variant_name) = spectra.(variant_name)(1:frame_id, :);
  endfor
  diagnostic_names = fieldnames(diagnostics);
  for diagnostic_id = 1:numel(diagnostic_names)
    diagnostic_name = diagnostic_names{diagnostic_id};
    diagnostics.(diagnostic_name) = ...
        diagnostics.(diagnostic_name)(1:frame_id);
  endfor
endfunction

function result = evaluate_variants( ...
    spectra, diagnostics, timing, true_angles_deg, config)

  number_sources = numel(true_angles_deg);
  variant_names = {"wideband", "base", "snr", "snr_coherence"};
  estimates = struct();
  errors = struct();
  tracks = struct();

  for variant_id = 1:numel(variant_names)
    variant_name = variant_names{variant_id};
    variant_spectra = spectra.(variant_name);
    accumulated = normalize_spectrum(mean(variant_spectra, 1));
    estimates.(variant_name) = find_spatial_peaks( ...
        accumulated, config.angle_grid_deg, number_sources, ...
        config.min_peak_separation_deg);

    smoothed = smooth_temporal_spectra( ...
        variant_spectra, config.temporal_smoothing);
    timer_id = tic();
    tracks.([variant_name, "_dp"]) = extract_dp_tracks( ...
        smoothed(config.dp_warmup_frames + 1:end, :), ...
        number_sources, config);
    timing.([variant_name, "_dp_s"]) = toc(timer_id);
    estimates.([variant_name, "_dp"]) = track_angles( ...
        tracks.([variant_name, "_dp"]), ...
        config.dp_output_history_frames);
  endfor

  method_names = fieldnames(estimates);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    errors.(method_name) = match_doa_errors( ...
        true_angles_deg, estimates.(method_name));
  endfor

  result.estimates_deg = estimates;
  result.errors_deg = errors;
  result.tracks_deg = tracks;
  result.spectra = spectra;
  result.diagnostics = diagnostics;
  result.timing = timing;
endfunction

function spectrum = evaluate_weighted_das( ...
    csd, frequencies_hz, weights, mic_positions, config)

  directions = [
    sind(config.angle_grid_deg);
    cosd(config.angle_grid_deg)
  ];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(mic_positions);
  spectrum = zeros(size(config.angle_grid_deg));
  weight_sum = sum(weights) + eps;

  for frequency_id = 1:numel(frequencies_hz)
    if weights(frequency_id) <= 0
      continue;
    endif
    steering = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
    steered_covariance = csd(:, :, frequency_id) * steering;
    frequency_power = real(sum( ...
        conj(steering) .* steered_covariance, 1)) / (number_mics ^ 2);
    spectrum += weights(frequency_id) * frequency_power;
  endfor
  spectrum /= weight_sum;
endfunction

function coherence = mean_pair_coherence(csd)
  pairs = [1, 2; 1, 3; 2, 3];
  number_bins = size(csd, 3);
  coherence = zeros(1, number_bins);
  for pair_id = 1:rows(pairs)
    mic_a = pairs(pair_id, 1);
    mic_b = pairs(pair_id, 2);
    cross_power = reshape(csd(mic_a, mic_b, :), 1, number_bins);
    auto_a = real(reshape(csd(mic_a, mic_a, :), 1, number_bins));
    auto_b = real(reshape(csd(mic_b, mic_b, :), 1, number_bins));
    pair_coherence = abs(cross_power) .^ 2 ./ ...
                     (auto_a .* auto_b + eps);
    coherence += clamp(real(pair_coherence), 0, 1);
  endfor
  coherence /= rows(pairs);
endfunction

function weights = ensure_minimum_bins(weights, scores, minimum_bins)
  if sum(weights > 0) >= minimum_bins
    return;
  endif
  [~, order] = sort(scores, "descend");
  selected = order(1:min(minimum_bins, numel(order)));
  weights(selected) = max(weights(selected), 0.05);
endfunction

function values = clamp(values, lower_bound, upper_bound)
  values = min(max(values, lower_bound), upper_bound);
endfunction

function smoothed = smooth_temporal_spectra(spectra, alpha)
  smoothed = spectra;
  for frame_id = 2:rows(spectra)
    smoothed(frame_id, :) = alpha * smoothed(frame_id - 1, :) + ...
                            (1 - alpha) * spectra(frame_id, :);
    smoothed(frame_id, :) = normalize_spectrum(smoothed(frame_id, :));
  endfor
endfunction

function tracks = extract_dp_tracks(spectra, number_sources, config)
  working_spectra = max(spectra, config.dp_emission_floor);
  tracks = zeros(number_sources, rows(spectra));
  for source_id = 1:number_sources
    tracks(source_id, :) = viterbi_angle_track(working_spectra, config);
    for frame_id = 1:rows(working_spectra)
      distances = angular_distance( ...
          config.angle_grid_deg, tracks(source_id, frame_id));
      suppression = exp( ...
          -0.5 * (distances / config.dp_suppression_radius_deg) .^ 2);
      working_spectra(frame_id, :) .*= (1 - 0.97 * suppression);
      working_spectra(frame_id, :) = max( ...
          working_spectra(frame_id, :), config.dp_emission_floor);
    endfor
  endfor
endfunction

function track = viterbi_angle_track(spectra, config)
  [number_frames, number_angles] = size(spectra);
  costs = -log(max(spectra, config.dp_emission_floor));
  accumulated = costs(1, :);
  backpointer = zeros(number_frames, number_angles);
  offsets = -config.dp_max_step_deg:config.dp_max_step_deg;
  angle_ids = 1:number_angles;
  previous_id_table = zeros(numel(offsets), number_angles);
  transition_costs = zeros(numel(offsets), 1);

  for offset_id = 1:numel(offsets)
    previous_id_table(offset_id, :) = mod( ...
        angle_ids - 1 + offsets(offset_id), number_angles) + 1;
    transition_costs(offset_id) = config.dp_transition_weight * ...
                                  offsets(offset_id) ^ 2;
  endfor

  for frame_id = 2:number_frames
    candidate_costs = accumulated(previous_id_table) + ...
                      repmat(transition_costs, 1, number_angles);
    [best_costs, best_offset_ids] = min(candidate_costs, [], 1);
    accumulated = costs(frame_id, :) + best_costs;
    selected_ids = sub2ind( ...
        size(previous_id_table), best_offset_ids, angle_ids);
    backpointer(frame_id, :) = previous_id_table(selected_ids);
  endfor

  [~, angle_id] = min(accumulated);
  track_ids = zeros(1, number_frames);
  track_ids(end) = angle_id;
  for frame_id = number_frames:-1:2
    track_ids(frame_id - 1) = backpointer(frame_id, track_ids(frame_id));
  endfor
  track = config.angle_grid_deg(track_ids);
endfunction

function estimates = track_angles(tracks, history_frames)
  first_frame = max(1, columns(tracks) - history_frames + 1);
  estimates = zeros(1, rows(tracks));
  for source_id = 1:rows(tracks)
    recent_track = tracks(source_id, first_frame:end);
    angles_rad = recent_track * pi / 180;
    center_deg = atan2(mean(sin(angles_rad)), ...
                       mean(cos(angles_rad))) * 180 / pi;
    unwrapped = center_deg + mod( ...
        recent_track - center_deg + 180, 360) - 180;
    estimates(source_id) = wrap_angles(round(median(unwrapped)));
  endfor
  estimates = sort(estimates);
endfunction

function write_case_csv(csv_file, result)
  method_names = fieldnames(result.estimates_deg);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    uses_dp = length(method_name) >= 3 && ...
              strcmp(method_name(end - 2:end), "_dp");
    variant_name = strrep(method_name, "_dp", "");
    scan_field = [variant_name, "_scan_s"];
    dp_s = 0;
    if uses_dp
      dp_s = result.timing.([variant_name, "_dp_s"]);
    endif

    if strcmp(variant_name, "base") || strcmp(variant_name, "wideband")
      active_bins = NaN;
      mean_weight = 1;
    elseif strcmp(variant_name, "snr")
      active_bins = mean(result.diagnostics.snr_active_bins);
      mean_weight = mean(result.diagnostics.snr_mean_weight);
    else
      active_bins = mean(result.diagnostics.coherence_active_bins);
      mean_weight = mean(result.diagnostics.coherence_mean_weight);
    endif

    total_per_frame_ms = 1000 * ...
        (result.timing.analysis_s + result.timing.(scan_field) + dp_s) / ...
        result.number_frames;
    fprintf(csv_file, ...
        "%s,%s,%d,\"%s\",\"%s\",\"%s\",%.6f,%d,%.3f,%.6f,", ...
        result.case_name, method_label(method_name), uses_dp, ...
        angle_list_text(result.true_angles_deg), ...
        angle_list_text(result.estimates_deg.(method_name)), ...
        angle_list_text(result.errors_deg.(method_name)), ...
        mean(result.errors_deg.(method_name)), result.number_frames, ...
        active_bins, mean_weight);
    fprintf(csv_file, "%.6f,%.6f,%.6f,%.6f\n", ...
        result.timing.analysis_s * 1000, ...
        result.timing.(scan_field) * 1000, dp_s * 1000, ...
        total_per_frame_ms);
  endfor
endfunction

function print_case_result(result)
  printf("[OK] %s, reales=%s\n", ...
         result.case_name, mat2str(result.true_angles_deg));
  method_names = fieldnames(result.estimates_deg);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    printf("     %-28s estimado=%-18s error=%.2f grados\n", ...
           method_label(method_name), ...
           mat2str(result.estimates_deg.(method_name)), ...
           mean(result.errors_deg.(method_name)));
  endfor
  printf("     bins SNR=%.1f, bins SNR+coh=%.1f de %d\n", ...
         mean(result.diagnostics.snr_active_bins), ...
         mean(result.diagnostics.coherence_active_bins), ...
         result.diagnostics.total_frequency_bins(1));
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

function wrapped = wrap_angles(angles_deg)
  wrapped = mod(angles_deg + 180, 360) - 180;
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
    case "wideband"
      label = "DAS 300-5000 Hz";
    case "wideband_dp"
      label = "DAS 300-5000 Hz + DP";
    case "base"
      label = "DAS 300-4000 Hz";
    case "base_dp"
      label = "DAS 300-4000 Hz + DP";
    case "snr"
      label = "DAS + SNR";
    case "snr_dp"
      label = "DAS + SNR + DP";
    case "snr_coherence"
      label = "DAS + SNR + coherencia";
    case "snr_coherence_dp"
      label = "DAS + SNR + coherencia + DP";
    otherwise
      label = method_name;
  endswitch
endfunction
