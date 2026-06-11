function results = run_full_das_iterative_sic(case_name, num_iterations, cancellation_factor)
  % Iterative interference cancellation initialized with frequency-domain DAS.
  %
  % Each source is recalculated from the original microphone signals after
  % subtracting the reconstructed images of all the other sources.

  if nargin < 1 || isempty(case_name)
    case_name = 'clean-2source';
  endif
  if nargin < 2 || isempty(num_iterations)
    num_iterations = 3;
  endif
  if nargin < 3 || isempty(cancellation_factor)
    cancellation_factor = 0.70;
  endif

  if num_iterations < 1 || num_iterations != fix(num_iterations)
    error('num_iterations must be a positive integer.');
  endif
  if cancellation_factor < 0 || cancellation_factor > 1
    error('cancellation_factor must be between 0 and 1.');
  endif

  pkg load signal;

  script_dir = fileparts(mfilename('fullpath'));
  project_dir = fileparts(fileparts(script_dir));
  localization_dir = fullfile(project_dir, 'Octave', 'Localizacion');
  corpus_root = fullfile(project_dir, 'data', 'corpus48000');
  output_dir = fullfile(script_dir, 'full_results', 'das_iterative_sic', case_name);
  localization_csv = fullfile(output_dir, 'localization_results.csv');

  addpath(localization_dir);
  if !exist(output_dir, 'dir')
    mkdir(output_dir);
  endif

  fprintf('\n=== Iterative DAS cancellation: %s ===\n', case_name);
  fprintf('Iterations per source: %d\n', num_iterations);
  fprintf('Cancellation factor: %.2f\n', cancellation_factor);

  localization = run_wola_das_adaptive_mask({case_name}, localization_csv);
  estimated_angles = localization(1).estimates_deg.adaptive(:).';
  true_angles = localization(1).true_angles_deg(:).';
  if isempty(estimated_angles)
    error('Adaptive DAS did not return any DOA for %s.', case_name);
  endif

  case_dir = fullfile(corpus_root, case_name);
  mic_files = {'wav_mic1.wav', 'wav_mic2.wav', 'wav_mic3.wav'};
  [first_channel, fs] = audioread(fullfile(case_dir, mic_files{1}));
  first_channel = first_channel(:, 1);
  num_samples = length(first_channel);
  num_mics = numel(mic_files);
  mic_signals = zeros(num_samples, num_mics);
  mic_signals(:, 1) = first_channel;

  for mic_idx = 2:num_mics
    [channel, channel_fs] = audioread(fullfile(case_dir, mic_files{mic_idx}));
    if channel_fs != fs
      error('All microphone files must use the same sample rate.');
    endif
    mic_signals(:, mic_idx) = channel(1:num_samples, 1);
  endfor

  [mic_distance, ~] = read_case_info(fullfile(case_dir, 'info.txt'));
  geometry = aira_microphone_positions(mic_distance);
  if rows(geometry) != num_mics
    error('Geometry has %d microphones, but the corpus has %d.', rows(geometry), num_mics);
  endif

  fft_size = 2 ^ nextpow2(num_samples);
  frequencies = (0:(fft_size - 1)) * fs / fft_size;
  microphone_spectra = fft(mic_signals, fft_size);
  num_sources = numel(estimated_angles);
  direction_vectors = cell(1, num_sources);

  for source_idx = 1:num_sources
    delays = far_field_delays(geometry, estimated_angles(source_idx));
    direction_vectors{source_idx} = exp(-1i * 2 * pi * delays * frequencies);
  endfor

  source_spectra = zeros(fft_size, num_sources);
  for source_idx = 1:num_sources
    steering = direction_vectors{source_idx}.';
    source_spectra(:, source_idx) = ...
      sum(conj(steering) .* microphone_spectra, 2) / num_mics;
  endfor

  iteration_audio = cell(num_iterations + 1, 1);
  iteration_audio{1} = spectra_to_audio(source_spectra, num_samples);
  save_iteration_audio(iteration_audio{1}, 0, estimated_angles, fs, output_dir);

  for iteration_idx = 1:num_iterations
    total_images = reconstruct_images(source_spectra, direction_vectors);
    updated_spectra = zeros(size(source_spectra));

    for source_idx = 1:num_sources
      source_image = direction_vectors{source_idx}.' .* source_spectra(:, source_idx);
      other_images = total_images - source_image;
      source_residual = microphone_spectra - cancellation_factor * other_images;
      steering = direction_vectors{source_idx}.';
      updated_spectra(:, source_idx) = ...
        sum(conj(steering) .* source_residual, 2) / num_mics;
    endfor

    source_spectra = updated_spectra;
    iteration_audio{iteration_idx + 1} = spectra_to_audio(source_spectra, num_samples);
    save_iteration_audio(iteration_audio{iteration_idx + 1}, iteration_idx, ...
                         estimated_angles, fs, output_dir);
    fprintf('Completed iteration %d/%d for all sources.\n', ...
            iteration_idx, num_iterations);
  endfor

  final_audio = iteration_audio{end};
  for source_idx = 1:num_sources
    output_file = fullfile(output_dir, sprintf('source%d_final.wav', source_idx));
    audiowrite(output_file, apply_output_gain(final_audio(:, source_idx)), fs);
  endfor

  final_images = reconstruct_images(source_spectra, direction_vectors);
  residual_spectra = microphone_spectra - cancellation_factor * final_images;
  residual_audio = real(ifft(residual_spectra));
  residual_audio = residual_audio(1:num_samples, :);
  for mic_idx = 1:num_mics
    audiowrite(fullfile(output_dir, sprintf('residual_sensor%d.wav', mic_idx)), ...
               apply_output_gain(residual_audio(:, mic_idx)), fs);
  endfor

  metrics = evaluate_iterations(iteration_audio, case_dir, estimated_angles, ...
                                true_angles, fs);
  write_iteration_metrics(metrics, fullfile(output_dir, 'iteration_metrics.csv'));
  write_run_info(fullfile(output_dir, 'run_info.txt'), case_name, fs, num_samples, ...
                 estimated_angles, num_iterations, cancellation_factor);

  results = struct();
  results.case_name = case_name;
  results.estimated_angles = estimated_angles;
  results.num_iterations = num_iterations;
  results.cancellation_factor = cancellation_factor;
  results.output_dir = output_dir;
  results.metrics = metrics;

  fprintf('Saved full-length iteration and final WAV files in:\n  %s\n', output_dir);
