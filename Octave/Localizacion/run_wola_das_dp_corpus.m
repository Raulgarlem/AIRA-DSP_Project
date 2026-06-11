function results = run_wola_das_dp_corpus(case_names)
%RUN_WOLA_DAS_DP_CORPUS Track DAS directions with dynamic programming.
%
% Each 1024-sample WOLA frame produces a spatial spectrum. Viterbi dynamic
% programming connects likely angles over time and extracts one trajectory
% per expected source.
%
% Examples:
%   results = run_wola_das_dp_corpus();
%   results = run_wola_das_dp_corpus( ...
%       {"clean-3source", "noisy-3source"});

  if nargin < 1 || isempty(case_names)
    case_names = {"clean-3source", "noisy-3source"};
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
  config.angle_grid_deg = -180:1:179;
  config.coarse_step_deg = 5;
  config.refine_step_deg = 1;
  config.refine_radius_deg = 5;
  config.hierarchical_candidate_factor = 2;
  config.min_peak_separation_deg = 20;
  config.dp_max_step_deg = 8;
  config.dp_transition_weight = 0.06;
  config.dp_suppression_radius_deg = 18;
  config.dp_emission_floor = 0.03;
  config.csd_smoothing = 0.90;
  config.temporal_smoothing = 0.50;
  config.dp_warmup_frames = 12;
  config.dp_output_history_frames = 20;

  localization_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(localization_directory));
  corpus_path = fullfile(project_root, "data", "corpus48000");
  output_csv = fullfile( ...
      localization_directory, "wola_das_dp_corpus48000_results.csv");

  csv_file = fopen(output_csv, "w");
  if csv_file < 0
    error("No se pudo crear el archivo CSV: %s", output_csv);
  endif
  fprintf(csv_file, ...
      ["caso,fuentes,tramas,metodo,angulos_reales,angulos_estimados,", ...
       "errores_por_fuente_grados,error_medio_grados,", ...
       "analisis_wola_ms,escaneo_total_ms,dp_total_ms,", ...
       "tiempo_total_por_ventana_ms\n"]);

  results = struct([]);
  result_id = 0;

  printf("\nDelay-and-Sum con Dynamic Programming\n");
  printf("fs=%d Hz, ventana=%d, salto=%d, max DP=%d grados/ventana\n\n", ...
         config.fs, config.frame_length, config.frame_hop, ...
         config.dp_max_step_deg);

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
      number_sources = numel(true_angles_deg);
      signals = read_case_signals(case_path, config);
      mic_positions = aira_microphone_positions(mic_distance_m);

      [full_spectra, hierarchical_spectra, timing] = ...
          calculate_temporal_spectra(signals, mic_positions, ...
                                     number_sources, config);

      case_result = evaluate_temporal_methods( ...
          full_spectra, hierarchical_spectra, true_angles_deg, ...
          timing, config);
      case_result.case_name = case_name;
      case_result.true_angles_deg = true_angles_deg;
      case_result.number_frames = rows(full_spectra);

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

function [full_spectra, hierarchical_spectra, timing] = ...
    calculate_temporal_spectra(signals, mic_positions, ...
                               number_sources, config)

  [number_mics, samples] = size(signals);
  number_bins = config.frame_length / 2 + 1;
  all_frequencies_hz = (0:number_bins - 1) * ...
                       config.fs / config.frame_length;
  frequency_mask = all_frequencies_hz >= config.min_frequency_hz & ...
                   all_frequencies_hz <= config.max_frequency_hz;
  frequencies_hz = all_frequencies_hz(frequency_mask);
  number_frames = floor(samples / config.frame_hop) - 1;

  full_spectra = zeros(number_frames, numel(config.angle_grid_deg));
  hierarchical_spectra = zeros(size(full_spectra));
  frame_buffer = zeros(number_mics, config.frame_length);
  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:config.frame_length - 1) / config.frame_length);

  analysis_time_s = 0;
  full_scan_time_s = 0;
  hierarchical_scan_time_s = 0;
  frame_id = 0;
  smoothed_csd = [];

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
    csd = complex(zeros(number_mics, number_mics, numel(frequencies_hz)));
    for frequency_id = 1:numel(frequencies_hz)
      frequency_vector = frame_spectrum(:, frequency_id);
      csd(:, :, frequency_id) = frequency_vector * frequency_vector';
    endfor
    if isempty(smoothed_csd)
      smoothed_csd = csd;
    else
      smoothed_csd = config.csd_smoothing * smoothed_csd + ...
                     (1 - config.csd_smoothing) * csd;
    endif
    analysis_time_s += toc(timer_id);

    timer_id = tic();
    full_spectra(frame_id, :) = normalize_spectrum(evaluate_das( ...
        smoothed_csd, frequencies_hz, mic_positions, ...
        config.angle_grid_deg, config));
    full_scan_time_s += toc(timer_id);

    timer_id = tic();
    evaluator = @(angles) evaluate_das( ...
        smoothed_csd, frequencies_hz, mic_positions, angles, config);
    hierarchical_spectra(frame_id, :) = hierarchical_frame_scan( ...
        evaluator, number_sources, config);
    hierarchical_scan_time_s += toc(timer_id);
  endfor

  full_spectra = full_spectra(1:frame_id, :);
  hierarchical_spectra = hierarchical_spectra(1:frame_id, :);
  timing.analysis_s = analysis_time_s;
  timing.full_scan_s = full_scan_time_s;
  timing.hierarchical_scan_s = hierarchical_scan_time_s;
