function results = run_wola_localization_corpus(case_names)
%RUN_WOLA_LOCALIZATION_CORPUS Validate block-based localization at 48 kHz.
%
% The input is consumed in blocks of 512 samples. A 1024-sample periodic
% Hann analysis window feeds incremental CSD and PHAT accumulators.
%
% Examples:
%   results = run_wola_localization_corpus();
%   results = run_wola_localization_corpus( ...
%       {"clean-2source", "clean-3source"});
%   results = run_wola_localization_corpus("noisy-3source");

  if nargin < 1 || isempty(case_names)
    case_names = {
      "clean-2source", ...
      "clean-3source", ...
      "noisy-2source", ...
      "noisy-3source"
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
  config.angle_grid_deg = -180:1:179;
  config.coarse_step_deg = 5;
  config.refine_step_deg = 1;
  config.refine_radius_deg = 5;
  config.min_peak_separation_deg = 20;

  localization_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(localization_directory));
  corpus_path = fullfile(project_root, "data", "corpus48000");
  output_csv = fullfile( ...
      localization_directory, "wola_corpus48000_localization_results.csv");

  csv_file = fopen(output_csv, "w");
  if csv_file < 0
    error("No se pudo crear el archivo CSV: %s", output_csv);
  endif

  fprintf(csv_file, ...
      ["caso,fuentes,tramas_wola,metodo,angulos_reales,", ...
       "angulos_estimados,errores_por_fuente_grados,", ...
       "error_medio_grados,procesamiento_bloques_ms,", ...
       "evaluacion_ms\n"]);

  results = struct([]);
  result_id = 0;

  printf("\nValidacion WOLA de localizacion\n");
  printf("fs=%d Hz, ventana=%d, salto=%d, solapamiento=%.0f%%\n", ...
         config.fs, config.frame_length, config.frame_hop, ...
         100 * (1 - config.frame_hop / config.frame_length));
  printf("Corpus: %s\n\n", corpus_path);

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
      if number_sources != 2 && number_sources != 3
        warning(["El caso %s tiene %d fuentes. Esta prueba esta configurada ", ...
                 "para casos de 2 o 3 fuentes; se omite."], ...
                case_name, number_sources);
        continue;
      endif

      signals = read_case_signals(case_path, config);
      mic_positions = aira_microphone_positions(mic_distance_m);

      block_timer = tic();
      state = process_wola_blocks(signals, mic_positions, config);
      block_processing_s = toc(block_timer);

      [spectra, evaluation_times_s] = evaluate_localizers( ...
          state, mic_positions, number_sources, config);

      estimates = struct();
      errors = struct();
      method_names = fieldnames(spectra);
      for method_id = 1:numel(method_names)
        method_name = method_names{method_id};
        estimates.(method_name) = find_spatial_peaks( ...
            spectra.(method_name), config.angle_grid_deg, number_sources, ...
            config.min_peak_separation_deg);
        errors.(method_name) = match_doa_errors( ...
            true_angles_deg, estimates.(method_name));

        fprintf(csv_file, ...
            "%s,%d,%d,%s,\"%s\",\"%s\",\"%s\",%.6f,%.6f,%.6f\n", ...
            case_name, number_sources, state.number_frames, ...
            method_label(method_name), angle_list_text(true_angles_deg), ...
            angle_list_text(estimates.(method_name)), ...
            angle_list_text(errors.(method_name)), ...
            mean(errors.(method_name)), block_processing_s * 1000, ...
            evaluation_times_s.(method_name) * 1000);
      endfor

      result_id += 1;
      results(result_id).case_name = case_name;
      results(result_id).true_angles_deg = true_angles_deg;
      results(result_id).estimates_deg = estimates;
      results(result_id).errors_deg = errors;
      results(result_id).spectra = spectra;
      results(result_id).number_frames = state.number_frames;
      results(result_id).block_processing_time_s = block_processing_s;
      results(result_id).evaluation_times_s = evaluation_times_s;

      print_case_result(results(result_id));
    endfor
  unwind_protect_cleanup
    fclose(csv_file);
  end_unwind_protect

  printf("\nResultados guardados en:\n%s\n", output_csv);
endfunction

