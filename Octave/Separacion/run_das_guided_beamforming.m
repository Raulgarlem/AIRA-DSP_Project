function results = run_das_guided_beamforming(case_names)
%RUN_DAS_GUIDED_BEAMFORMING Compare beamformers using adaptive DAS DOAs.
%
% Methods from slide 49 of 07.2-Beamforming:
%   - MVDR
%   - LCMV
%   - GSC with fixed LMS step
%   - GSC with dynamic LMS step
%   - Phase-based frequency masking
%
% A conventional DAS output is included as a baseline. Source directions
% are obtained directly from run_wola_das_adaptive_mask.

  pkg load signal;

  if nargin < 1 || isempty(case_names)
    case_names = {"clean-3source"};
  elseif ischar(case_names)
    case_names = {case_names};
  endif

  config.fs = 48000;
  config.segment_duration_s = 1.0;
  config.sound_speed = 343;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.mvdr_diagonal_loading = 1e-2;
  config.lcmv_diagonal_loading = 1e-2;
  config.lcmv_null_width_deg = 5;
  config.lcmv_min_rcond = 1e-5;
  config.lcmv_max_weight_norm = 4;
  config.gsc_filter_length = 32;
  config.gsc_fixed_mu = 5e-4;
  config.gsc_mu0 = 1e-3;
  config.gsc_mu_max = 5e-4;
  config.gsc_leakage = 1e-6;
  config.phase_threshold_deg = 25;
  config.phase_mask_floor = 0;
  config.evaluation_max_delay_s = 0.10;
  config.write_audio = true;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  localization_directory = fullfile(project_root, "Octave", "Localizacion");
  corpus_path = fullfile(project_root, "data", "corpus48000");
  output_csv = fullfile( ...
      separation_directory, "das_guided_beamforming_results.csv");
  localization_csv = fullfile( ...
      separation_directory, "das_guided_localization_results.csv");
  addpath(localization_directory);

  printf("\nLocalizacion DAS adaptativa para separacion\n");
  localization_results = run_wola_das_adaptive_mask( ...
      case_names, localization_csv);
  if isempty(localization_results)
    warning("El localizador no produjo resultados.");
    results = struct([]);
    return;
  endif

  csv_file = fopen(output_csv, "w");
  if csv_file < 0
    error("No se pudo crear el archivo CSV: %s", output_csv);
  endif
  fprintf(csv_file, ...
      ["caso,metodo,fuente,angulo_real,angulo_estimado,error_doa_grados,", ...
       "si_sdr_db,si_sdri_db,correlacion,tiempo_separacion_ms\n"]);

  printf("\nComparacion de beamforming guiada por DAS adaptativo\n");
  printf("Ventana=%d, salto=%d, segmento=%.1f s\n\n", ...
         config.frame_length, config.frame_hop, ...
         config.segment_duration_s);

  results = struct([]);
  result_id = 0;
  unwind_protect
    for localization_id = 1:numel(localization_results)
      localization_result = localization_results(localization_id);
      case_name = localization_result.case_name;
      case_path = fullfile(corpus_path, case_name);
      true_angles_deg = localization_result.true_angles_deg;
      estimated_angles_deg = ...
          localization_result.estimates_deg.adaptive;

      if numel(estimated_angles_deg) != numel(true_angles_deg)
        warning(["%s produjo %d DOAs para %d fuentes; ", ...
                 "se omite la separacion."], ...
                case_name, numel(estimated_angles_deg), ...
                numel(true_angles_deg));
        continue;
      endif

      [mic_distance_m, ~] = read_case_info( ...
          fullfile(case_path, "info.txt"));
      [signals, references] = read_case_audio( ...
          case_path, numel(true_angles_deg), config);
      mic_positions = aira_microphone_positions(mic_distance_m);

      case_result = process_case( ...
          signals, references, mic_positions, true_angles_deg, ...
          estimated_angles_deg, config);
      case_result.case_name = case_name;
      case_result.localization_mode = localization_result.final_mode;

      if config.write_audio
        output_directory = fullfile( ...
            separation_directory, "results", ...
            [case_name, "_das_guided"]);
        write_case_audio(output_directory, case_result, config.fs);
      endif

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

