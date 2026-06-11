function results = run_wola_source_separation(case_names)
%RUN_WOLA_SOURCE_SEPARATION Separate localized sources with DAS and MVDR.
%
% Two complete localization/separation paths are compared:
%   1. Adaptive SNR-weighted DAS localization -> DAS beamforming.
%   2. SRP-PHAT localization -> masked, diagonally-loaded MVDR beamforming.
%
% Examples:
%   results = run_wola_source_separation();
%   results = run_wola_source_separation({"clean-2source", "noisy-2source"});

  pkg load signal;

  if nargin < 1 || isempty(case_names)
    case_names = {"clean-2source"};
  elseif ischar(case_names)
    case_names = {case_names};
  endif

  config.fs = 48000;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.segment_duration_s = 3.0;
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
  config.mask_confidence_margin = 1.05;
  config.mvdr_diagonal_loading = 1e-2;
  config.evaluation_max_delay_s = 0.10;
  config.write_audio = true;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  corpus_path = fullfile(project_root, "data", "corpus48000");
  output_csv = fullfile( ...
      separation_directory, "wola_source_separation_results.csv");

  csv_file = fopen(output_csv, "w");
  if csv_file < 0
    error("No se pudo crear el archivo CSV: %s", output_csv);
  endif
  fprintf(csv_file, ...
      ["caso,metodo,fuente,angulo_real,angulo_estimado,error_doa_grados,", ...
       "si_sdr_db,si_sdri_db,correlacion,localizacion_ms,", ...
       "separacion_ms\n"]);

  printf("\nSeparacion WOLA guiada por localizacion\n");
  printf("Ventana=%d, salto=%d, banda=%d-%d Hz, segmento=%.1f s\n\n", ...
         config.frame_length, config.frame_hop, ...
         config.min_frequency_hz, config.max_frequency_hz, ...
         config.segment_duration_s);

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
      [signals, references] = read_case_audio( ...
          case_path, numel(true_angles_deg), config);
      if rows(references) != numel(true_angles_deg)
        warning(["%s tiene %d referencias para %d DOAs; ", ...
                 "se omite la evaluacion."], ...
                case_name, rows(references), numel(true_angles_deg));
        continue;
      endif

      mic_positions = aira_microphone_positions(mic_distance_m);
      case_result = process_case( ...
          signals, references, mic_positions, true_angles_deg, config);
      case_result.case_name = case_name;

      if config.write_audio
        output_directory = fullfile( ...
            separation_directory, "results", case_name);
        write_separated_audio(output_directory, case_result, config.fs);
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
    signals, references, mic_positions, true_angles_deg, config)

  timer_id = tic();
  analysis = analyze_wola(signals, mic_positions, config);
  das_spectrum = evaluate_das_spectrum( ...
      analysis.csd, analysis.frequencies_hz, analysis.snr_weights, ...
      mic_positions, config);
  [das_mode, das_selected_spectrum] = select_adaptive_das_spectrum( ...
      das_spectrum, analysis.mask_diagnostics, ...
      numel(true_angles_deg), config);
  das_angles = find_spatial_peaks( ...
      das_selected_spectrum, config.angle_grid_deg, ...
      numel(true_angles_deg), config.min_peak_separation_deg);

  srp_spectrum = evaluate_srp_phat( ...
      analysis.phat_csd, analysis.frequencies_hz, ...
      mic_positions, config);
  srp_angles = find_spatial_peaks( ...
      srp_spectrum, config.angle_grid_deg, ...
      numel(true_angles_deg), config.min_peak_separation_deg);
  localization_time_s = toc(timer_id);

  timer_id = tic();
  das_estimates = apply_wola_beamformer( ...
      signals, das_angles, mic_positions, [], "das", config);
  das_time_s = toc(timer_id);

  timer_id = tic();
  mvdr_estimates = apply_wola_beamformer( ...
      signals, srp_angles, mic_positions, analysis.full_csd, ...
      "mvdr", config);
  mvdr_time_s = toc(timer_id);

  das_metrics = evaluate_estimates( ...
      das_estimates, references, signals(1, :), das_angles, ...
      true_angles_deg, config);
  mvdr_metrics = evaluate_estimates( ...
      mvdr_estimates, references, signals(1, :), srp_angles, ...
      true_angles_deg, config);

  result.true_angles_deg = true_angles_deg;
  result.das_adaptive.mode = das_mode;
  result.das_adaptive.estimated_angles_deg = das_angles;
  result.das_adaptive.spectrum = das_selected_spectrum;
  result.das_adaptive.estimates = das_estimates;
  result.das_adaptive.metrics = das_metrics;
  result.das_adaptive.separation_time_s = das_time_s;
  result.srp_mvdr.estimated_angles_deg = srp_angles;
  result.srp_mvdr.spectrum = srp_spectrum;
  result.srp_mvdr.estimates = mvdr_estimates;
  result.srp_mvdr.metrics = mvdr_metrics;
  result.srp_mvdr.separation_time_s = mvdr_time_s;
  result.localization_time_s = localization_time_s;
  result.mask_diagnostics = analysis.mask_diagnostics;