endfunction

function result = evaluate_temporal_methods( ...
    full_spectra, hierarchical_spectra, true_angles_deg, timing, config)

  number_sources = numel(true_angles_deg);
  full_smoothed = smooth_temporal_spectra( ...
      full_spectra, config.temporal_smoothing);
  hierarchical_smoothed = smooth_temporal_spectra( ...
      hierarchical_spectra, config.temporal_smoothing);

  accumulated_full = normalize_spectrum(mean(full_spectra, 1));
  accumulated_hierarchical = normalize_spectrum( ...
      mean(hierarchical_spectra, 1));

  estimates.delay_and_sum = find_spatial_peaks( ...
      accumulated_full, config.angle_grid_deg, number_sources, ...
      config.min_peak_separation_deg);
  estimates.delay_and_sum_hierarchical = find_spatial_peaks( ...
      accumulated_hierarchical, config.angle_grid_deg, number_sources, ...
      config.min_peak_separation_deg);

  timer_id = tic();
  tracks.delay_and_sum_dp = extract_dp_tracks( ...
      full_smoothed(config.dp_warmup_frames + 1:end, :), ...
      number_sources, config);
  timing.full_dp_s = toc(timer_id);

  timer_id = tic();
  tracks.delay_and_sum_hierarchical_dp = extract_dp_tracks( ...
      hierarchical_smoothed(config.dp_warmup_frames + 1:end, :), ...
      number_sources, config);
  timing.hierarchical_dp_s = toc(timer_id);

  estimates.delay_and_sum_dp = track_angles( ...
      tracks.delay_and_sum_dp, config.dp_output_history_frames);
  estimates.delay_and_sum_hierarchical_dp = track_angles( ...
      tracks.delay_and_sum_hierarchical_dp, ...
      config.dp_output_history_frames);

  method_names = fieldnames(estimates);
  errors = struct();
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    errors.(method_name) = match_doa_errors( ...
        true_angles_deg, estimates.(method_name));
  endfor

  result.estimates_deg = estimates;
  result.errors_deg = errors;
  result.tracks_deg = tracks;
  result.temporal_spectra.delay_and_sum = full_spectra;
  result.temporal_spectra.delay_and_sum_hierarchical = ...
      hierarchical_spectra;
  result.timing = timing;
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
  max_step = round(config.dp_max_step_deg);
  offsets = -max_step:max_step;
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
    previous_cost = accumulated;
    candidate_costs = previous_cost(previous_id_table) + ...
                      repmat(transition_costs, 1, number_angles);
    [best_costs, best_offset_ids] = min(candidate_costs, [], 1);
    accumulated = costs(frame_id, :) + best_costs;
    selected_linear_ids = sub2ind( ...
        size(previous_id_table), best_offset_ids, angle_ids);
    backpointer(frame_id, :) = previous_id_table(selected_linear_ids);
  endfor

  [~, angle_id] = min(accumulated);
  track_ids = zeros(1, number_frames);
  track_ids(number_frames) = angle_id;
  for frame_id = number_frames:-1:2
    track_ids(frame_id - 1) = backpointer(frame_id, track_ids(frame_id));
  endfor
  track = config.angle_grid_deg(track_ids);
endfunction

function estimates = track_angles(tracks, history_frames)
  if nargin < 2
    history_frames = columns(tracks);
  endif
  first_frame = max(1, columns(tracks) - history_frames + 1);
  estimates = zeros(1, rows(tracks));
  for source_id = 1:rows(tracks)
    recent_track = tracks(source_id, first_frame:end);
    angles_rad = recent_track * pi / 180;
    mean_angle = atan2(mean(sin(angles_rad)), mean(cos(angles_rad)));
    center_deg = mean_angle * 180 / pi;
    unwrapped = center_deg + mod( ...
        recent_track - center_deg + 180, 360) - 180;
    estimates(source_id) = wrap_angles(round(median(unwrapped)));
  endfor
  estimates = sort(estimates);
endfunction