endfunction

function delays = far_field_delays(geometry, angle_degrees)
  sound_speed = 343;
  direction = [sind(angle_degrees); cosd(angle_degrees)];
  delays = -(geometry * direction) / sound_speed;
endfunction

function images = reconstruct_images(source_spectra, direction_vectors)
  fft_size = rows(source_spectra);
  num_mics = rows(direction_vectors{1});
  num_sources = columns(source_spectra);
  images = zeros(fft_size, num_mics);

  for source_idx = 1:num_sources
    images += direction_vectors{source_idx}.' .* source_spectra(:, source_idx);
  endfor
endfunction

function audio = spectra_to_audio(source_spectra, num_samples)
  audio = real(ifft(source_spectra));
  audio = audio(1:num_samples, :);
endfunction

function save_iteration_audio(audio, iteration_idx, angles, fs, output_dir)
  for source_idx = 1:columns(audio)
    filename = sprintf('iteration_%d_source%d_angle_%+04d.wav', ...
                       iteration_idx, source_idx, round(angles(source_idx)));
    audiowrite(fullfile(output_dir, filename), ...
               apply_output_gain(audio(:, source_idx)), fs);
  endfor
endfunction

function output = apply_output_gain(signal)
  output = signal * 2.0;
  peak = max(abs(output));
  if peak > 0.999
    output *= 0.999 / peak;
  endif
endfunction