function result = process_case( ...
    signals, references, mic_positions, true_angles_deg, ...
    estimated_angles_deg, config)

  methods = {
    "das", ...
    "mvdr", ...
    "lcmv", ...
    "gsc_fixed", ...
    "gsc_dynamic", ...
    "phase_mask"
  };
  estimates = struct();
  metrics = struct();
  timing = struct();
  covariance = estimate_frequency_covariance(signals, config);

  for method_id = 1:numel(methods)
    method_name = methods{method_id};
    timer_id = tic();
    switch method_name
      case "das"
        output = apply_frequency_beamformer( ...
            signals, estimated_angles_deg, mic_positions, ...
            covariance, "das", config);
      case "mvdr"
        output = apply_frequency_beamformer( ...
            signals, estimated_angles_deg, mic_positions, ...
            covariance, "mvdr", config);
      case "lcmv"
        output = apply_frequency_beamformer( ...
            signals, estimated_angles_deg, mic_positions, ...
            covariance, "lcmv", config);
      case "gsc_fixed"
        output = apply_gsc( ...
            signals, estimated_angles_deg, mic_positions, false, config);
      case "gsc_dynamic"
        output = apply_gsc( ...
            signals, estimated_angles_deg, mic_positions, true, config);
      case "phase_mask"
        output = apply_phase_frequency_mask( ...
            signals, estimated_angles_deg, mic_positions, config);
    endswitch
    timing.(method_name) = toc(timer_id);
    estimates.(method_name) = output;
    metrics.(method_name) = evaluate_estimates( ...
        output, references, signals(1, :), estimated_angles_deg, ...
        true_angles_deg, config);
  endfor

  result.true_angles_deg = true_angles_deg;
  result.estimated_angles_deg = estimated_angles_deg;
  result.estimates = estimates;
  result.metrics = metrics;
  result.timing = timing;
endfunction

function covariance = estimate_frequency_covariance(signals, config)
  [number_mics, samples] = size(signals);
  number_bins = config.frame_length / 2 + 1;
  frame_starts = 1:config.frame_hop:(samples - config.frame_length + 1);
  window = periodic_hann(config.frame_length);
  covariance = complex(zeros(number_mics, number_mics, number_bins));

  for frame_id = 1:numel(frame_starts)
    frame_range = frame_starts(frame_id): ...
                  frame_starts(frame_id) + config.frame_length - 1;
    frame = signals(:, frame_range) .* repmat(window, number_mics, 1);
    spectrum = fft(frame, [], 2);
    spectrum = spectrum(:, 1:number_bins);
    for frequency_id = 1:number_bins
      x = spectrum(:, frequency_id);
      covariance(:, :, frequency_id) += x * x';
    endfor
  endfor
  covariance /= max(numel(frame_starts), 1);
endfunction