endfunction

function analysis = analyze_wola(signals, mic_positions, config)
  [number_mics, samples] = size(signals);
  number_bins = config.frame_length / 2 + 1;
  frequencies_hz = (0:number_bins - 1) * ...
                   config.fs / config.frame_length;
  localization_mask = frequencies_hz >= config.min_frequency_hz & ...
                      frequencies_hz <= config.max_frequency_hz;
  selected_frequencies_hz = frequencies_hz(localization_mask);
  selected_bins = numel(selected_frequencies_hz);
  frame_starts = 1:config.frame_hop:(samples - config.frame_length + 1);
  number_frames = numel(frame_starts);
  window = periodic_hann(config.frame_length);

  smoothed_csd = [];
  accumulated_csd = complex(zeros( ...
      number_mics, number_mics, selected_bins));
  full_csd = complex(zeros(number_mics, number_mics, number_bins));
  phat_csd = complex(zeros(number_mics, number_mics, selected_bins));
  smoothed_power = [];
  power_history = zeros(config.noise_window_frames, selected_bins);
  history_count = 0;
  history_position = 0;

  for frame_id = 1:number_frames
    frame_range = frame_starts(frame_id): ...
                  frame_starts(frame_id) + config.frame_length - 1;
    frame = signals(:, frame_range) .* repmat(window, number_mics, 1);
    frame_spectrum = fft(frame, [], 2);
    one_sided = frame_spectrum(:, 1:number_bins);
    selected = one_sided(:, localization_mask);

    instantaneous_csd = complex(zeros( ...
        number_mics, number_mics, selected_bins));
    for frequency_id = 1:selected_bins
      x = selected(:, frequency_id);
      instantaneous_csd(:, :, frequency_id) = x * x';
      normalized = x ./ (abs(x) + eps);
      phat_csd(:, :, frequency_id) += normalized * normalized';
    endfor
    accumulated_csd += instantaneous_csd;

    for frequency_id = 1:number_bins
      x = one_sided(:, frequency_id);
      full_csd(:, :, frequency_id) += x * x';
    endfor

    current_power = mean(abs(selected) .^ 2, 1);
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
  endfor

  full_csd /= max(number_frames, 1);
  phat_csd /= max(number_frames, 1);
  noise_floor = min(power_history(1:history_count, :), [], 1);
  snr_ratio = smoothed_power ./ (noise_floor + eps);
  threshold_ratio = 10 ^ (config.snr_threshold_db / 10);
  snr_weights = max(0, 1 - threshold_ratio ./ (snr_ratio + eps));

  diagnostics.active_bins = sum(snr_weights > 0);
  diagnostics.effective_bins = ...
      (sum(snr_weights) ^ 2) / (sum(snr_weights .^ 2) + eps);
  diagnostics.mean_weight = mean(snr_weights);
  diagnostics.valid = ...
      diagnostics.active_bins >= config.min_active_bins && ...
      diagnostics.effective_bins >= config.min_effective_bins && ...
      diagnostics.mean_weight >= config.min_mean_weight;

  analysis.csd = accumulated_csd / max(number_frames, 1);
  analysis.full_csd = full_csd;
  analysis.phat_csd = phat_csd;
  analysis.frequencies_hz = selected_frequencies_hz;
  analysis.snr_weights = snr_weights;
  analysis.mask_diagnostics = diagnostics;
