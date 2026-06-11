function results = run_localization_simulation(mode, corpus_name, case_name)
%RUN_LOCALIZATION_SIMULATION Compare DOA methods with the AIRA geometry.
%
% Angle convention:
%   0 degrees points to +y, 90 degrees points to +x.
%
% The experiment uses an equilateral three-microphone array and compares:
%   1. Pearson normalized cross-correlation
%   2. GCC
%   3. GCC-PHAT using microphone pair 2-1
%   4. Multi-GCC-PHAT using multiple peaks from microphone pair 2-1
%   5. SRP-PHAT (steered GCC-PHAT using every pair)
%   6. Delay-and-sum spatial power
%   7. Broadband MUSIC

  if nargin < 1
    mode = "simulation";
  endif
  if nargin < 2
    corpus_name = "";
  endif
  if nargin < 3
    case_name = "";
  endif

  if strcmpi(mode, "corpus")
    results = run_corpus_batch(corpus_name, case_name);
    return;
  elseif !strcmpi(mode, "simulation")
    error("Modo desconocido. Use 'simulation' o 'corpus'.");
  endif

  close all;
  clc;

  config.fs = 48000;
  config.duration_s = 1.0;
  config.sound_speed = 343;
  config.mic_distance_m = 0.18;
  config.snr_db = 20;
  config.angle_grid_deg = -180:1:179;
  config.hierarchical_search = true;
  config.coarse_step_deg = 5;
  config.refine_step_deg = 1;
  config.refine_radius_deg = 5;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.min_frequency_hz = 300;
  config.max_frequency_hz = 5000;
  config.music_frequency_stride = 4;
  config.min_peak_separation_deg = 20;
  config.random_seed = 7;
  config.plot_results = true;
  config.wait_for_user = true;

  scenarios = {
    struct("name", "Una fuente", "angles_deg", 60), ...
    struct("name", "Dos fuentes", "angles_deg", [-30, 90])
  };

  results = cell(1, numel(scenarios));
  for scenario_id = 1:numel(scenarios)
    results{scenario_id} = run_scenario(config, scenarios{scenario_id});
  endfor

  if config.plot_results && config.wait_for_user
    drawnow();
    printf("\nLas graficas permaneceran abiertas.\n");
    input("Presiona Enter para terminar la simulacion y cerrar Octave...");
  endif
endfunction

function results = run_corpus_batch(selected_corpus, selected_case)
% Run all cases, one corpus, or one specific case.
  clc;

  if nargin < 1
    selected_corpus = "";
  endif
  if nargin < 2
    selected_case = "";
  endif
  if !isempty(selected_case) && isempty(selected_corpus)
    error("Para elegir un caso tambien debe indicar el corpus.");
  endif

  config.sound_speed = 343;
  config.angle_grid_deg = -180:1:179;
  config.hierarchical_search = true;
  config.coarse_step_deg = 5;
  config.refine_step_deg = 1;
  config.refine_radius_deg = 5;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.min_frequency_hz = 300;
  config.max_frequency_hz = 5000;
  config.music_frequency_stride = 8;
  config.min_peak_separation_deg = 20;
  config.segment_duration_s = 1.0;
  config.save_plots = true;
  config.plot_resolution_dpi = 150;

  if config.save_plots
    toolkits = available_graphics_toolkits();
    if any(strcmp(toolkits, "gnuplot"))
      graphics_toolkit("gnuplot");
    endif
  endif

  localization_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(localization_directory));
  data_root = fullfile(project_root, "data");

  if isempty(selected_corpus)
    output_csv_name = "corpus_localization_results.csv";
  else
    valid_corpora = {"corpus44100", "corpus48000"};
    if !any(strcmp(selected_corpus, valid_corpora))
      error("Corpus invalido. Use 'corpus44100' o 'corpus48000'.");
    endif
    if isempty(selected_case)
      output_csv_name = [selected_corpus, "_localization_results.csv"];
    else
      output_csv_name = [selected_corpus, "_", selected_case, ...
                         "_localization_results.csv"];
    endif
  endif

  output_csv = fullfile(localization_directory, output_csv_name);
  corpus_names = list_subdirectories(data_root);

  if isempty(selected_corpus)
    corpus_mask = strncmp(corpus_names, "corpus", 6);
  else
    corpus_mask = strcmp(corpus_names, selected_corpus);
  endif
  corpus_names = corpus_names(corpus_mask);

  if isempty(corpus_names)
    error("No se encontro el corpus solicitado en %s", data_root);
  endif

  results = struct([]);
  result_id = 0;
  csv_file = fopen(output_csv, "w");
  if csv_file < 0
    error("No se pudo crear el archivo CSV: %s", output_csv);
  endif

  csv_header = ["corpus,caso,fuentes,angulos_reales,metodo,", ...
                "angulos_estimados,errores_por_fuente_grados,", ...
                "error_medio_grados,", ...
                "tiempo_localizacion_ms,preprocesamiento_ms\n"];
  fprintf(csv_file, "%s", csv_header);

  if isempty(selected_corpus)
    printf("\nEvaluando todos los casos de ambos corpus...\n");
  elseif isempty(selected_case)
    printf("\nEvaluando todos los casos de %s...\n", selected_corpus);
  else
    printf("\nEvaluando %s/%s...\n", selected_corpus, selected_case);
  endif
  printf("Fragmento analizado por caso: %.1f segundos\n\n", ...
         config.segment_duration_s);

  for corpus_id = 1:numel(corpus_names)
    corpus_name = corpus_names{corpus_id};
    corpus_path = fullfile(data_root, corpus_name);
    case_names = list_subdirectories(corpus_path);
    if !isempty(selected_case)
      case_names = case_names(strcmp(case_names, selected_case));
      if isempty(case_names)
        error("No existe el caso '%s' dentro de %s.", ...
              selected_case, corpus_name);
      endif
    endif

    for case_id = 1:numel(case_names)
      case_name = case_names{case_id};
      case_path = fullfile(corpus_path, case_name);
      if !exist(fullfile(case_path, "info.txt"), "file")
        continue;
      endif
      try
        [mic_distance_m, true_angles_deg] = read_corpus_info( ...
            fullfile(case_path, "info.txt"));
        [signals, fs] = read_corpus_microphones( ...
            case_path, config.segment_duration_s);

        case_result = localize_corpus_case( ...
            signals, fs, mic_distance_m, true_angles_deg, config);

        if config.save_plots
          output_directory = fullfile(case_path, "localization_results");
          save_corpus_plots(signals, fs, true_angles_deg, case_result, ...
                            config, output_directory);
        endif

        result_id += 1;
        case_result.corpus = corpus_name;
        case_result.case_name = case_name;
        results(result_id) = case_result;

        method_names = fieldnames(case_result.estimates_deg);
        for method_id = 1:numel(method_names)
          method_name = method_names{method_id};
          estimates = case_result.estimates_deg.(method_name);
          errors = case_result.errors_deg.(method_name);
          elapsed_ms = case_result.localization_times_s.(method_name) * 1000;

          fprintf(csv_file, ...
              "%s,%s,%d,\"%s\",%s,\"%s\",\"%s\",%.6f,%.6f,%.6f\n", ...
              corpus_name, case_name, numel(true_angles_deg), ...
              angle_list_text(true_angles_deg), method_label(method_name), ...
              angle_list_text(estimates), angle_list_text(errors), ...
              mean(errors), elapsed_ms, ...
              case_result.preprocessing_time_s * 1000);
        endfor

        printf("[OK] %-11s %-21s fuentes=%d\n", ...
               corpus_name, case_name, numel(true_angles_deg));
      catch error_info
        printf("[ERROR] %s/%s: %s\n", ...
               corpus_name, case_name, error_info.message);
      end_try_catch
    endfor
  endfor

  fclose(csv_file);
  printf("\nResultados guardados en:\n%s\n", output_csv);
