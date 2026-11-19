% Parallel DTD Processing Script - Optimized for MacBook
% Processes multiple subjects in parallel using MATLAB's Parallel Computing Toolbox

clear all;
close all;
clearvars;

% =========================================================================
% CONFIGURATION
% =========================================================================

% Set timezone
setenv('TZ', 'America/Los_Angeles');

% Paths - EDIT THESE
bids_path    = '/path/to/bids';            % BIDS dataset (used to list subjects)
scripts_path = '/path/to/dtd_scripts';     % folder containing runmydtd.m
mdmri_path   = '/path/to/md-dmri';         % md-dmri toolbox
log_dir      = '/path/to/results/parallel_logs';

% Add path to the parallel function
addpath(genpath(scripts_path));

% =========================================================================
% SUBJECT LIST
% =========================================================================

% All subjects in the BIDS folder
% (or replace with an explicit list, e.g. subjects = {'sub-01'; 'sub-02'};)
sub_dirs = dir(fullfile(bids_path, 'sub-*'));
sub_dirs = sub_dirs([sub_dirs.isdir]);
subjects = {sub_dirs.name}';

fprintf('Total subjects to process: %d\n\n', length(subjects));

% =========================================================================
% PARALLEL PROCESSING CONFIGURATION
% =========================================================================

% Determine optimal number of workers for your MacBook
% Rule of thumb: Use (CPU cores - 1) to leave one core for system
% For M1/M2/M3 Macs: Check your CPU cores in System Settings > General > About
% Typical values: M1 = 8 cores, M1 Pro = 8-10 cores, M1 Max = 10 cores

% Auto-detect number of CPU cores
num_cores = feature('numcores');
fprintf('Detected %d CPU cores\n', num_cores);

% Set number of workers (leave 1-2 cores free for system)
if num_cores >= 8
    num_workers = num_cores - 2;  % Use all but 2 cores
elseif num_cores >= 4
    num_workers = num_cores - 1;  % Use all but 1 core
else
    num_workers = 2;  % Minimum 2 workers
end

fprintf('Using %d parallel workers\n\n', num_workers);

% =========================================================================
% SETUP PARALLEL POOL
% =========================================================================

% Check if a parallel pool is already running
poolobj = gcp('nocreate');

if isempty(poolobj)
    % Create new parallel pool with proper path configuration
    fprintf('Starting parallel pool with %d workers...\n', num_workers);
    
    % Create pool with attached files to ensure paths work
    poolobj = parpool('local', num_workers);
    fprintf('Parallel pool started successfully\n\n');
else
    % Pool already exists
    fprintf('Parallel pool already running with %d workers\n\n', poolobj.NumWorkers);
    
    % If different number of workers needed, restart the pool
    if poolobj.NumWorkers ~= num_workers
        fprintf('Restarting pool with %d workers...\n', num_workers);
        delete(poolobj);
        poolobj = parpool('local', num_workers);
    end
end

% Ensure all workers have access to necessary paths
% (workers need the md-dmri toolbox on their path)
fprintf('Adding md-dmri toolbox to path...\n');
if ~contains(path, mdmri_path)
    addpath(genpath(mdmri_path));
    fprintf('Path added successfully\n\n');
else
    fprintf('Path already in MATLAB path\n\n');
end

% =========================================================================
% PROCESS SUBJECTS IN PARALLEL
% =========================================================================

fprintf('========================================\n');
fprintf('Starting parallel processing\n');
fprintf('========================================\n\n');

% Create log directory for parallel worker outputs
if ~exist(log_dir, 'dir')
    mkdir(log_dir);
end

% Track start time
tic;

% Create arrays to track success/failure
subject_names = cell(length(subjects), 1);
status_messages = cell(length(subjects), 1);

% Process subjects in parallel using parfor
parfor i = 1:length(subjects)
    subject_id = subjects{i};
    
    try
        % Call the parallel DTD function
        runmydtd(subject_id);
        
        % Mark as successful
        subject_names{i} = subject_id;
        status_messages{i} = 'SUCCESS';
        
    catch ME
        % Mark as failed and capture error
        subject_names{i} = subject_id;
        status_messages{i} = sprintf('FAILED: %s', ME.message);
        
        % Save detailed error log
        error_log = fullfile(log_dir, sprintf('%s_error.txt', subject_id));
        fid = fopen(error_log, 'w');
        fprintf(fid, 'Error processing %s\n\n', subject_id);
        fprintf(fid, 'Message: %s\n\n', ME.message);
        fprintf(fid, 'Stack trace:\n');
        for k = 1:length(ME.stack)
            fprintf(fid, '  File: %s\n', ME.stack(k).file);
            fprintf(fid, '  Line: %d\n', ME.stack(k).line);
            fprintf(fid, '  Function: %s\n\n', ME.stack(k).name);
        end
        fclose(fid);
    end
end

% Combine results for reporting
results = [subject_names, status_messages];

% Calculate total time
total_time = toc;

% =========================================================================
% SUMMARY REPORT
% =========================================================================

fprintf('\n========================================\n');
fprintf('PROCESSING COMPLETE\n');
fprintf('========================================\n\n');

fprintf('Total time: %.2f minutes (%.2f hours)\n', total_time/60, total_time/3600);
fprintf('Average time per subject: %.2f minutes\n\n', total_time/60/length(subjects));

% Count successes and failures
num_success = sum(strcmp(results(:, 2), 'SUCCESS'));
num_failed = length(subjects) - num_success;

fprintf('Successfully processed: %d/%d subjects\n', num_success, length(subjects));
fprintf('Failed: %d subjects\n\n', num_failed);

% List successful subjects
if num_success > 0
    fprintf('Successful subjects:\n');
    for i = 1:length(subjects)
        if strcmp(results{i, 2}, 'SUCCESS')
            fprintf('  ✓ %s\n', results{i, 1});
        end
    end
    fprintf('\n');
end

% List failed subjects
if num_failed > 0
    fprintf('Failed subjects:\n');
    for i = 1:length(subjects)
        if ~strcmp(results{i, 2}, 'SUCCESS')
            fprintf('  ✗ %s: %s\n', results{i, 1}, results{i, 2});
        end
    end
    fprintf('\n');
    fprintf('Error logs saved to: %s\n\n', log_dir);
end

% Save summary report
summary_file = fullfile(log_dir, sprintf('processing_summary_%s.txt', datestr(now, 'yyyymmdd_HHMMSS')));
fid = fopen(summary_file, 'w');
fprintf(fid, 'DTD Processing Summary\n');
fprintf(fid, 'Date: %s\n\n', datestr(now));
fprintf(fid, 'Total subjects: %d\n', length(subjects));
fprintf(fid, 'Successful: %d\n', num_success);
fprintf(fid, 'Failed: %d\n\n', num_failed);
fprintf(fid, 'Total time: %.2f minutes\n', total_time/60);
fprintf(fid, 'Average time per subject: %.2f minutes\n\n', total_time/60/length(subjects));

fprintf(fid, 'Detailed Results:\n');
fprintf(fid, '----------------------------------------\n');
for i = 1:length(subjects)
    fprintf(fid, '%s: %s\n', results{i, 1}, results{i, 2});
end
fclose(fid);

fprintf('Summary saved to: %s\n', summary_file);

% =========================================================================
% CLEANUP (OPTIONAL)
% =========================================================================

% Uncomment the following line to automatically shut down the parallel pool
% delete(gcp('nocreate'));