function state = process_wola_blocks(signals, mic_positions, config)
  [number_mics, samples] = size(signals);
  frame_length = config.frame_length;
  frame_hop = config.frame_hop;

  if frame_hop > frame_length
    error("El salto WOLA no puede ser mayor que la ventana.");
  endif

  number_bins = frame_length / 2 + 1;
  frequencies_hz = (0:number_bins - 1) * config.fs / frame_length;
  frequency_mask = frequencies_hz >= config.min_frequency_hz & ...
                   frequencies_hz <= config.max_frequency_hz;
  frequencies_hz = frequencies_hz(frequency_mask);
  number_frequencies = numel(frequencies_hz);

  state.frequencies_hz = frequencies_hz;
  state.csd = complex(zeros(number_mics, number_mics, number_frequencies));
  state.pairs = [1, 2; 1, 3; 2, 3];
  state.phat_pairs = complex(zeros(rows(state.pairs), number_frequencies));
  state.multi_pair = [2, 1];
  state.multi_phat = complex(zeros(1, number_frequencies));
  state.number_frames = 0;

  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:frame_length - 1) / frame_length);
  frame_buffer = zeros(number_mics, frame_length);
  buffered_samples = 0;

  for block_start = 1:frame_hop:samples
    block_end = block_start + frame_hop - 1;
    if block_end > samples
      break;
    endif

    frame_buffer(:, 1:frame_length - frame_hop) = ...
        frame_buffer(:, frame_hop + 1:frame_length);
    frame_buffer(:, frame_length - frame_hop + 1:end) = ...
        signals(:, block_start:block_end);
    buffered_samples += frame_hop;

    if buffered_samples < frame_length
      continue;
    endif

    windowed_frame = frame_buffer .* repmat(window, number_mics, 1);
    frame_spectrum = fft(windowed_frame, [], 2);
    frame_spectrum = frame_spectrum(:, 1:number_bins);
    frame_spectrum = frame_spectrum(:, frequency_mask);

    for frequency_id = 1:number_frequencies
      frequency_vector = frame_spectrum(:, frequency_id);
      state.csd(:, :, frequency_id) += ...
          frequency_vector * frequency_vector';
    endfor

    for pair_id = 1:rows(state.pairs)
      mic_a = state.pairs(pair_id, 1);
      mic_b = state.pairs(pair_id, 2);
      cross_spectrum = frame_spectrum(mic_a, :) .* ...
                       conj(frame_spectrum(mic_b, :));
      state.phat_pairs(pair_id, :) += ...
          cross_spectrum ./ (abs(cross_spectrum) + eps);
    endfor

    mic_a = state.multi_pair(1);
    mic_b = state.multi_pair(2);
    cross_spectrum = frame_spectrum(mic_a, :) .* ...
                     conj(frame_spectrum(mic_b, :));
    state.multi_phat += cross_spectrum ./ (abs(cross_spectrum) + eps);
    state.number_frames += 1;
  endfor

  if state.number_frames == 0
    error("La senal no contiene una trama WOLA completa.");
  endif

  state.csd /= state.number_frames;
  state.phat_pairs /= state.number_frames;
  state.multi_phat /= state.number_frames;
endfunction

function [spectra, evaluation_times_s] = evaluate_localizers( ...
    state, mic_positions, number_sources, config)

  timer_id = tic();
  spectra.delay_and_sum = normalize_spectrum(evaluate_delay_and_sum( ...
      state.csd, state.frequencies_hz, mic_positions, ...
      config.angle_grid_deg, config));
  evaluation_times_s.delay_and_sum = toc(timer_id);

  timer_id = tic();
  das_evaluator = @(angles) evaluate_delay_and_sum( ...
      state.csd, state.frequencies_hz, mic_positions, angles, config);
  spectra.delay_and_sum_hierarchical = hierarchical_scan( ...
      das_evaluator, number_sources, config);
  evaluation_times_s.delay_and_sum_hierarchical = toc(timer_id);

  timer_id = tic();
  spectra.srp_phat = normalize_spectrum(evaluate_phat_angles( ...
      state.phat_pairs, state.pairs, state.frequencies_hz, ...
      mic_positions, config.angle_grid_deg, config));
  evaluation_times_s.srp_phat = toc(timer_id);

  timer_id = tic();
  spectra.multi_gcc_phat = zeros(size(config.angle_grid_deg));
  frontal_mask = config.angle_grid_deg >= -90 & ...
                 config.angle_grid_deg <= 90;
  frontal_angles = config.angle_grid_deg(frontal_mask);
  frontal_values = evaluate_phat_angles( ...
      state.multi_phat, state.multi_pair, state.frequencies_hz, ...
      mic_positions, frontal_angles, config);
  spectra.multi_gcc_phat(frontal_mask) = normalize_spectrum(frontal_values);
  evaluation_times_s.multi_gcc_phat = toc(timer_id);
endfunction

function spectrum = evaluate_delay_and_sum( ...
    csd, frequencies_hz, mic_positions, angles_deg, config)

  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(mic_positions);
  spectrum = zeros(1, numel(angles_deg));

  for frequency_id = 1:numel(frequencies_hz)
    steering = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
    covariance = csd(:, :, frequency_id);
    steered_covariance = covariance * steering;
    spectrum += real(sum(conj(steering) .* steered_covariance, 1)) / ...
                (number_mics ^ 2);
  endfor