endfunction

function directory_names = list_subdirectories(parent_path)
  [entries, error_code, error_message] = readdir(parent_path);
  if error_code != 0
    error("No se pudo leer %s: %s", parent_path, error_message);
  endif

  directory_names = {};
  for entry_id = 1:numel(entries)
    entry_name = entries{entry_id};
    if strcmp(entry_name, ".") || strcmp(entry_name, "..")
      continue;
    endif
    if exist(fullfile(parent_path, entry_name), "dir")
      directory_names{end + 1} = entry_name;
    endif
  endfor
endfunction

function result = localize_corpus_case( ...
    signals, fs, mic_distance_m, true_angles_deg, config)

  number_sources = numel(true_angles_deg);
  mic_positions = aira_microphone_positions(mic_distance_m);
  config.fs = fs;

  preprocessing_timer = tic();
  [stft_data, frequencies_hz] = multichannel_stft( ...
      signals, fs, config.frame_length, config.frame_hop);
  frequency_mask = frequencies_hz >= config.min_frequency_hz & ...
                   frequencies_hz <= config.max_frequency_hz;
  stft_data = stft_data(:, frequency_mask, :);
  frequencies_hz = frequencies_hz(frequency_mask);
  preprocessing_time_s = toc(preprocessing_timer);

  spectra = struct();
  localization_times_s = struct();

  method_timer = tic();
  if number_sources == 1
    spectra.pearson = single_pair_correlation_scan( ...
        signals, mic_positions, config, "pearson");
  else
    spectra.pearson = correlation_scan( ...
        signals, mic_positions, config, "pearson");
  endif
  localization_times_s.pearson = toc(method_timer);

  method_timer = tic();
  if number_sources == 1
    spectra.gcc = single_pair_correlation_scan( ...
        signals, mic_positions, config, "gcc");
  else
    spectra.gcc = correlation_scan(signals, mic_positions, config, "gcc");
  endif
  localization_times_s.gcc = toc(method_timer);

  method_timer = tic();
  spectra.gcc_phat = single_pair_correlation_scan( ...
      signals, mic_positions, config, "phat");
  localization_times_s.gcc_phat = toc(method_timer);

  method_timer = tic();
  spectra.multi_gcc_phat = multi_gcc_phat_scan( ...
      signals, mic_positions, config);
  localization_times_s.multi_gcc_phat = toc(method_timer);

  method_timer = tic();
  spectra.srp_phat = hierarchical_correlation_scan( ...
      signals, mic_positions, config, "phat", number_sources);
  localization_times_s.srp_phat = toc(method_timer);

  method_timer = tic();
  spectra.delay_and_sum = delay_and_sum_scan( ...
      stft_data, frequencies_hz, mic_positions, config, number_sources);
  localization_times_s.delay_and_sum = toc(method_timer);

  method_timer = tic();
  spectra.delay_and_sum_hierarchical = ...
      delay_and_sum_hierarchical_scan( ...
          stft_data, frequencies_hz, mic_positions, config, number_sources);
  localization_times_s.delay_and_sum_hierarchical = toc(method_timer);

  if number_sources < rows(mic_positions)
    method_timer = tic();
    spectra.music = music_scan( ...
        stft_data, frequencies_hz, mic_positions, number_sources, config);
    localization_times_s.music = toc(method_timer);
  else
    spectra.music = [];
    localization_times_s.music = NaN;
  endif

  method_names = fieldnames(spectra);
  estimates = struct();
  errors = struct();
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    if isempty(spectra.(method_name))
      estimates.(method_name) = [];
      errors.(method_name) = NaN;
      continue;
    endif

    peak_timer = tic();
    requested_peaks = method_peak_count(method_name, number_sources);
    estimates.(method_name) = find_spatial_peaks( ...
        spectra.(method_name), config.angle_grid_deg, requested_peaks, ...
        config.min_peak_separation_deg);
    localization_times_s.(method_name) += toc(peak_timer);
    errors.(method_name) = match_doa_errors( ...
        true_angles_deg, estimates.(method_name));
  endfor

  result.true_angles_deg = true_angles_deg;
  result.estimates_deg = estimates;
  result.errors_deg = errors;
  result.localization_times_s = localization_times_s;
  result.preprocessing_time_s = preprocessing_time_s;
  result.spectra = spectra;