function spectrum = hierarchical_frame_scan( ...
    evaluator, number_sources, config)

  coarse_angles = -180:config.coarse_step_deg: ...
                  (180 - config.coarse_step_deg);
  coarse_values = real(evaluator(coarse_angles));
  number_candidates = min( ...
      numel(coarse_angles), ...
      config.hierarchical_candidate_factor * number_sources);
  coarse_candidates = find_spatial_peaks( ...
      normalize_spectrum(coarse_values), coarse_angles, number_candidates, ...
      config.min_peak_separation_deg);

  refine_angles = [];
  for candidate = coarse_candidates
    local_angles = candidate - config.refine_radius_deg: ...
                   config.refine_step_deg: ...
                   candidate + config.refine_radius_deg;
    refine_angles = [refine_angles, wrap_angles(local_angles)];
  endfor
  refine_angles = unique(refine_angles);

  evaluated_angles = coarse_angles;
  evaluated_values = coarse_values;
  if !isempty(refine_angles)
    evaluated_angles = [evaluated_angles, refine_angles];
    evaluated_values = [evaluated_values, real(evaluator(refine_angles))];
  endif

  [evaluated_angles, unique_ids] = unique(evaluated_angles);
  evaluated_values = evaluated_values(unique_ids);
  periodic_angles = [evaluated_angles - 360, evaluated_angles, ...
                     evaluated_angles + 360];
  periodic_values = [evaluated_values, evaluated_values, evaluated_values];
  spectrum = interp1(periodic_angles, periodic_values, ...
                     config.angle_grid_deg, "linear");
  spectrum = normalize_spectrum(real(spectrum));
endfunction

function spectrum = evaluate_das( ...
    csd, frequencies_hz, mic_positions, angles_deg, config)

  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(mic_positions);
  spectrum = zeros(1, numel(angles_deg));

  for frequency_id = 1:numel(frequencies_hz)
    steering = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
    steered_covariance = csd(:, :, frequency_id) * steering;
    spectrum += real(sum(conj(steering) .* steered_covariance, 1)) / ...
                (number_mics ^ 2);
  endfor
endfunction

function write_case_csv(csv_file, result)
  method_names = fieldnames(result.estimates_deg);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    if strcmp(method_name, "delay_and_sum") || ...
       strcmp(method_name, "delay_and_sum_dp")
      scan_s = result.timing.full_scan_s;
    else
      scan_s = result.timing.hierarchical_scan_s;
    endif

    if strcmp(method_name, "delay_and_sum_dp")
      dp_s = result.timing.full_dp_s;
    elseif strcmp(method_name, "delay_and_sum_hierarchical_dp")
      dp_s = result.timing.hierarchical_dp_s;
    else
      dp_s = 0;
    endif

    total_per_frame_ms = 1000 * ...
        (result.timing.analysis_s + scan_s + dp_s) / result.number_frames;
    fprintf(csv_file, ...
        "%s,%d,%d,%s,\"%s\",\"%s\",\"%s\",%.6f,%.6f,%.6f,%.6f,%.6f\n", ...
        result.case_name, numel(result.true_angles_deg), ...
        result.number_frames, method_label(method_name), ...
        angle_list_text(result.true_angles_deg), ...
        angle_list_text(result.estimates_deg.(method_name)), ...
        angle_list_text(result.errors_deg.(method_name)), ...
        mean(result.errors_deg.(method_name)), ...
        result.timing.analysis_s * 1000, scan_s * 1000, dp_s * 1000, ...
        total_per_frame_ms);
  endfor
endfunction

function print_case_result(result)
  printf("[OK] %s: %d ventanas, reales=%s\n", ...
         result.case_name, result.number_frames, ...
         mat2str(result.true_angles_deg));
  method_names = fieldnames(result.estimates_deg);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    printf("     %-36s estimado=%-18s error=%.2f grados\n", ...
           method_label(method_name), ...
           mat2str(result.estimates_deg.(method_name)), ...
           mean(result.errors_deg.(method_name)));
  endfor
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
    wav_info = audioinfo(fullfile( ...
        case_path, sprintf("wav_mic%d.wav", mic_id)));
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
      candidate = estimate_orders(order_id, 1:number_true);
      candidate_errors = angular_distance(true_angles, candidate);
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
  text = strtrim(sprintf("%.2f ", angles));
endfunction

function label = method_label(method_name)
  switch method_name
    case "delay_and_sum"
      label = "Delay-and-Sum";
    case "delay_and_sum_dp"
      label = "Delay-and-Sum + DP";
    case "delay_and_sum_hierarchical"
      label = "Delay-and-Sum Hierarchical";
    case "delay_and_sum_hierarchical_dp"
      label = "Delay-and-Sum Hierarchical + DP";
    otherwise
      label = method_name;
  endswitch
endfunction