endfunction

function spectra = evaluate_das_spectrum( ...
    csd, frequencies_hz, snr_weights, mic_positions, config)

  directions = [sind(config.angle_grid_deg); ...
                cosd(config.angle_grid_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(mic_positions);
  base = zeros(size(config.angle_grid_deg));
  snr = zeros(size(config.angle_grid_deg));

  for frequency_id = 1:numel(frequencies_hz)
    steering = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
    steered_covariance = csd(:, :, frequency_id) * steering;
    power = real(sum(conj(steering) .* steered_covariance, 1)) / ...
            (number_mics ^ 2);
    base += power;
    snr += snr_weights(frequency_id) * power;
  endfor

  spectra.base = normalize_spectrum(base);
  spectra.snr = normalize_spectrum(snr);
endfunction

function [mode, spectrum] = select_adaptive_das_spectrum( ...
    spectra, diagnostics, number_sources, config)

  base_confidence = spatial_confidence( ...
      spectra.base, number_sources, config);
  snr_confidence = spatial_confidence( ...
      spectra.snr, number_sources, config);

  if diagnostics.valid && ...
     snr_confidence > config.mask_confidence_margin * base_confidence
    mode = "snr";
    spectrum = spectra.snr;
  else
    mode = "base";
    spectrum = spectra.base;
  endif
endfunction

function confidence = spatial_confidence(spectrum, number_sources, config)
  peaks = find_spatial_peaks( ...
      spectrum, config.angle_grid_deg, number_sources, ...
      config.min_peak_separation_deg);
  peak_values = zeros(size(peaks));
  for peak_id = 1:numel(peaks)
    [~, angle_id] = min(abs(config.angle_grid_deg - peaks(peak_id)));
    peak_values(peak_id) = spectrum(angle_id);
  endfor
  confidence = mean(peak_values) / (median(spectrum) + eps);
endfunction

function spectrum = evaluate_srp_phat( ...
    phat_csd, frequencies_hz, mic_positions, config)

  directions = [sind(config.angle_grid_deg); ...
                cosd(config.angle_grid_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(mic_positions);
  spectrum = zeros(size(config.angle_grid_deg));

  for frequency_id = 1:numel(frequencies_hz)
    steering = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
    steered_covariance = phat_csd(:, :, frequency_id) * steering;
    power = real(sum(conj(steering) .* steered_covariance, 1));
    spectrum += (power - number_mics) / ...
                max(number_mics * (number_mics - 1), 1);
  endfor
  spectrum = normalize_spectrum(spectrum);
endfunction

function outputs = apply_wola_beamformer( ...
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

  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  steering = complex(zeros(number_mics, number_sources, number_bins));
  weights = complex(zeros(size(steering)));

  for frequency_id = 1:number_bins
    steering(:, :, frequency_id) = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
  endfor

  if strcmp(method, "mvdr")
    interference_covariance = estimate_interference_covariance( ...
        signals, steering, window, frame_starts, config);
  else
    interference_covariance = [];
  endif

  for frequency_id = 1:number_bins
    for source_id = 1:number_sources
      a = steering(:, source_id, frequency_id);
      if strcmp(method, "das")
        weights(:, source_id, frequency_id) = a / number_mics;
      else
        R = interference_covariance(:, :, frequency_id, source_id);
        if real(trace(R)) <= eps
          R = covariance(:, :, frequency_id);
        endif
        loading = config.mvdr_diagonal_loading * ...
                  real(trace(R)) / number_mics + eps;
        loaded_R = (R + R') / 2 + loading * eye(number_mics);
        candidate = loaded_R \ a;
        denominator = real(a' * candidate);
        if !isfinite(denominator) || denominator <= eps
          weights(:, source_id, frequency_id) = a / number_mics;
        else
          weights(:, source_id, frequency_id) = ...
              candidate / denominator;
        endif
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

function interference_covariance = estimate_interference_covariance( ...
    signals, steering, window, frame_starts, config)

  [number_mics, ~] = size(signals);
  [~, number_sources, number_bins] = size(steering);
  interference_covariance = complex(zeros( ...
      number_mics, number_mics, number_bins, number_sources));
  mask_sums = zeros(number_bins, number_sources);

  for frame_id = 1:numel(frame_starts)
    frame_range = frame_starts(frame_id): ...
                  frame_starts(frame_id) + config.frame_length - 1;
    frame = signals(:, frame_range) .* repmat(window, number_mics, 1);
    spectrum = fft(frame, [], 2);
    one_sided = spectrum(:, 1:number_bins);

    for frequency_id = 1:number_bins
      x = one_sided(:, frequency_id);
      directional_power = zeros(1, number_sources);
      for source_id = 1:number_sources
        a = steering(:, source_id, frequency_id);
        directional_power(source_id) = ...
            abs(a' * x / number_mics) ^ 2;
      endfor
      source_masks = directional_power / ...
                     (sum(directional_power) + eps);

      for source_id = 1:number_sources
        interference_mask = max(0.05, 1 - source_masks(source_id));
        interference_covariance(:, :, frequency_id, source_id) += ...
            interference_mask * (x * x');
        mask_sums(frequency_id, source_id) += interference_mask;
      endfor
    endfor
  endfor

  for source_id = 1:number_sources
    for frequency_id = 1:number_bins
      interference_covariance(:, :, frequency_id, source_id) /= ...
          max(mask_sums(frequency_id, source_id), eps);
    endfor
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
  best_score = -Inf;
  best_order = 1:number_sources;
  for order_id = 1:rows(source_orders)
    order = source_orders(order_id, :);
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
    if !exist(reference_paths{reference_id}, "file")
      error("No existe la referencia: %s", reference_paths{reference_id});
    endif
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

  references = zeros(numel(reference_paths), target_samples);
  for reference_id = 1:numel(reference_paths)
    reference_path = reference_paths{reference_id};
    [reference, reference_fs] = audioread(reference_path);
    if reference_fs != config.fs
      error("%s tiene fs=%d; se esperaba %d.", ...
            reference_path, reference_fs, config.fs);
    endif
    reference_start = min(start_sample, max(1, rows(reference) - ...
                          target_samples + 1));
    reference_end = min(rows(reference), ...
                        reference_start + target_samples - 1);
    reference_segment = reference(reference_start:reference_end, 1)';
    references(reference_id, 1:numel(reference_segment)) = ...
        reference_segment;
  endfor
endfunction

function write_separated_audio(output_directory, result, fs)
  if !exist(output_directory, "dir")
    mkdir(output_directory);
  endif
  write_method_audio( ...
      output_directory, "das_adaptive", ...
      result.das_adaptive.estimates, ...
      result.das_adaptive.metrics.permutation, fs);
  write_method_audio( ...
      output_directory, "srp_mvdr", ...
      result.srp_mvdr.estimates, ...
      result.srp_mvdr.metrics.permutation, fs);
endfunction

function write_method_audio( ...
    output_directory, method_name, estimates, permutation, fs)
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
endfunction

function print_case_result(result)
  printf("Caso: %s\n", result.case_name);
  printf("  DOAs reales: %s\n", angle_list_text(result.true_angles_deg));
  printf("  DAS adaptativo (%s): %s\n", ...
         result.das_adaptive.mode, ...
         angle_list_text(result.das_adaptive.estimated_angles_deg));
  print_method_metrics("DAS", result.das_adaptive.metrics);
  printf("  SRP-PHAT -> MVDR: %s\n", ...
         angle_list_text(result.srp_mvdr.estimated_angles_deg));
  print_method_metrics("MVDR", result.srp_mvdr.metrics);
  printf("\n");
endfunction

function print_method_metrics(label, metrics)
  printf("    %s SI-SDR: %s dB\n", ...
         label, value_list_text(metrics.si_sdr_db));
  printf("    %s SI-SDRi: %s dB\n", ...
         label, value_list_text(metrics.si_sdri_db));
endfunction

function write_case_csv(csv_file, result)
  write_method_csv(csv_file, result, "das_adaptive", ...
                   result.das_adaptive, result.localization_time_s);
  write_method_csv(csv_file, result, "srp_mvdr", ...
                   result.srp_mvdr, result.localization_time_s);
endfunction

function write_method_csv( ...
    csv_file, result, method_name, method_result, localization_time_s)
  metrics = method_result.metrics;
  for source_id = 1:numel(result.true_angles_deg)
    fprintf(csv_file, ...
        "%s,%s,%d,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f\n", ...
        result.case_name, method_name, source_id, ...
        result.true_angles_deg(source_id), ...
        metrics.estimated_angles_deg(source_id), ...
        metrics.doa_error_deg(source_id), ...
        metrics.si_sdr_db(source_id), metrics.si_sdri_db(source_id), ...
        metrics.correlation(source_id), ...
        1000 * localization_time_s, ...
        1000 * method_result.separation_time_s);
  endfor
endfunction

function [mic_distance_m, angles_deg] = read_case_info(info_path)
  text = fileread(info_path);
  lines = strsplit(strtrim(text), {"\r\n", "\n", "\r"});
  mic_distance_m = str2double(strtrim(lines{1}));
  angles_deg = sscanf( ...
      strrep(strjoin(lines(2:end), " "), ",", " "), "%f")';
  if isnan(mic_distance_m) || isempty(angles_deg)
    error("No se pudo leer la geometria de %s.", info_path);
  endif
endfunction

function positions = aira_microphone_positions(distance_m)
  positions = [
     0.00,              0.00;
    -distance_m,        0.00;
    -distance_m / 2,   -sqrt(3) * distance_m / 2
  ];
  positions -= repmat(mean(positions, 1), rows(positions), 1);
endfunction

function estimates = find_spatial_peaks( ...
    spectrum, angle_grid_deg, number_peaks, minimum_separation_deg)

  left = spectrum([end, 1:end - 1]);
  right = spectrum([2:end, 1]);
  candidates = find(spectrum >= left & spectrum > right);
  if isempty(candidates)
    [~, candidates] = sort(spectrum, "descend");
  else
    [~, order] = sort(spectrum(candidates), "descend");
    candidates = candidates(order);
  endif

  estimates = [];
  for candidate_id = 1:numel(candidates)
    angle = angle_grid_deg(candidates(candidate_id));
    if isempty(estimates) || all( ...
        angular_distance(angle, estimates) >= minimum_separation_deg)
      estimates(end + 1) = angle;
    endif
    if numel(estimates) >= number_peaks
      break;
    endif
  endfor

  if numel(estimates) < number_peaks
    [~, order] = sort(spectrum, "descend");
    for candidate_id = order
      angle = angle_grid_deg(candidate_id);
      if isempty(estimates) || all( ...
          angular_distance(angle, estimates) >= minimum_separation_deg)
        estimates(end + 1) = angle;
      endif
      if numel(estimates) >= number_peaks
        break;
      endif
    endfor
  endif
  estimates = sort(estimates);
endfunction

function normalized = normalize_spectrum(spectrum)
  spectrum = real(spectrum);
  minimum = min(spectrum);
  maximum = max(spectrum);
  if maximum - minimum <= eps
    normalized = zeros(size(spectrum));
  else
    normalized = (spectrum - minimum) / (maximum - minimum);
  endif
endfunction

function distance = angular_distance(angle_a, angle_b)
  distance = abs(mod(angle_a - angle_b + 180, 360) - 180);
endfunction

function window = periodic_hann(length_samples)
  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:length_samples - 1) / length_samples);
endfunction

function text = angle_list_text(values)
  text = strtrim(sprintf("%.1f ", values));
endfunction

function text = value_list_text(values)
  text = strtrim(sprintf("%.2f ", values));
endfunction