function metrics = evaluate_iterations(iteration_audio, case_dir, estimated_angles, ...
                                       true_angles, fs)
  metrics = struct('iteration', {}, 'source', {}, 'estimated_angle', {}, ...
                   'reference', {}, 'si_sdr_db', {});
  num_pairs = min(numel(estimated_angles), numel(true_angles));
  if num_pairs == 0
    fprintf('Reference-angle mapping unavailable; skipping SI-SDR metrics.\n');
    return;
  endif

  reference_paths = cell(1, num_pairs);
  for reference_idx = 1:num_pairs
    reference_paths{reference_idx} = fullfile( ...
      case_dir, sprintf('pristine_channel%d.wav', reference_idx));
    if !exist(reference_paths{reference_idx}, 'file')
      fprintf('Missing %s; skipping SI-SDR metrics.\n', ...
              reference_paths{reference_idx});
      return;
    endif
  endfor

  assignment = best_angle_assignment(estimated_angles(1:num_pairs), ...
                                     true_angles(1:num_pairs));
  metric_idx = 0;
  for source_idx = 1:num_pairs
    reference_idx = assignment(source_idx);
    [reference, reference_fs] = audioread(reference_paths{reference_idx});
    if reference_fs != fs
      error('Reference and microphone sample rates do not match.');
    endif
    reference = reference(:, 1);

    for iteration_idx = 0:(numel(iteration_audio) - 1)
      estimate = iteration_audio{iteration_idx + 1}(:, source_idx);
      metric_idx += 1;
      metrics(metric_idx).iteration = iteration_idx;
      metrics(metric_idx).source = source_idx;
      metrics(metric_idx).estimated_angle = estimated_angles(source_idx);
      metrics(metric_idx).reference = reference_idx;
      metrics(metric_idx).si_sdr_db = aligned_si_sdr(reference, estimate, fs);
    endfor
  endfor
endfunction

function assignment = best_angle_assignment(estimated_angles, true_angles)
  num_sources = numel(estimated_angles);
  permutations = perms(1:num_sources);
  best_cost = Inf;
  assignment = 1:num_sources;

  for permutation_idx = 1:rows(permutations)
    candidate = permutations(permutation_idx, :);
    cost = 0;
    for source_idx = 1:num_sources
      difference = abs(estimated_angles(source_idx) - true_angles(candidate(source_idx)));
      cost += min(difference, 360 - difference);
    endfor
    if cost < best_cost
      best_cost = cost;
      assignment = candidate;
    endif
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

function value = aligned_si_sdr(reference, estimate, fs)
  max_lag = round(0.1 * fs);
  common_length = min(length(reference), length(estimate));
  reference = reference(1:common_length);
  estimate = estimate(1:common_length);
  [correlation, lags] = xcorr(estimate, reference, max_lag);
  [~, peak_idx] = max(abs(correlation));
  lag = lags(peak_idx);

  if lag >= 0
    estimate = estimate((1 + lag):end);
    reference = reference(1:length(estimate));
  else
    reference = reference((1 - lag):end);
    estimate = estimate(1:length(reference));
  endif

  reference -= mean(reference);
  estimate -= mean(estimate);
  scale = (reference' * estimate) / (reference' * reference + eps);
  target = scale * reference;
  noise = estimate - target;
  value = 10 * log10((target' * target + eps) / (noise' * noise + eps));
endfunction

function write_iteration_metrics(metrics, output_file)
  file_id = fopen(output_file, 'w');
  fprintf(file_id, 'iteration,source,estimated_angle_deg,reference,si_sdr_db\n');
  for idx = 1:numel(metrics)
    fprintf(file_id, '%d,%d,%.2f,%d,%.6f\n', ...
            metrics(idx).iteration, metrics(idx).source, ...
            metrics(idx).estimated_angle, metrics(idx).reference, ...
            metrics(idx).si_sdr_db);
  endfor
  fclose(file_id);
endfunction

function write_run_info(output_file, case_name, fs, num_samples, angles, ...
                        num_iterations, cancellation_factor)
  file_id = fopen(output_file, 'w');
  fprintf(file_id, 'Case: %s\n', case_name);
  fprintf(file_id, 'Sample rate: %d Hz\n', fs);
  fprintf(file_id, 'Samples: %d\n', num_samples);
  fprintf(file_id, 'Duration: %.3f s\n', num_samples / fs);
  fprintf(file_id, 'Iterations per source: %d\n', num_iterations);
  fprintf(file_id, 'Cancellation factor: %.3f\n', cancellation_factor);
  fprintf(file_id, 'Output gain: +6.0206 dB, with clipping prevention\n');
  fprintf(file_id, 'Estimated angles:');
  fprintf(file_id, ' %.2f', angles);
  fprintf(file_id, '\n');
  fclose(file_id);
endfunction