endfunction

function [mic_distance_m, angles_deg] = read_corpus_info(info_path)
  file_id = fopen(info_path, "r");
  if file_id < 0
    error("No se pudo leer %s", info_path);
  endif
  lines = textscan(file_id, "%s", "delimiter", "\n");
  fclose(file_id);
  lines = lines{1};

  if numel(lines) < 2
    error("Formato invalido en %s", info_path);
  endif

  mic_distance_m = str2double(strtrim(lines{1}));
  angle_line = strjoin(lines(2:end), " ");
  angles_deg = sscanf(strrep(angle_line, ",", " "), "%f")';
  if isnan(mic_distance_m) || isempty(angles_deg)
    error("No se pudieron interpretar distancia y angulos en %s", info_path);
  endif
endfunction

function [signals, fs] = read_corpus_microphones(case_path, duration_s)
  number_mics = 3;
  sample_rates = zeros(1, number_mics);
  available_samples = zeros(1, number_mics);

  for mic_id = 1:number_mics
    wav_path = fullfile(case_path, sprintf("wav_mic%d.wav", mic_id));
    wav_info = audioinfo(wav_path);
    sample_rates(mic_id) = wav_info.SampleRate;
    available_samples(mic_id) = wav_info.TotalSamples;
  endfor

  if any(sample_rates != sample_rates(1))
    error("Los microfonos no tienen la misma frecuencia de muestreo.");
  endif

  fs = sample_rates(1);
  total_samples = min(available_samples);
  samples = min(total_samples, round(duration_s * fs));
  first_sample = floor((total_samples - samples) / 2) + 1;
  last_sample = first_sample + samples - 1;
  signals = zeros(number_mics, samples);

  for mic_id = 1:number_mics
    wav_path = fullfile(case_path, sprintf("wav_mic%d.wav", mic_id));
    microphone_audio = audioread(wav_path, [first_sample, last_sample]);
    signals(mic_id, :) = microphone_audio(:, 1)';
  endfor
endfunction

function text = angle_list_text(angles)
  if isempty(angles)
    text = "N/A";
  else
    text = strtrim(sprintf("%.2f ", angles));
  endif
endfunction

