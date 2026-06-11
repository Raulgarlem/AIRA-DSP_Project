clear;
clc;

% Leave only the corpus case you want to run uncommented.
case_name = 'clean-2source';
% case_name = 'clean-3source';
% case_name = 'clean-4source';
% case_name = 'noisy-2source';
% case_name = 'noisy-3source';
% case_name = 'noisy-4source';

num_iterations = 3;
cancellation_factor = 0.70;

results = run_full_das_iterative_sic( ...
  case_name, num_iterations, cancellation_factor);
