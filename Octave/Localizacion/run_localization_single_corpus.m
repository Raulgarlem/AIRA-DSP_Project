function results = run_localization_single_corpus(corpus_name, case_name)
%RUN_LOCALIZATION_SINGLE_CORPUS Evaluate one corpus or one specific case.
%
% Examples:
%   results = run_localization_single_corpus("corpus44100");
%   results = run_localization_single_corpus("corpus48000");
%   results = run_localization_single_corpus( ...
%       "corpus48000", "clean-2source090");

  if nargin < 1
    error(["Debe indicar el corpus: ", ...
           "'corpus44100' o 'corpus48000'."]);
  endif
  if nargin < 2
    case_name = "";
  endif

  results = run_localization_simulation("corpus", corpus_name, case_name);
endfunction
