function run_das_realtime_gui(initial_case, audio_enabled, max_duration_s)
%RUN_DAS_REALTIME_GUI Interactive block-based DAS separation demo.
%
% The Play button first obtains source directions from the existing
% adaptive DAS localizer. It then separates the complete recording with
% causal WOLA blocks and plays the selected source while processing.
% Changing the source takes effect on the next audio block.
%
% Example:
%   cd Octave/Separacion
%   run_das_realtime_gui("clean-2source");

  if nargin < 1 || isempty(initial_case)
    initial_case = "clean-2source";
  endif
  if nargin < 2 || isempty(audio_enabled)
    audio_enabled = true;
  endif
  if nargin < 3 || isempty(max_duration_s)
    max_duration_s = 30;
  endif

  config.fs = 48000;
  config.sound_speed = 343;
  config.frame_length = 1024;
  config.frame_hop = 512;
  config.frames_per_audio_block = 8;
  config.max_duration_s = max_duration_s;

  separation_directory = fileparts(mfilename("fullpath"));
  project_root = fileparts(fileparts(separation_directory));
  localization_directory = fullfile(project_root, "Octave", "Localizacion");
  corpus_path = fullfile(project_root, "data", "corpus48000");
  localization_csv = fullfile( ...
      separation_directory, "realtime_gui_localization.csv");
  addpath(localization_directory);

  case_names = list_cases(corpus_path);
  if isempty(case_names)
    error("No se encontraron casos en %s.", corpus_path);
  endif
  initial_id = find(strcmp(case_names, char(initial_case)), 1);
  if isempty(initial_id)
    initial_id = 1;
  endif

  figure_handle = figure( ...
      "name", "Separacion DAS en tiempo real", ...
      "numbertitle", "off", ...
      "menubar", "none", ...
      "toolbar", "none", ...
      "position", [200, 150, 760, 430], ...
      "closerequestfcn", @on_close);

  uicontrol(figure_handle, ...
      "style", "text", ...
      "string", "Caso", ...
      "horizontalalignment", "left", ...
      "position", [30, 385, 80, 24]);
  case_popup = uicontrol(figure_handle, ...
      "style", "popupmenu", ...
      "string", case_names, ...
      "value", initial_id, ...
      "position", [90, 385, 210, 28]);

  play_button = uicontrol(figure_handle, ...
      "style", "pushbutton", ...
      "string", "Play", ...
      "fontsize", 11, ...
      "position", [325, 382, 105, 34], ...
      "callback", @on_play);
  stop_button = uicontrol(figure_handle, ...
      "style", "pushbutton", ...
      "string", "Stop", ...
      "fontsize", 11, ...
      "enable", "off", ...
      "position", [445, 382, 105, 34], ...
      "callback", @on_stop);

  uicontrol(figure_handle, ...
      "style", "text", ...
      "string", "Fuente escuchada", ...
      "horizontalalignment", "left", ...
      "position", [30, 342, 120, 24]);
  source_popup = uicontrol(figure_handle, ...
      "style", "popupmenu", ...
      "string", {"Fuente 1"}, ...
      "value", 1, ...
      "enable", "off", ...
      "position", [150, 342, 280, 28], ...
      "callback", @on_source_changed);

  status_text = uicontrol(figure_handle, ...
      "style", "text", ...
      "string", "Listo.", ...
      "horizontalalignment", "left", ...
      "fontsize", 10, ...
      "position", [30, 305, 690, 25]);
  progress_text = uicontrol(figure_handle, ...
      "style", "text", ...
      "string", "0.0 / 0.0 s", ...
      "horizontalalignment", "right", ...
      "position", [570, 385, 150, 24]);

  axes_handle = axes( ...
      "parent", figure_handle, ...
      "units", "pixels", ...
      "position", [55, 65, 665, 220]);
  waveform_line = plot(axes_handle, 0, 0, "b-");
  grid(axes_handle, "on");
  xlabel(axes_handle, "Tiempo dentro del bloque (ms)");
  ylabel(axes_handle, "Amplitud");
  title(axes_handle, "Bloque reproducido");
  axis(axes_handle, [0, 100, -1, 1]);

  state.running = false;
  state.paused = false;
  state.stop_requested = false;
  state.selected_source = 1;
  state.player = [];
  state.source_labels = {"Fuente 1"};
  guidata(figure_handle, state);

  function on_play(~, ~)
    if !ishandle(figure_handle)
      return;
    endif
    current = guidata(figure_handle);
    if current.running
      current.paused = !current.paused;
      if current.paused
        set(play_button, "string", "Reanudar");
        set(status_text, "string", "Pausado.");
        if !isempty(current.player) && isplaying(current.player)
          pause(current.player);
        endif
      else
        set(play_button, "string", "Pausa");
        set(status_text, "string", "Procesando y reproduciendo.");
        if !isempty(current.player)
          resume(current.player);
        endif
      endif
      guidata(figure_handle, current);
      return;
    endif

    current.running = true;
    current.paused = false;
    current.stop_requested = false;
    current.selected_source = 1;
    guidata(figure_handle, current);
    set(play_button, "string", "Pausa");
    set(stop_button, "enable", "on");
    set(case_popup, "enable", "off");
    run_demo();
  endfunction

  function on_stop(~, ~)
    if !ishandle(figure_handle)
      return;
    endif
    current = guidata(figure_handle);
    current.stop_requested = true;
    current.paused = false;
    if !isempty(current.player)
      stop(current.player);
    endif
    guidata(figure_handle, current);
  endfunction

  function on_source_changed(~, ~)
    current = guidata(figure_handle);
    current.selected_source = get(source_popup, "value");
    guidata(figure_handle, current);
    if current.running
      set(status_text, "string", sprintf( ...
          "Cambio a %s en el siguiente bloque.", ...
          current.source_labels{current.selected_source}));
    endif
  endfunction

  function on_close(~, ~)
    if !ishandle(figure_handle)
      return;
    endif
    current = guidata(figure_handle);
    current.stop_requested = true;
    if !isempty(current.player)
      stop(current.player);
    endif
    guidata(figure_handle, current);
    delete(figure_handle);
  endfunction

  function run_demo()
    unwind_protect
      case_id = get(case_popup, "value");
      case_name = case_names{case_id};
      case_path = fullfile(corpus_path, case_name);
      set(status_text, "string", ...
          "Localizando fuentes con DAS adaptativo...");
      drawnow();

      localization = run_wola_das_adaptive_mask( ...
          {case_name}, localization_csv);
      if isempty(localization)
        error("No se obtuvieron direcciones para %s.", case_name);
      endif
      angles_deg = localization(1).estimates_deg.adaptive;
      if isempty(angles_deg)
        error("El localizador no encontro fuentes.");
      endif

      [mic_distance_m, ~] = read_case_info( ...
          fullfile(case_path, "info.txt"));
      signals = read_microphone_signals(case_path, config);
      mic_positions = aira_microphone_positions(mic_distance_m);
      processor = initialize_processor( ...
          signals, angles_deg, mic_positions, config);

      labels = cell(1, numel(angles_deg));
      for source_id = 1:numel(angles_deg)
        labels{source_id} = sprintf( ...
            "Fuente %d: %.1f grados", source_id, angles_deg(source_id));
      endfor
      current = guidata(figure_handle);
      current.source_labels = labels;
      current.selected_source = min(current.selected_source, numel(labels));
      guidata(figure_handle, current);
      set(source_popup, ...
          "string", labels, ...
          "value", current.selected_source, ...
          "enable", "on");
      set(status_text, "string", sprintf( ...
          "DOAs: %s grados. Preparando audio...", ...
          strtrim(sprintf("%.1f ", angles_deg))));
      set(progress_text, "string", sprintf( ...
          "0.0 / %.1f s", columns(signals) / config.fs));
      drawnow();

      [next_audio, processor] = process_audio_block( ...
          processor, signals, config);
      while !isempty(next_audio)
        current = guidata(figure_handle);
        if current.stop_requested || !ishandle(figure_handle)
          break;
        endif

        wait_while_paused();
        current = guidata(figure_handle);
        selected_source = min( ...
            current.selected_source, rows(next_audio));
        playback = limit_audio(next_audio(selected_source, :));
        player = [];
        if audio_enabled
          player = audioplayer(playback', config.fs);
          current.player = player;
          guidata(figure_handle, current);
          play(player);
        endif

        time_ms = (0:numel(playback) - 1) * 1000 / config.fs;
        set(waveform_line, "xdata", time_ms, "ydata", playback);
        axis(axes_handle, [0, max(time_ms(end), 1), -1, 1]);
        title(axes_handle, current.source_labels{selected_source});
        set(status_text, "string", sprintf( ...
            "Procesando y escuchando %s.", ...
            current.source_labels{selected_source}));

        [queued_audio, processor] = process_audio_block( ...
            processor, signals, config);
        update_progress(processor, columns(signals));
        drawnow();

        while audio_enabled && isplaying(player)
          current = guidata(figure_handle);
          if current.stop_requested
            stop(player);
            break;
          endif
          if current.paused
            wait_while_paused();
          endif
          drawnow();
          builtin("pause", 0.01);
        endwhile
        next_audio = queued_audio;
      endwhile

      current = guidata(figure_handle);
      if current.stop_requested
        set(status_text, "string", "Detenido.");
      else
        set(status_text, "string", "Reproduccion terminada.");
        set(progress_text, "string", sprintf( ...
            "%.1f / %.1f s", columns(signals) / config.fs, ...
            columns(signals) / config.fs));
      endif
    unwind_protect_cleanup
      if ishandle(figure_handle)
        current = guidata(figure_handle);
        if !isempty(current.player)
          stop(current.player);
        endif
        current.running = false;
        current.paused = false;
        current.stop_requested = false;
        current.player = [];
        guidata(figure_handle, current);
        set(play_button, "string", "Play");
        set(stop_button, "enable", "off");
        set(case_popup, "enable", "on");
      endif
    end_unwind_protect
  endfunction

  function wait_while_paused()
    while ishandle(figure_handle)
      current = guidata(figure_handle);
      if !current.paused || current.stop_requested
        break;
      endif
      drawnow();
      builtin("pause", 0.02);
    endwhile
  endfunction

  function update_progress(processor, total_samples)
    processed_sample = min( ...
        total_samples, processor.last_emitted_sample);
    set(progress_text, "string", sprintf( ...
        "%.1f / %.1f s", processed_sample / config.fs, ...
        total_samples / config.fs));
  endfunction
endfunction

function processor = initialize_processor( ...
    signals, angles_deg, mic_positions, config)

  samples = columns(signals);
  number_bins = config.frame_length / 2 + 1;
  frequencies_hz = (0:number_bins - 1) * ...
                   config.fs / config.frame_length;
  directions = [sind(angles_deg); cosd(angles_deg)];
  delays_s = -(mic_positions * directions) / config.sound_speed;
  number_mics = rows(signals);

  steering = complex(zeros(number_mics, numel(angles_deg), number_bins));
  for frequency_id = 1:number_bins
    steering(:, :, frequency_id) = exp( ...
        -1i * 2 * pi * frequencies_hz(frequency_id) * delays_s);
  endfor

  processor.window = periodic_hann(config.frame_length);
  processor.frame_starts = ...
      1:config.frame_hop:(samples - config.frame_length + 1);
  processor.next_frame = 1;
  processor.last_emitted_sample = 0;
  processor.steering = steering;
  processor.output_accumulator = zeros( ...
      numel(angles_deg), samples + config.frame_length);
  processor.normalization = zeros(1, samples + config.frame_length);
endfunction

function [audio_block, processor] = process_audio_block( ...
    processor, signals, config)

  if processor.next_frame > numel(processor.frame_starts)
    audio_block = [];
    return;
  endif

  number_mics = rows(signals);
  number_sources = rows(processor.output_accumulator);
  number_bins = config.frame_length / 2 + 1;
  first_frame_id = processor.next_frame;
  last_frame_id = min( ...
      numel(processor.frame_starts), ...
      first_frame_id + config.frames_per_audio_block - 1);

  for frame_id = first_frame_id:last_frame_id
    frame_start = processor.frame_starts(frame_id);
    frame_range = frame_start:frame_start + config.frame_length - 1;
    frame = signals(:, frame_range) .* ...
            repmat(processor.window, number_mics, 1);
    spectrum = fft(frame, [], 2);
    one_sided = spectrum(:, 1:number_bins);

    for source_id = 1:number_sources
      output_spectrum = complex(zeros(1, config.frame_length));
      steering = squeeze( ...
          processor.steering(:, source_id, :));
      output_spectrum(1:number_bins) = ...
          sum(conj(steering) .* one_sided, 1) / number_mics;
      output_spectrum(number_bins + 1:end) = ...
          conj(output_spectrum(number_bins - 1:-1:2));
      output_frame = real(ifft(output_spectrum)) .* processor.window;
      processor.output_accumulator(source_id, frame_range) += output_frame;
    endfor
    processor.normalization(frame_range) += processor.window .^ 2;
  endfor

  emit_start = processor.last_emitted_sample + 1;
  last_frame_start = processor.frame_starts(last_frame_id);
  if last_frame_id == numel(processor.frame_starts)
    emit_end = min(columns(signals), ...
                   last_frame_start + config.frame_length - 1);
  else
    emit_end = last_frame_start + config.frame_hop - 1;
  endif

  normalization = processor.normalization(emit_start:emit_end);
  audio_block = processor.output_accumulator(:, emit_start:emit_end);
  valid = normalization > 1e-8;
  audio_block(:, valid) ./= repmat( ...
      normalization(valid), number_sources, 1);
  audio_block(:, !valid) = 0;

  processor.next_frame = last_frame_id + 1;
  processor.last_emitted_sample = emit_end;
endfunction

function signals = read_microphone_signals(case_path, config)
  paths = {
    fullfile(case_path, "wav_mic1.wav"), ...
    fullfile(case_path, "wav_mic2.wav"), ...
    fullfile(case_path, "wav_mic3.wav")
  };
  [first_signal, fs] = audioread(paths{1});
  if fs != config.fs
    error("%s tiene fs=%d; se esperaba %d.", paths{1}, fs, config.fs);
  endif
  target_samples = min( ...
      rows(first_signal), round(config.max_duration_s * config.fs));
  signals = zeros(3, target_samples);
  signals(1, :) = first_signal(1:target_samples, 1)';
  for microphone_id = 2:3
    [signal, signal_fs] = audioread(paths{microphone_id});
    if signal_fs != config.fs || rows(signal) < target_samples
      error("Audio incompatible: %s", paths{microphone_id});
    endif
    signals(microphone_id, :) = signal(1:target_samples, 1)';
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

function names = list_cases(corpus_path)
  candidates = {
    "clean-1source", ...
    "clean-2source", ...
    "clean-2source090", ...
    "clean-2source090_2", ...
    "clean-3source", ...
    "clean-3source090180", ...
    "clean-4source", ...
    "noisy-1source", ...
    "noisy-2source", ...
    "noisy-2source090", ...
    "noisy-3source", ...
    "noisy-3source090180", ...
    "noisy-4source"
  };
  names = {};
  for candidate_id = 1:numel(candidates)
    case_path = fullfile(corpus_path, candidates{candidate_id});
    if exist(fullfile(case_path, "info.txt"), "file") && ...
       exist(fullfile(case_path, "wav_mic1.wav"), "file")
      names{end + 1} = candidates{candidate_id};
    endif
  endfor
endfunction

function limited = limit_audio(signal)
  peak = max(abs(signal));
  if peak > 0.98
    limited = 0.98 * signal / peak;
  else
    limited = signal;
  endif
endfunction

function window = periodic_hann(length_samples)
  window = 0.5 - 0.5 * cos( ...
      2 * pi * (0:length_samples - 1) / length_samples);
endfunction