endfunction

function spectrum = evaluate_phat_angles( ...
    phat_spectra, pairs, frequencies_hz, mic_positions, angles_deg, config)

  if rows(pairs) == 1 && numel(pairs) == 2
    pairs = reshape(pairs, 1, 2);
  endif

  directions = [sind(angles_deg); cosd(angles_deg)];
  spectrum = zeros(1, numel(angles_deg));

  for pair_id = 1:rows(pairs)
    mic_a = pairs(pair_id, 1);
    mic_b = pairs(pair_id, 2);
    baseline = mic_positions(mic_a, :) - mic_positions(mic_b, :);
    predicted_delays_s = -(baseline * directions) / config.sound_speed;
    phase = exp( ...
        1i * 2 * pi * frequencies_hz(:) * predicted_delays_s);
    spectrum += real(phat_spectra(pair_id, :) * phase);
  endfor
endfunction

function spectrum = hierarchical_scan(evaluator, number_sources, config)
  coarse_angles = -180:config.coarse_step_deg: ...
                  (180 - config.coarse_step_deg);
  coarse_values = real(evaluator(coarse_angles));
  coarse_candidates = find_spatial_peaks( ...
      normalize_spectrum(coarse_values), coarse_angles, number_sources, ...
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

function [mic_distance_m, angles_deg] = read_case_info(info_path)
  file_id = fopen(info_path, "r");
  if file_id < 0
    error("No se pudo leer %s", info_path);
  endif
  lines = textscan(file_id, "%s", "delimiter", "\n");
  fclose(file_id);
  lines = lines{1};

  mic_distance_m = str2double(strtrim(lines{1}));
  angle_line = strjoin(lines(2:end), " ");
  angles_deg = sscanf(strrep(angle_line, ",", " "), "%f")';
  if isnan(mic_distance_m) || isempty(angles_deg)
    error("Formato invalido en %s", info_path);
  endif
endfunction

function signals = read_case_signals(case_path, config)
  number_mics = 3;
  sample_rates = zeros(1, number_mics);
  available_samples = zeros(1, number_mics);

  for mic_id = 1:number_mics
    wav_path = fullfile(case_path, sprintf("wav_mic%d.wav", mic_id));
    wav_info = audioinfo(wav_path);
    sample_rates(mic_id) = wav_info.SampleRate;
    available_samples(mic_id) = wav_info.TotalSamples;
  endfor

  if any(sample_rates != config.fs)
    error("Todos los WAV deben estar muestreados a %d Hz.", config.fs);
  endif

  samples = min(min(available_samples), ...
                round(config.segment_duration_s * config.fs));
  total_samples = min(available_samples);
  first_sample = floor((total_samples - samples) / 2) + 1;
  last_sample = first_sample + samples - 1;
  signals = zeros(number_mics, samples);

  for mic_id = 1:number_mics
    wav_path = fullfile(case_path, sprintf("wav_mic%d.wav", mic_id));
    microphone_audio = audioread(wav_path, [first_sample, last_sample]);
    signals(mic_id, :) = microphone_audio(:, 1)';
  endfor
endfunction

function positions = aira_microphone_positions(distance_m)
% Match the coordinate system used to generate and evaluate the corpus.
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
    candidate_angle = angle_grid_deg(candidates(order(order_id)));
    if isempty(estimates) || all(angular_distance( ...
        candidate_angle, estimates) >= minimum_separation_deg)
      estimates(end + 1) = candidate_angle;
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
  if isempty(angles)
    text = "N/A";
  else
    text = strtrim(sprintf("%.2f ", angles));
  endif
endfunction

function label = method_label(method_name)
  switch method_name
    case "delay_and_sum"
      label = "Delay-and-Sum";
    case "delay_and_sum_hierarchical"
      label = "Delay-and-Sum Hierarchical";
    case "srp_phat"
      label = "SRP-PHAT";
    case "multi_gcc_phat"
      label = "Multi-GCC-PHAT";
    otherwise
      label = method_name;
  endswitch
endfunction

function print_case_result(result)
  printf("[OK] %-20s fuentes=%d, tramas=%d, bloques=%.2f ms\n", ...
         result.case_name, numel(result.true_angles_deg), ...
         result.number_frames, result.block_processing_time_s * 1000);

  method_names = fieldnames(result.estimates_deg);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    printf("     %-28s estimado=%-18s error medio=%.2f grados\n", ...
           method_label(method_name), ...
           mat2str(result.estimates_deg.(method_name)), ...
           mean(result.errors_deg.(method_name)));
  endfor
endfunction