function save_corpus_plots( ...
    signals, fs, true_angles_deg, result, config, output_directory)

  if !exist(output_directory, "dir")
    mkdir(output_directory);
  endif

  figure_handle = figure("visible", "off");
  if any(strcmp(available_graphics_toolkits(), "gnuplot"))
    graphics_toolkit(figure_handle, "gnuplot");
  endif
  time_ms = (0:columns(signals) - 1) / fs * 1000;
  plot(time_ms, signals');
  grid on;
  xlabel("Tiempo [ms]");
  ylabel("Amplitud");
  title("Senales de los tres microfonos");
  legend("Mic 1", "Mic 2", "Mic 3");
  print(figure_handle, fullfile(output_directory, "signals.png"), ...
        "-dpng", sprintf("-r%d", config.plot_resolution_dpi));
  close(figure_handle);

  method_names = fieldnames(result.spectra);
  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    figure_handle = figure("visible", "off");
    if any(strcmp(available_graphics_toolkits(), "gnuplot"))
      graphics_toolkit(figure_handle, "gnuplot");
    endif

    if isempty(result.spectra.(method_name))
      axis off;
      text(0.5, 0.58, method_label(method_name), ...
           "horizontalalignment", "center", ...
           "fontsize", 16, "fontweight", "bold");
      text(0.5, 0.43, ...
           "No aplicable: numero de fuentes >= numero de microfonos", ...
           "horizontalalignment", "center");
    else
      spectrum_handle = plot( ...
          config.angle_grid_deg, result.spectra.(method_name), ...
          "b-", "linewidth", 1.4);
      hold on;

      true_handles = [];
      for true_angle = true_angles_deg
        true_handles(end + 1) = plot( ...
            [true_angle, true_angle], [0, 1], "g--", "linewidth", 1.4);
      endfor

      estimated_handles = [];
      estimates = result.estimates_deg.(method_name);
      for estimated_angle = estimates
        estimated_handles(end + 1) = plot( ...
            [estimated_angle, estimated_angle], [0, 1], ...
            "r:", "linewidth", 1.6);
      endfor

      grid on;
      axis([-180, 180, 0, 1.05]);
      xlabel("Angulo [grados]");
      ylabel("Espectro normalizado");
      title(method_label(method_name));

      legend_handles = spectrum_handle;
      legend_labels = {"Espectro espacial del metodo"};
      if !isempty(true_handles)
        legend_handles(end + 1) = true_handles(1);
        legend_labels{end + 1} = "Direccion real";
      endif
      if !isempty(estimated_handles)
        legend_handles(end + 1) = estimated_handles(1);
        legend_labels{end + 1} = "Direccion estimada";
      endif
      legend(legend_handles, legend_labels, "location", "northeast");

      errors = result.errors_deg.(method_name);
      elapsed_ms = result.localization_times_s.(method_name) * 1000;
      result_lines = {
        sprintf("Real: %s grados", mat2str(true_angles_deg));
        sprintf("Estimado: %s grados", mat2str(estimates, 4));
        sprintf("Errores: %s grados", mat2str(errors, 4));
        sprintf("Error medio: %.2f grados", mean(errors));
        sprintf("Tiempo: %.3f ms", elapsed_ms)
      };
      add_result_lines(result_lines);
      hold off;
    endif

    output_filename = [method_name, ".png"];
    print(figure_handle, fullfile(output_directory, output_filename), ...
          "-dpng", sprintf("-r%d", config.plot_resolution_dpi));
    close(figure_handle);
  endfor
endfunction

function result = run_scenario(config, scenario)
  number_sources = numel(scenario.angles_deg);
  mic_positions = aira_microphone_positions(config.mic_distance_m);

  set_random_seed(config.random_seed + number_sources);
  sources = create_broadband_sources(number_sources, ...
                                     round(config.duration_s * config.fs), ...
                                     config.fs);

  microphone_signals = simulate_far_field_array( ...
      sources, scenario.angles_deg, mic_positions, config.fs, ...
      config.sound_speed, config.snr_db);

  preprocessing_timer = tic();
  [stft_data, frequencies_hz] = multichannel_stft( ...
      microphone_signals, config.fs, config.frame_length, config.frame_hop);

  frequency_mask = frequencies_hz >= config.min_frequency_hz & ...
                   frequencies_hz <= config.max_frequency_hz;
  stft_data = stft_data(:, frequency_mask, :);
  frequencies_hz = frequencies_hz(frequency_mask);
  preprocessing_time_s = toc(preprocessing_timer);

  spectra = struct();
  localization_times_s = struct();

  method_timer = tic();
  if number_sources == 1
    spectra.pearson = single_pair_correlation_scan( ...
        microphone_signals, mic_positions, config, "pearson");
  else
    spectra.pearson = correlation_scan( ...
        microphone_signals, mic_positions, config, "pearson");
  endif
  localization_times_s.pearson = toc(method_timer);

  method_timer = tic();
  if number_sources == 1
    spectra.gcc = single_pair_correlation_scan( ...
        microphone_signals, mic_positions, config, "gcc");
  else
    spectra.gcc = correlation_scan( ...
        microphone_signals, mic_positions, config, "gcc");
  endif
  localization_times_s.gcc = toc(method_timer);

  method_timer = tic();
  spectra.gcc_phat = single_pair_correlation_scan( ...
      microphone_signals, mic_positions, config, "phat");
  localization_times_s.gcc_phat = toc(method_timer);

  method_timer = tic();
  spectra.multi_gcc_phat = multi_gcc_phat_scan( ...
      microphone_signals, mic_positions, config);
  localization_times_s.multi_gcc_phat = toc(method_timer);

  method_timer = tic();
  spectra.srp_phat = hierarchical_correlation_scan( ...
      microphone_signals, mic_positions, config, "phat", number_sources);
  localization_times_s.srp_phat = toc(method_timer);

  method_timer = tic();
  spectra.delay_and_sum = delay_and_sum_scan( ...
      stft_data, frequencies_hz, mic_positions, config, number_sources);
  localization_times_s.delay_and_sum = toc(method_timer);

  method_timer = tic();
  spectra.delay_and_sum_hierarchical = ...
      delay_and_sum_hierarchical_scan( ...
          stft_data, frequencies_hz, mic_positions, config, number_sources);
  localization_times_s.delay_and_sum_hierarchical = toc(method_timer);

  method_timer = tic();
  spectra.music = music_scan( ...
      stft_data, frequencies_hz, mic_positions, number_sources, config);
  localization_times_s.music = toc(method_timer);

  method_names = fieldnames(spectra);
  estimates = struct();
  errors = struct();

  printf("\n============================================================\n");
  printf("%s | DOA reales: %s grados | SNR: %.1f dB\n", ...
         scenario.name, mat2str(scenario.angles_deg), config.snr_db);
  printf("Preprocesamiento STFT compartido: %.3f ms\n", ...
         preprocessing_time_s * 1000);
  printf("============================================================\n");

  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    peak_timer = tic();
    requested_peaks = method_peak_count(method_name, number_sources);
    estimates.(method_name) = find_spatial_peaks( ...
        spectra.(method_name), config.angle_grid_deg, requested_peaks, ...
        config.min_peak_separation_deg);
    localization_times_s.(method_name) += toc(peak_timer);
    errors.(method_name) = match_doa_errors( ...
        scenario.angles_deg, estimates.(method_name));

    printf("%-16s estimado=%-18s MAE=%6.2f grados tiempo=%9.3f ms\n", ...
           method_label(method_name), ...
           mat2str(estimates.(method_name), 4), ...
           mean(errors.(method_name)), ...
           localization_times_s.(method_name) * 1000);
  endfor

  if config.plot_results
    plot_scenario(scenario, config, microphone_signals, spectra, estimates, ...
                  localization_times_s);
  endif

  result.name = scenario.name;
  result.true_angles_deg = scenario.angles_deg;
  result.estimates_deg = estimates;
  result.errors_deg = errors;
  result.localization_times_s = localization_times_s;
  result.preprocessing_time_s = preprocessing_time_s;
  result.spectra = spectra;
  result.microphone_signals = microphone_signals;
  result.sources = sources;
endfunction

function mic_positions = aira_microphone_positions(distance_m)
% Equilateral triangle, matching the geometry used by the existing scripts.
  mic_positions = [
     0,                 0;
    -distance_m,        0;
    -distance_m / 2,   -sqrt(3) * distance_m / 2
  ];
endfunction

function sources = create_broadband_sources(number_sources, samples, fs)
  sources = zeros(number_sources, samples);
  frequencies_hz = fft_frequency_vector(samples, fs);

  for source_id = 1:number_sources
    noise = randn(1, samples);
    noise_spectrum = fft(noise);

    low_hz = 250 + 350 * (source_id - 1);
    high_hz = min(fs / 2 - 500, 6500 + 500 * (source_id - 1));
    band_mask = abs(frequencies_hz) >= low_hz & ...
                abs(frequencies_hz) <= high_hz;

    shaped_noise = real(ifft(noise_spectrum .* band_mask));
    time_s = (0:samples - 1) / fs;
    tonal_component = 0.25 * sin(2 * pi * (700 + 530 * source_id) * time_s);
    source = shaped_noise + tonal_component;
    sources(source_id, :) = source / (sqrt(mean(source .^ 2)) + eps);
  endfor
endfunction

function microphone_signals = simulate_far_field_array( ...
    sources, source_angles_deg, mic_positions, fs, sound_speed, snr_db)

  [number_sources, samples] = size(sources);
  number_mics = rows(mic_positions);
  microphone_signals = zeros(number_mics, samples);

  for source_id = 1:number_sources
    direction = angle_to_direction(source_angles_deg(source_id));
    % direction points from the array toward the source. A microphone
    % closer to the source receives the wave earlier, hence the minus sign.
    delays_s = -(mic_positions * direction') / sound_speed;

    for mic_id = 1:number_mics
      microphone_signals(mic_id, :) += fractional_delay( ...
          sources(source_id, :), delays_s(mic_id), fs);
    endfor
  endfor

  signal_power = mean(microphone_signals(:) .^ 2);
  noise_power = signal_power / (10 ^ (snr_db / 10));
  microphone_signals += sqrt(noise_power) * randn(size(microphone_signals));
endfunction

function direction = angle_to_direction(angle_deg)
  direction = [sind(angle_deg), cosd(angle_deg)];
endfunction

function delayed = fractional_delay(signal, delay_s, fs)
% Apply a non-circular fractional delay using zero padding and an FFT phase.
  samples = numel(signal);
  margin = ceil(abs(delay_s) * fs) + 32;
  padded = [zeros(1, margin), signal, zeros(1, margin)];
  fft_size = 2 ^ nextpow2(numel(padded));
  padded = [padded, zeros(1, fft_size - numel(padded))];

  frequencies_hz = fft_frequency_vector(fft_size, fs);
  delayed_padded = real(ifft( ...
      fft(padded) .* exp(-1i * 2 * pi * frequencies_hz * delay_s)));
  delayed = delayed_padded(margin + 1:margin + samples);
endfunction

function frequencies_hz = fft_frequency_vector(samples, fs)
  if mod(samples, 2) == 0
    bins = [0:(samples / 2), (-samples / 2 + 1):-1];
  else
    half = floor(samples / 2);
    bins = [0:half, -half:-1];
  endif
  frequencies_hz = bins * fs / samples;
endfunction

function spectrum = correlation_scan(signals, mic_positions, config, mode)
  correlation_data = prepare_pair_correlations(signals, mode);
  spectrum = evaluate_correlation_angles( ...
      correlation_data, mic_positions, config, config.angle_grid_deg);
  spectrum = normalize_spectrum(real(spectrum));
endfunction

function spectrum = hierarchical_correlation_scan( ...
    signals, mic_positions, config, mode, number_sources)

  if !config.hierarchical_search
    spectrum = correlation_scan(signals, mic_positions, config, mode);
    return;
  endif

  correlation_data = prepare_pair_correlations(signals, mode);
  evaluator = @(angles) evaluate_correlation_angles( ...
      correlation_data, mic_positions, config, angles);
  spectrum = hierarchical_spatial_scan(evaluator, config, number_sources);
endfunction

function correlation_data = prepare_pair_correlations(signals, mode)
  pairs = [1, 2; 1, 3; 2, 3];
  correlation_data.pairs = pairs;
  correlation_data.values = cell(1, rows(pairs));
  correlation_data.lags = cell(1, rows(pairs));

  for pair_id = 1:rows(pairs)
    mic_a = pairs(pair_id, 1);
    mic_b = pairs(pair_id, 2);
    [correlation, lags] = generalized_cross_correlation( ...
        signals(mic_a, :), signals(mic_b, :), mode);
    correlation_data.values{pair_id} = ...
        correlation / (max(abs(correlation)) + eps);
    correlation_data.lags{pair_id} = lags;
  endfor
endfunction

function spectrum = evaluate_correlation_angles( ...
    correlation_data, mic_positions, config, angles_deg)

  pairs = correlation_data.pairs;
  directions = [
    sind(angles_deg);
    cosd(angles_deg)
  ];
  spectrum = zeros(1, columns(directions));

  for pair_id = 1:rows(pairs)
    mic_a = pairs(pair_id, 1);
    mic_b = pairs(pair_id, 2);
    correlation = correlation_data.values{pair_id};
    lags = correlation_data.lags{pair_id};

    baseline = mic_positions(mic_a, :) - mic_positions(mic_b, :);
    predicted_lags = -(baseline * directions) * config.fs / ...
                     config.sound_speed;
    spectrum += interp1( ...
        lags, correlation, predicted_lags, "linear", 0);
  endfor
endfunction

function spectrum = single_pair_correlation_scan( ...
    signals, mic_positions, config, mode)
% Reproduce the original one-source approach using microphone 2 vs 1.
% A single pair only resolves the front half-plane, hence [-90, 90].
  mic_a = 2;
  mic_b = 1;
  [correlation, lags] = generalized_cross_correlation( ...
      signals(mic_a, :), signals(mic_b, :), mode);
  correlation /= max(abs(correlation)) + eps;

  spectrum = zeros(1, numel(config.angle_grid_deg));
  baseline = mic_positions(mic_a, :) - mic_positions(mic_b, :);
  for angle_id = 1:numel(config.angle_grid_deg)
    angle_deg = config.angle_grid_deg(angle_id);
    if angle_deg < -90 || angle_deg > 90
      continue;
    endif
    direction = angle_to_direction(angle_deg);
    predicted_lag = -(baseline * direction') * config.fs / ...
                    config.sound_speed;
    spectrum(angle_id) = interp1( ...
        lags, correlation, predicted_lag, "linear", 0);
  endfor

  spectrum = normalize_spectrum(real(spectrum));
endfunction

function spectrum = multi_gcc_phat_scan(signals, mic_positions, config)
% "Patch" from slides 7-28 of M_DOA: interpret several PHAT peaks from the
% same two-microphone correlation as delays from different sources.
% The pair 2-1 only resolves the frontal half-plane [-90, 90].
  spectrum = single_pair_correlation_scan( ...
      signals, mic_positions, config, "phat");
endfunction

function [correlation, lags] = generalized_cross_correlation(x, y, mode)
  x = x(:)' - mean(x);
  y = y(:)' - mean(y);
  samples = numel(x);

  if strcmp(mode, "phat")
    hann_window = 0.5 - 0.5 * cos( ...
        2 * pi * (0:samples - 1) / max(samples - 1, 1));
    x = x .* hann_window;
    y = y .* hann_window;
  endif

  fft_size = 2 ^ nextpow2(2 * samples - 1);

  cross_spectrum = fft(x, fft_size) .* conj(fft(y, fft_size));
  if strcmp(mode, "phat")
    cross_spectrum ./= abs(cross_spectrum) + eps;
  endif

  circular_correlation = real(ifft(cross_spectrum));
  correlation = [circular_correlation(end - samples + 2:end), ...
                 circular_correlation(1:samples)];
  lags = -(samples - 1):(samples - 1);

  if strcmp(mode, "pearson")
    correlation /= (norm(x) * norm(y) + eps);
  elseif strcmp(mode, "gcc")
    correlation /= sqrt(sum(x .^ 2) * sum(y .^ 2)) + eps;
  endif
endfunction

function [stft_data, frequencies_hz] = multichannel_stft( ...
    signals, fs, frame_length, frame_hop)

  [number_mics, samples] = size(signals);
  number_frames = 1 + floor((samples - frame_length) / frame_hop);
  number_bins = frame_length / 2 + 1;
  stft_data = complex(zeros(number_mics, number_bins, number_frames));
  window = 0.5 - 0.5 * cos(2 * pi * (0:frame_length - 1) / ...
                           (frame_length - 1));

  for frame_id = 1:number_frames
    first_sample = (frame_id - 1) * frame_hop + 1;
    frame_indices = first_sample:first_sample + frame_length - 1;

    for mic_id = 1:number_mics
      frame = signals(mic_id, frame_indices) .* window;
      frame_spectrum = fft(frame);
      stft_data(mic_id, :, frame_id) = frame_spectrum(1:number_bins);
    endfor
  endfor

  frequencies_hz = (0:number_bins - 1) * fs / frame_length;
endfunction

function spectrum = delay_and_sum_scan( ...
    stft_data, frequencies_hz, mic_positions, config, number_sources)

  if nargin < 5
    number_sources = 1;
  endif

  spectrum = evaluate_delay_and_sum_angles( ...
      stft_data, frequencies_hz, mic_positions, config, ...
      config.angle_grid_deg);
  spectrum = normalize_spectrum(spectrum);
endfunction

function spectrum = delay_and_sum_hierarchical_scan( ...
    stft_data, frequencies_hz, mic_positions, config, number_sources)

  evaluator = @(angles) evaluate_delay_and_sum_angles( ...
      stft_data, frequencies_hz, mic_positions, config, angles);
  spectrum = hierarchical_spatial_scan(evaluator, config, number_sources);
endfunction

function spectrum = evaluate_delay_and_sum_angles( ...
    stft_data, frequencies_hz, mic_positions, config, angles_deg)

  number_angles = numel(angles_deg);
  number_frames = size(stft_data, 3);
  number_mics = rows(mic_positions);
  spectrum = zeros(1, number_angles);

  directions = [
    sind(angles_deg);
    cosd(angles_deg)
  ];
  delays_s = -(mic_positions * directions) / config.sound_speed;

  for frequency_id = 1:numel(frequencies_hz)
    steering = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
    frequency_frames = reshape( ...
        stft_data(:, frequency_id, :), number_mics, number_frames);
    beamformed = steering' * frequency_frames / number_mics;
    spectrum += mean(abs(beamformed) .^ 2, 2)';
  endfor
endfunction

function spectrum = hierarchical_spatial_scan(evaluator, config, number_sources)
  coarse_angles = -180:config.coarse_step_deg:(180 - config.coarse_step_deg);
  coarse_values = real(evaluator(coarse_angles));
  coarse_values_normalized = normalize_spectrum(coarse_values);

  coarse_candidates = find_spatial_peaks( ...
      coarse_values_normalized, coarse_angles, number_sources, ...
      config.min_peak_separation_deg);

  evaluated_angles = coarse_angles;
  evaluated_values = coarse_values;
  all_refine_angles = [];
  for candidate = coarse_candidates
    refine_angles = candidate - config.refine_radius_deg: ...
                    config.refine_step_deg: ...
                    candidate + config.refine_radius_deg;
    refine_angles = wrap_angles(refine_angles);
    all_refine_angles = [all_refine_angles, refine_angles];
  endfor

  all_refine_angles = unique(all_refine_angles);
  if !isempty(all_refine_angles)
    refine_values = real(evaluator(all_refine_angles));
    evaluated_angles = [evaluated_angles, all_refine_angles];
    evaluated_values = [evaluated_values, refine_values];
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

function wrapped = wrap_angles(angles_deg)
  wrapped = mod(angles_deg + 180, 360) - 180;
endfunction

function spectrum = music_scan( ...
    stft_data, frequencies_hz, mic_positions, number_sources, config)

  number_mics = rows(mic_positions);
  if number_sources >= number_mics
    error("MUSIC requires fewer sources than microphones.");
  endif

  frequency_ids = 1:config.music_frequency_stride:numel(frequencies_hz);
  number_frames = size(stft_data, 3);
  noise_projectors = cell(1, numel(frequency_ids));

  for selected_id = 1:numel(frequency_ids)
    frequency_id = frequency_ids(selected_id);
    frequency_frames = reshape( ...
        stft_data(:, frequency_id, :), number_mics, number_frames);
    covariance = frequency_frames * frequency_frames' / number_frames;
    covariance += 1e-8 * trace(covariance) / number_mics * eye(number_mics);

    [eigenvectors, eigenvalues] = eig(covariance);
    [~, order] = sort(real(diag(eigenvalues)), "descend");
    noise_subspace = eigenvectors(:, order(number_sources + 1:end));
    noise_projectors{selected_id} = noise_subspace * noise_subspace';
  endfor

  spectrum = zeros(1, numel(config.angle_grid_deg));
  for angle_id = 1:numel(config.angle_grid_deg)
    direction = angle_to_direction(config.angle_grid_deg(angle_id));
    delays_s = -(mic_positions * direction') / config.sound_speed;
    music_value = 0;

    for selected_id = 1:numel(frequency_ids)
      frequency_id = frequency_ids(selected_id);
      steering = exp(-1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
      denominator = real(steering' * noise_projectors{selected_id} * steering);
      music_value += 1 / max(denominator, eps);
    endfor

    spectrum(angle_id) = music_value;
  endfor

  spectrum = normalize_spectrum(spectrum);
endfunction

function normalized = normalize_spectrum(spectrum)
  spectrum -= min(spectrum);
  normalized = spectrum / (max(spectrum) + eps);
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
    if isempty(estimates) || all( ...
        angular_distance(candidate_angle, estimates) >= minimum_separation_deg)
      estimates(end + 1) = candidate_angle;
      if numel(estimates) == number_peaks
        break;
      endif
    endif
  endfor

  estimates = sort(estimates);
endfunction

function distances = angular_distance(angle_a, angle_b)
  distances = abs(mod(angle_a - angle_b + 180, 360) - 180);
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
    assigned_true_ids = true_assignments(assignment_id, 1:number_estimated);
    candidate_errors = 180 * ones(size(true_angles));
    candidate_errors(assigned_true_ids) = angular_distance( ...
        true_angles(assigned_true_ids), estimated_angles);
    if mean(candidate_errors) < best_mean
      best_mean = mean(candidate_errors);
      errors = candidate_errors;
    endif
  endfor
endfunction

function number_peaks = method_peak_count(method_name, number_sources)
% Single-source GCC-PHAT reports only its dominant delay. Multi-GCC-PHAT
% explicitly retains one delay peak for each expected source.
  if strcmp(method_name, "gcc_phat")
    number_peaks = 1;
  else
    number_peaks = number_sources;
  endif
endfunction

function label = method_label(method_name)
  switch method_name
    case "pearson"
      label = "Pearson";
    case "gcc"
      label = "GCC";
    case "gcc_phat"
      label = "GCC-PHAT";
    case "multi_gcc_phat"
      label = "Multi-GCC-PHAT";
    case "srp_phat"
      label = "SRP-PHAT";
    case "delay_and_sum"
      label = "Delay-and-Sum";
    case "delay_and_sum_hierarchical"
      label = "Delay-and-Sum Hierarchical";
    case "music"
      label = "MUSIC";
    otherwise
      label = method_name;
  endswitch
endfunction

function plot_scenario( ...
    scenario, config, signals, spectra, estimates, localization_times_s)
  method_names = fieldnames(spectra);

  figure("name", [scenario.name, " - Senales"], "numbertitle", "off");
  time_ms = (0:min(columns(signals), 2400) - 1) / config.fs * 1000;
  plot(time_ms, signals(:, 1:numel(time_ms))');
  grid on;
  xlabel("Tiempo [ms]");
  ylabel("Amplitud");
  title([scenario.name, ": senales de microfonos"]);
  legend("Mic 1", "Mic 2", "Mic 3");
  drawnow();

  for method_id = 1:numel(method_names)
    method_name = method_names{method_id};
    figure_name = [scenario.name, " - ", method_label(method_name)];
    figure("name", figure_name, "numbertitle", "off");
    spectrum_handle = plot( ...
        config.angle_grid_deg, spectra.(method_name), "b-", "linewidth", 1.4);
    hold on;

    true_handles = [];
    for true_angle = scenario.angles_deg
      true_handles(end + 1) = plot( ...
          [true_angle, true_angle], [0, 1], "g--", "linewidth", 1.4);
    endfor

    estimated_handles = [];
    for estimated_angle = estimates.(method_name)
      estimated_handles(end + 1) = plot( ...
          [estimated_angle, estimated_angle], [0, 1], "r:", "linewidth", 1.6);
    endfor

    grid on;
    axis([-180, 180, 0, 1.05]);
    xlabel("Angulo [grados]");
    ylabel("Espectro normalizado");
    title(figure_name);

    legend_handles = spectrum_handle;
    legend_labels = {"Espectro espacial del metodo"};
    if !isempty(true_handles)
      legend_handles(end + 1) = true_handles(1);
      legend_labels{end + 1} = "Direccion real";
    endif
    if !isempty(estimated_handles)
      legend_handles(end + 1) = estimated_handles(1);
      legend_labels{end + 1} = "Direccion estimada";
    endif
    legend(legend_handles, legend_labels, "location", "northeast");

    angular_errors = match_doa_errors( ...
        scenario.angles_deg, estimates.(method_name));
    result_lines = {
      sprintf("Real: %s grados", mat2str(scenario.angles_deg));
      sprintf("Estimado: %s grados", ...
              mat2str(estimates.(method_name), 4));
      sprintf("Errores: %s grados", mat2str(angular_errors, 4));
      sprintf("Error medio: %.2f grados", mean(angular_errors));
      sprintf("Tiempo: %.3f ms", ...
              localization_times_s.(method_name) * 1000)
    };
    add_result_lines(result_lines);

    hold off;
    drawnow();
  endfor
endfunction

function add_result_lines(result_lines)
% Use separate text objects because gnuplot cannot export multiline text.
  first_y = 0.97;
  line_spacing = 0.075;
  for line_id = 1:numel(result_lines)
    text(-172, first_y - (line_id - 1) * line_spacing, ...
         result_lines{line_id}, ...
         "verticalalignment", "top", ...
         "backgroundcolor", "white", ...
         "edgecolor", [0.3, 0.3, 0.3]);
  endfor
endfunction

function set_random_seed(seed)
  rand("seed", seed);
  randn("seed", seed);
endfunction
