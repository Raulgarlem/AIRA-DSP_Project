function result = run_full_das_triple_sum(case_name, angle_offsets_deg)
%RUN_FULL_DAS_TRIPLE_SUM Sum three DAS estimates around every localized DOA.
%
% Repeating DAS three times with the same signals and DOA produces three
% identical signals. This variant uses nearby steering directions and
% coherently averages them:
%   output = (DAS(theta+d1) + DAS(theta+d2) + DAS(theta+d3)) / 3
%
% Examples:
%   result = run_full_das_triple_sum("clean-2source");
%   result = run_full_das_triple_sum("clean-2source", [-2, 0, 2]);

  pkg load signal;

  if nargin < 1 || isempty(case_name)
    case_name = "clean-2source";
  endif
  if nargin < 2 || isempty(angle_offsets_deg)
    angle_offsets_deg = [-2, 0, 2];
  endif
  if numel(angle_offsets_deg) != 3
    error("angle_offsets_deg debe contener exactamente tres valores.");
  endif

  config.fs = 48000;
  config.sound_speed = 343;
  config.padding_samples = 1024;
  config.output_gain_db = 6.0206;
  config.evaluation_max_delay_s = 0.10;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  localization_directory = fullfile(project_root, "Octave", "Localizacion");
  corpus_path = fullfile(project_root, "data", "corpus48000");
  case_path = fullfile(corpus_path, char(case_name));
  output_directory = fullfile( ...
      separation_directory, "full_results", "das_triple_sum", ...
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

  printf("\nSuma coherente de tres DAS: %s\n", char(case_name));
  printf("1. Obteniendo DOAs con DAS adaptativo...\n");
  localization = run_wola_das_adaptive_mask( ...
      {char(case_name)}, localization_csv);
  if isempty(localization)
    error("El localizador no produjo resultados para %s.", case_name);
  endif

  estimated_angles_deg = localization(1).estimates_deg.adaptive(:)';
  true_angles_deg = localization(1).true_angles_deg(:)';
  [mic_distance_m, ~] = read_case_info( ...
      fullfile(case_path, "info.txt"));
  [signals, references] = read_complete_audio( ...
      case_path, numel(true_angles_deg), config);
  mic_positions = aira_microphone_positions(mic_distance_m);

  printf("2. Calculando DAS con offsets angulares %s...\n", ...
         mat2str(angle_offsets_deg));
  timer_id = tic();
  pass_outputs = frequency_domain_triple_das( ...
      signals, estimated_angles_deg, angle_offsets_deg, ...
      mic_positions, config);
  summed_outputs = mean(pass_outputs, 3);
  processing_time_s = toc(timer_id);

  center_id = find(angle_offsets_deg == 0, 1);
  if isempty(center_id)
    center_id = 1;
  endif
  center_outputs = pass_outputs(:, :, center_id);
  center_metrics = evaluate_estimates( ...
      center_outputs, references, estimated_angles_deg, ...
      true_angles_deg, config);
  summed_metrics = evaluate_estimates( ...
      summed_outputs, references, estimated_angles_deg, ...
      true_angles_deg, config);

  printf("3. Guardando las tres pasadas y la suma en:\n%s\n", ...
         output_directory);
  output_paths = write_audio_outputs( ...
      output_directory, pass_outputs, summed_outputs, ...
      estimated_angles_deg, angle_offsets_deg, config);
  write_metrics_csv( ...
      fullfile(output_directory, "separation_metrics.csv"), ...
      center_metrics, summed_metrics, true_angles_deg);
  write_info_file( ...
      fullfile(output_directory, "separation_info.txt"), ...
      case_name, true_angles_deg, estimated_angles_deg, ...
      angle_offsets_deg, columns(signals), processing_time_s, ...
      center_metrics, summed_metrics, config);

  result.case_name = char(case_name);
  result.method = "Promedio coherente de tres DAS";
  result.true_angles_deg = true_angles_deg;
  result.estimated_angles_deg = estimated_angles_deg;
  result.angle_offsets_deg = angle_offsets_deg;
  result.center_metrics = center_metrics;
  result.summed_metrics = summed_metrics;
  result.duration_s = columns(signals) / config.fs;
  result.processing_time_s = processing_time_s;
  result.output_directory = output_directory;
  result.output_paths = output_paths;

  for source_id = 1:numel(true_angles_deg)
    change = summed_metrics.si_sdr_db(source_id) - ...
             center_metrics.si_sdr_db(source_id);
    printf("  Fuente %d: DAS central %.3f dB, suma %.3f dB, cambio %+.3f dB\n", ...
           source_id, center_metrics.si_sdr_db(source_id), ...
           summed_metrics.si_sdr_db(source_id), change);
  endfor
endfunction

function outputs = frequency_domain_triple_das( ...
    signals, angles_deg, offsets_deg, mic_positions, config)

  [number_mics, samples] = size(signals);
  number_sources = numel(angles_deg);
  padding = config.padding_samples;
  fft_length = 2 ^ nextpow2(samples + 2 * padding);
  original_range = padding + 1:padding + samples;
  padded_signals = zeros(number_mics, fft_length);
  padded_signals(:, original_range) = signals;
  captured_spectra = fft(padded_signals, [], 2);
  frequency_ids = [0:(fft_length / 2), ...
                   (-fft_length / 2 + 1):-1];
  frequencies_hz = frequency_ids * config.fs / fft_length;
  outputs = zeros(number_sources, samples, 3);

  for pass_id = 1:3
    pass_angles = angles_deg + offsets_deg(pass_id);
    directions = [sind(pass_angles); cosd(pass_angles)];
    delays_s = -(mic_positions * directions) / config.sound_speed;
    for source_id = 1:number_sources
      steering = exp( ...
          -1i * 2 * pi * delays_s(:, source_id) * frequencies_hz);
      source_spectrum = sum( ...
          conj(steering) .* captured_spectra, 1) / number_mics;
      source_time = real(ifft(source_spectrum));
      outputs(source_id, :, pass_id) = source_time(original_range);
    endfor
  endfor
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

  orders = perms(1:number_sources);
  best_score = -Inf;
  best_order = 1:number_sources;
  for order_id = 1:rows(orders)
    score = 0;
    for reference_id = 1:number_sources
      score += score_matrix(orders(order_id, reference_id), reference_id);
    endfor
    if score > best_score
      best_score = score;
      best_order = orders(order_id, :);
    endif
  endfor

  metrics.si_sdr_db = zeros(1, number_sources);
  metrics.correlation = zeros(1, number_sources);
  metrics.estimated_angles_deg = zeros(1, number_sources);
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
  samples = rows(first_signal);
  if fs != config.fs
    error("Frecuencia de muestreo incompatible.");
  endif
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
      error("Referencia incompatible: %s", reference_path);
    endif
    copied_samples = min(samples, rows(reference));
    references(reference_id, 1:copied_samples) = ...
        reference(1:copied_samples, 1)';
  endfor
endfunction

function output_paths = write_audio_outputs( ...
    output_directory, pass_outputs, summed_outputs, angles_deg, ...
    offsets_deg, config)

  number_sources = rows(summed_outputs);
  output_paths.passes = cell(3, number_sources);
  output_paths.summed = cell(1, number_sources);
  for source_id = 1:number_sources
    angle = round(angles_deg(source_id));
    for pass_id = 1:3
      output_paths.passes{pass_id, source_id} = fullfile( ...
          output_directory, sprintf( ...
              "das_pass%d_offset_%+03d_source%d_angle_%+04d.wav", ...
              pass_id, round(offsets_deg(pass_id)), source_id, angle));
      audiowrite(output_paths.passes{pass_id, source_id}, ...
        prepare_output(pass_outputs(source_id, :, pass_id), config)', ...
        config.fs);
    endfor
    output_paths.summed{source_id} = fullfile( ...
        output_directory, ...
        sprintf("triple_sum_source%d_angle_%+04d.wav", source_id, angle));
    audiowrite(output_paths.summed{source_id}, ...
      prepare_output(summed_outputs(source_id, :), config)', config.fs);
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
    output_path, center_metrics, summed_metrics, true_angles_deg)

  file_id = fopen(output_path, "w");
  fprintf(file_id, ...
      "method,source,true_angle_deg,estimated_angle_deg,si_sdr_db,correlation\n");
  for source_id = 1:numel(true_angles_deg)
    fprintf(file_id, "center_das,%d,%.2f,%.2f,%.6f,%.6f\n", ...
            source_id, true_angles_deg(source_id), ...
            center_metrics.estimated_angles_deg(source_id), ...
            center_metrics.si_sdr_db(source_id), ...
            center_metrics.correlation(source_id));
    fprintf(file_id, "triple_sum,%d,%.2f,%.2f,%.6f,%.6f\n", ...
            source_id, true_angles_deg(source_id), ...
            summed_metrics.estimated_angles_deg(source_id), ...
            summed_metrics.si_sdr_db(source_id), ...
            summed_metrics.correlation(source_id));
  endfor
  fclose(file_id);
endfunction

function write_info_file( ...
    output_path, case_name, true_angles_deg, estimated_angles_deg, ...
    offsets_deg, samples, processing_time_s, center_metrics, ...
    summed_metrics, config)

  file_id = fopen(output_path, "w");
  fprintf(file_id, "Caso: %s\n", char(case_name));
  fprintf(file_id, "Metodo: promedio coherente de tres DAS\n");
  fprintf(file_id, "Offsets angulares: %s\n", mat2str(offsets_deg));
  fprintf(file_id, "Angulos reales: %s\n", ...
          strtrim(sprintf("%.2f ", true_angles_deg)));
  fprintf(file_id, "Angulos estimados: %s\n", ...
          strtrim(sprintf("%.2f ", estimated_angles_deg)));
  fprintf(file_id, "Muestras: %d\n", samples);
  fprintf(file_id, "Duracion: %.6f s\n", samples / config.fs);
  fprintf(file_id, "SI-SDR DAS central: %s\n", ...
          strtrim(sprintf("%.4f ", center_metrics.si_sdr_db)));
  fprintf(file_id, "SI-SDR suma: %s\n", ...
          strtrim(sprintf("%.4f ", summed_metrics.si_sdr_db)));
  fprintf(file_id, "Tiempo de separacion: %.6f s\n", processing_time_s);
  fclose(file_id);
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