function outputs = apply_frequency_beamformer( ...
    signals, angles_deg, mic_positions, covariance, method, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  number_bins = config.frame_length / 2 + 1;
  frequencies_hz = (0:number_bins - 1) * ...
                   config.fs / config.frame_length;
  frame_starts = 1:config.frame_hop:(samples - config.frame_length + 1);
  window = periodic_hann(config.frame_length);
  outputs = zeros(number_sources, samples);
  normalization = zeros(1, samples);
  steering = calculate_steering( ...
      angles_deg, frequencies_hz, mic_positions, config);
  weights = complex(zeros(size(steering)));

  for frequency_id = 1:number_bins
    R = covariance(:, :, frequency_id);
    loading_factor = config.mvdr_diagonal_loading;
    if strcmp(method, "lcmv")
      loading_factor = config.lcmv_diagonal_loading;
    endif
    loading = loading_factor * real(trace(R)) / number_mics + eps;
    loaded_R = (R + R') / 2 + loading * eye(number_mics);

    for source_id = 1:number_sources
      target = steering(:, source_id, frequency_id);
      if strcmp(method, "das")
        weights(:, source_id, frequency_id) = target / number_mics;
      elseif strcmp(method, "mvdr")
        candidate = loaded_R \ target;
        denominator = real(target' * candidate);
        if !isfinite(denominator) || denominator <= eps
          weights(:, source_id, frequency_id) = target / number_mics;
        else
          weights(:, source_id, frequency_id) = ...
              candidate / denominator;
        endif
      else
        [constraints, response] = lcmv_constraints( ...
            source_id, angles_deg, frequencies_hz(frequency_id), ...
            mic_positions, config);
        inverse_times_constraints = loaded_R \ constraints;
        gram = constraints' * inverse_times_constraints;
        if columns(constraints) > number_mics || ...
           rcond(gram) < config.lcmv_min_rcond
          candidate = target / number_mics;
        else
          candidate = inverse_times_constraints * (gram \ response);
        endif
        if any(!isfinite(candidate)) || ...
           norm(candidate) > config.lcmv_max_weight_norm
          candidate = target / number_mics;
        endif
        weights(:, source_id, frequency_id) = candidate;
      endif
    endfor
  endfor

  for frame_id = 1:numel(frame_starts)
    frame_range = frame_starts(frame_id): ...
                  frame_starts(frame_id) + config.frame_length - 1;
    frame = signals(:, frame_range) .* repmat(window, number_mics, 1);
    spectrum = fft(frame, [], 2);
    one_sided = spectrum(:, 1:number_bins);

    for source_id = 1:number_sources
      output_spectrum = complex(zeros(1, config.frame_length));
      for frequency_id = 1:number_bins
        w = weights(:, source_id, frequency_id);
        output_spectrum(frequency_id) = ...
            w' * one_sided(:, frequency_id);
      endfor
      output_spectrum(number_bins + 1:end) = ...
          conj(output_spectrum(number_bins - 1:-1:2));
      output_frame = real(ifft(output_spectrum)) .* window;
      outputs(source_id, frame_range) += output_frame;
    endfor
    normalization(frame_range) += window .^ 2;
  endfor

  valid = normalization > 1e-8;
  outputs(:, valid) ./= repmat( ...
      normalization(valid), number_sources, 1);
endfunction

function [constraints, response] = lcmv_constraints( ...
    target_id, angles_deg, frequency_hz, mic_positions, config)

  target_angle = angles_deg(target_id);
  interference_angles = angles_deg;
  interference_angles(target_id) = [];

  if numel(angles_deg) == 2
    null_angles = [
      interference_angles(1) - config.lcmv_null_width_deg, ...
      interference_angles(1) + config.lcmv_null_width_deg
    ];
  else
    null_angles = interference_angles;
  endif

  constraint_angles = [target_angle, null_angles];
  constraints_3d = calculate_steering( ...
      constraint_angles, frequency_hz, mic_positions, config);
  constraints = squeeze(constraints_3d(:, :, 1));
  response = zeros(numel(constraint_angles), 1);
  response(1) = 1;
endfunction

function outputs = apply_gsc( ...
    signals, angles_deg, mic_positions, dynamic_mu, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  number_blockers = number_mics - 1;
  filter_length = config.gsc_filter_length;
  outputs = zeros(number_sources, samples);

  for source_id = 1:number_sources
    aligned = align_signals( ...
        signals, angles_deg(source_id), mic_positions, config);
    upper_output = mean(aligned, 1);
    blocking_output = diff(aligned, 1, 1);
    filters = zeros(number_blockers, filter_length);

    for sample_id = filter_length:samples
      regressors = blocking_output( ...
          :, sample_id:-1:sample_id - filter_length + 1);
      noise_estimate = sum(sum(filters .* regressors));
      output = upper_output(sample_id) - noise_estimate;
      outputs(source_id, sample_id) = output;

      for blocker_id = 1:number_blockers
        regressor = regressors(blocker_id, :);
        regressor_power = sum(regressor .^ 2) + eps;
        if dynamic_mu
          recent_start = max(1, sample_id - filter_length + 1);
          output_power = sum( ...
              outputs(source_id, recent_start:sample_id) .^ 2) + eps;
          if config.gsc_mu0 * regressor_power / output_power < ...
             config.gsc_mu_max
            mu = config.gsc_mu0 / output_power;
          else
            mu = config.gsc_mu0 / regressor_power;
          endif
          mu = min(mu, config.gsc_mu_max / regressor_power);
        else
          mu = config.gsc_fixed_mu / regressor_power;
        endif

        filters(blocker_id, :) = ...
            (1 - config.gsc_leakage) * filters(blocker_id, :) + ...
            mu * output * regressor;
      endfor
    endfor
  endfor
endfunction

function aligned = align_signals( ...
    signals, angle_deg, mic_positions, config)

  [number_mics, samples] = size(signals);
  fft_length = 2 ^ nextpow2(2 * samples);
  frequencies_hz = [ ...
      0:(fft_length / 2), ...
      (-fft_length / 2 + 1):-1] * config.fs / fft_length;
  direction = [sind(angle_deg); cosd(angle_deg)];
  delays_s = -(mic_positions * direction) / config.sound_speed;
  aligned = zeros(size(signals));

  for microphone_id = 1:number_mics
    padded = [signals(microphone_id, :), ...
              zeros(1, fft_length - samples)];
    spectrum = fft(padded);
    phase_alignment = exp( ...
        1i * 2 * pi * frequencies_hz * delays_s(microphone_id));
    shifted = real(ifft(spectrum .* phase_alignment));
    aligned(microphone_id, :) = shifted(1:samples);
  endfor
endfunction

function outputs = apply_phase_frequency_mask( ...
    signals, angles_deg, mic_positions, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  number_bins = config.frame_length / 2 + 1;
  frequencies_hz = (0:number_bins - 1) * ...
                   config.fs / config.frame_length;
  frame_starts = 1:config.frame_hop:(samples - config.frame_length + 1);
  window = periodic_hann(config.frame_length);
  threshold_rad = config.phase_threshold_deg * pi / 180;
  outputs = zeros(number_sources, samples);
  normalization = zeros(1, samples);
  steering = calculate_steering( ...
      angles_deg, frequencies_hz, mic_positions, config);

  for frame_id = 1:numel(frame_starts)
    frame_range = frame_starts(frame_id): ...
                  frame_starts(frame_id) + config.frame_length - 1;
    frame = signals(:, frame_range) .* repmat(window, number_mics, 1);
    spectrum = fft(frame, [], 2);
    one_sided = spectrum(:, 1:number_bins);

    for source_id = 1:number_sources
      aligned = conj(squeeze( ...
          steering(:, source_id, :))) .* one_sided;
      reference_phase = angle(aligned(1, :));
      phase_errors = angle(exp( ...
          1i * (angle(aligned) - ...
          repmat(reference_phase, number_mics, 1))));
      maximum_error = max(abs(phase_errors), [], 1);
      mask = double(maximum_error <= threshold_rad);
      mask = max(mask, config.phase_mask_floor);

      output_spectrum = complex(zeros(1, config.frame_length));
      output_spectrum(1:number_bins) = mask .* one_sided(1, :);
      output_spectrum(number_bins + 1:end) = ...
          conj(output_spectrum(number_bins - 1:-1:2));
      output_frame = real(ifft(output_spectrum)) .* window;
      outputs(source_id, frame_range) += output_frame;
    endfor
    normalization(frame_range) += window .^ 2;
  endfor

  valid = normalization > 1e-8;
  outputs(:, valid) ./= repmat( ...
      normalization(valid), number_sources, 1);
endfunction

function steering = calculate_steering( ...
    angles_deg, frequencies_hz, mic_positions, config)

  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(mic_positions);
  number_sources = numel(angles_deg);
  number_bins = numel(frequencies_hz);
  steering = complex(zeros(number_mics, number_sources, number_bins));
  for frequency_id = 1:number_bins
    steering(:, :, frequency_id) = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
  endfor
endfunction

function metrics = evaluate_estimates( ...
    estimates, references, mixture_reference, estimated_angles_deg, ...
    true_angles_deg, config)

  number_sources = rows(references);
  score_matrix = -Inf(number_sources, number_sources);
  corr_matrix = zeros(number_sources, number_sources);
  for estimated_id = 1:number_sources
    for reference_id = 1:number_sources
      [score_matrix(estimated_id, reference_id), ...
       corr_matrix(estimated_id, reference_id)] = aligned_si_sdr( ...
          estimates(estimated_id, :), references(reference_id, :), ...
          config);
    endfor
  endfor

  source_orders = perms(1:number_sources);
  best_error = Inf;
  best_order = 1:number_sources;
  for order_id = 1:rows(source_orders)
    order = source_orders(order_id, :);
    doa_errors = angular_distance( ...
        estimated_angles_deg(order), true_angles_deg);
    if mean(doa_errors) < best_error
      best_error = mean(doa_errors);
      best_order = order;
    endif
  endfor

  metrics.si_sdr_db = zeros(1, number_sources);
  metrics.si_sdri_db = zeros(1, number_sources);
  metrics.correlation = zeros(1, number_sources);
  metrics.estimated_angles_deg = zeros(1, number_sources);
  metrics.doa_error_deg = zeros(1, number_sources);
  metrics.permutation = best_order;

  for reference_id = 1:number_sources
    estimated_id = best_order(reference_id);
    baseline = aligned_si_sdr( ...
        mixture_reference, references(reference_id, :), config);
    metrics.si_sdr_db(reference_id) = ...
        score_matrix(estimated_id, reference_id);
    metrics.si_sdri_db(reference_id) = ...
        metrics.si_sdr_db(reference_id) - baseline;
    metrics.correlation(reference_id) = ...
        corr_matrix(estimated_id, reference_id);
    metrics.estimated_angles_deg(reference_id) = ...
        estimated_angles_deg(estimated_id);
    metrics.doa_error_deg(reference_id) = angular_distance( ...
        metrics.estimated_angles_deg(reference_id), ...
        true_angles_deg(reference_id));
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

function [signals, references] = read_case_audio( ...
    case_path, number_references, config)

  microphone_paths = {
    fullfile(case_path, "wav_mic1.wav"), ...
    fullfile(case_path, "wav_mic2.wav"), ...
    fullfile(case_path, "wav_mic3.wav")
  };
  reference_paths = cell(1, number_references);
  for reference_id = 1:number_references
    reference_paths{reference_id} = fullfile( ...
        case_path, sprintf("pristine_channel%d.wav", reference_id));
  endfor

  [first_signal, fs] = audioread(microphone_paths{1});
  if fs != config.fs
    error("%s tiene fs=%d; se esperaba %d.", ...
          microphone_paths{1}, fs, config.fs);
  endif
  available_samples = rows(first_signal);
  target_samples = min( ...
      available_samples, round(config.segment_duration_s * config.fs));
  start_sample = max(1, floor((available_samples - target_samples) / 2) + 1);
  sample_range = start_sample:start_sample + target_samples - 1;

  signals = zeros(3, target_samples);
  signals(1, :) = first_signal(sample_range, 1)';
  for microphone_id = 2:3
    [signal, signal_fs] = audioread(microphone_paths{microphone_id});
    if signal_fs != config.fs || rows(signal) < sample_range(end)
      error("Audio incompatible: %s", microphone_paths{microphone_id});
    endif
    signals(microphone_id, :) = signal(sample_range, 1)';
  endfor

  references = zeros(number_references, target_samples);
  for reference_id = 1:number_references
    [reference, reference_fs] = audioread(reference_paths{reference_id});
    if reference_fs != config.fs
      error("%s tiene fs=%d; se esperaba %d.", ...
            reference_paths{reference_id}, reference_fs, config.fs);
    endif
    reference_start = min(start_sample, max(1, rows(reference) - ...
                          target_samples + 1));
    reference_end = min(rows(reference), ...
                        reference_start + target_samples - 1);
    segment = reference(reference_start:reference_end, 1)';
    references(reference_id, 1:numel(segment)) = segment;
  endfor
endfunction

function write_case_audio(output_directory, result, fs)
  if !exist(output_directory, "dir")
    mkdir(output_directory);
  endif
  methods = fieldnames(result.estimates);
  for method_id = 1:numel(methods)
    method_name = methods{method_id};
    estimates = result.estimates.(method_name);
    permutation = result.metrics.(method_name).permutation;
    for source_id = 1:numel(permutation)
      signal = estimates(permutation(source_id), :);
      peak = max(abs(signal));
      if peak > 1
        signal /= peak;
      endif
      output_path = fullfile( ...
          output_directory, ...
          sprintf("%s_source%d.wav", method_name, source_id));
      audiowrite(output_path, signal', fs);
    endfor
  endfor
endfunction

function print_case_result(result)
  printf("Caso: %s\n", result.case_name);
  printf("  DAS adaptativo (%s): %s grados\n", ...
         result.localization_mode, ...
         value_list_text(result.estimated_angles_deg));
  methods = fieldnames(result.metrics);
  for method_id = 1:numel(methods)
    method_name = methods{method_id};
    metrics = result.metrics.(method_name);
    printf("  %-12s SI-SDRi=%s dB, tiempo=%.2f ms\n", ...
           upper(method_name), ...
           value_list_text(metrics.si_sdri_db), ...
           1000 * result.timing.(method_name));
  endfor
  printf("\n");
endfunction

function write_case_csv(csv_file, result)
  methods = fieldnames(result.metrics);
  for method_id = 1:numel(methods)
    method_name = methods{method_id};
    metrics = result.metrics.(method_name);
    for source_id = 1:numel(result.true_angles_deg)
      fprintf(csv_file, ...
          "%s,%s,%d,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.4f\n", ...
          result.case_name, method_name, source_id, ...
          result.true_angles_deg(source_id), ...
          metrics.estimated_angles_deg(source_id), ...
          metrics.doa_error_deg(source_id), ...
          metrics.si_sdr_db(source_id), ...
          metrics.si_sdri_db(source_id), ...
          metrics.correlation(source_id), ...
          1000 * result.timing.(method_name));
    endfor
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

function distance = angular_distance(angle_a, angle_b)
  distance = abs(mod(angle_a - angle_b + 180, 360) - 180);
endfunction

function window = periodic_hann(length_samples)
  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:length_samples - 1) / length_samples);
endfunction

function text = value_list_text(values)
  text = strtrim(sprintf("%.2f ", values));
endfunction
