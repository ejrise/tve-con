function runmydtd(subject_id)
% DTD processing for a single subject - parallelizable version
%
% Usage: runmydtd('sub-01')
%
% This function:
%   1. Creates merged xps structure from separate bval/bvec files
%   2. Performs motion/eddy correction
%   3. Creates brain mask
%   4. Runs DTD fitting

% =========================================================================
% CONFIGURATION - UPDATE THESE PATHS FOR YOUR SYSTEM
% =========================================================================

% Base paths - use FULL paths, not ~ (for parallel workers)
bids_path = '/path/to/bids';
results_path = '/path/to/results';

% Add md-dmri toolbox to path (only if not already added)
mdmri_path = '/path/to/md-dmri';
if ~contains(path, mdmri_path)
    addpath(genpath(mdmri_path));
end

% FSL configuration
setenv('FSLDIR', '/path/to/fsl');
setenv('FSLOUTPUTTYPE', 'NIFTI_GZ');
fsl_bin = fullfile(getenv('FSLDIR'), 'bin', 'fslmaths');

% =========================================================================
% SUBJECT-SPECIFIC PATHS
% =========================================================================

fprintf('\n========================================\n');
fprintf('Processing subject: %s\n', subject_id);
fprintf('========================================\n\n');

% Path to original bval/bvec files
original_data_path = fullfile(bids_path, subject_id, 'dwi');

% Path to denoised NIfTI file
denoised_nii_fn = fullfile(results_path, '01_denoised', subject_id, 'dwi', ...
    sprintf('%s_concat_dwi_denoised.nii.gz', subject_id));

% Check if denoised file exists
if ~exist(denoised_nii_fn, 'file')
    error('Denoised file not found: %s', denoised_nii_fn);
end

% =========================================================================
% BVAL/BVEC FILE NAMES
% =========================================================================

% Define the 8 pairs of bval/bvec files in chronological order
% Pattern: {subject_id}_acq-{type}_run-{num}_dwi.{ext}
bval_files = {
    sprintf('%s_acq-linear_run-1_dwi.bval', subject_id),
    sprintf('%s_acq-linear_run-2_dwi.bval', subject_id),
    sprintf('%s_acq-linear_run-3_dwi.bval', subject_id),
    sprintf('%s_acq-linear_run-4_dwi.bval', subject_id),
    sprintf('%s_acq-spherical_run-5_dwi.bval', subject_id),
    sprintf('%s_acq-spherical_run-6_dwi.bval', subject_id),
    sprintf('%s_acq-spherical_run-7_dwi.bval', subject_id),
    sprintf('%s_acq-spherical_run-8_dwi.bval', subject_id)
};

bvec_files = {
    sprintf('%s_acq-linear_run-1_dwi.bvec', subject_id),
    sprintf('%s_acq-linear_run-2_dwi.bvec', subject_id),
    sprintf('%s_acq-linear_run-3_dwi.bvec', subject_id),
    sprintf('%s_acq-linear_run-4_dwi.bvec', subject_id),
    sprintf('%s_acq-spherical_run-5_dwi.bvec', subject_id),
    sprintf('%s_acq-spherical_run-6_dwi.bvec', subject_id),
    sprintf('%s_acq-spherical_run-7_dwi.bvec', subject_id),
    sprintf('%s_acq-spherical_run-8_dwi.bvec', subject_id)
};

% B-tensor shapes for each acquisition
% 1 = linear, 0 = spherical
b_deltas = [1, 1, 1, 1, 0, 0, 0, 0];

% =========================================================================
% CREATE INDIVIDUAL XPS STRUCTURES
% =========================================================================

fprintf('Creating individual xps structures...\n');

% Initialize cell array for partial s structures
s = cell(1, 8);

% Loop over each acquisition to create xps structures
for i = 1:8
    % Full paths to bval/bvec files
    bval_fn = fullfile(original_data_path, bval_files{i});
    bvec_fn = fullfile(original_data_path, bvec_files{i});
    
    % Check if files exist
    if ~exist(bval_fn, 'file')
        error('Could not find bval file: %s', bval_fn);
    end
    if ~exist(bvec_fn, 'file')
        error('Could not find bvec file: %s', bvec_fn);
    end

    % Create xps structure from bval and bvec
    s{i}.nii_fn = sprintf('placeholder_acq%d.nii', i);
    s{i}.xps = mdm_xps_from_bval_bvec(bval_fn, bvec_fn, b_deltas(i));
    
    fprintf('  Acquisition %d: %d volumes, b_delta = %.5f\n', ...
        i, s{i}.xps.n, b_deltas(i));
end

% =========================================================================
% MERGE XPS STRUCTURES
% =========================================================================

fprintf('\nMerging xps structures...\n');

% Merge all xps structures into one
xps_cell = cell(1, 8);
for i = 1:8
    xps_cell{i} = s{i}.xps;
end

xps_merged = mdm_xps_merge(xps_cell);

fprintf('Total volumes in merged xps: %d\n', xps_merged.n);

% =========================================================================
% SAVE MERGED XPS
% =========================================================================

% Generate the standard xps filename based on the nii filename
xps_fn = mdm_xps_fn_from_nii_fn(denoised_nii_fn);

fprintf('Saving merged xps to: %s\n', xps_fn);
mdm_xps_save(xps_merged, xps_fn);

% =========================================================================
% MOTION AND EDDY CURRENT CORRECTION
% =========================================================================

fprintf('\n=== Starting Motion and Eddy Current Correction ===\n');

% Check if FSL is available
if ~exist(fsl_bin, 'file')
    error('FSL not found at: %s\nPlease install FSL or update the path.', fsl_bin);
end

% Set up options
opt = mdm_opt;

% Set up the s structure with the concatenated/denoised NIfTI and merged xps
s_merged = struct();
s_merged.nii_fn = denoised_nii_fn;
s_merged.xps = xps_merged;

% Output path (same directory as the denoised NIfTI)
[o_path, ~, ~] = fileparts(denoised_nii_fn);
if isempty(o_path)
    o_path = pwd;
end

% Create reference volume by subsampling low b-value data (b <= 1000 s/mm^2)
fprintf('Creating reference volume from low b-value data...\n');
s_ref = mdm_s_subsample(s_merged, xps_merged.b <= 1e9, o_path, opt);

% Elastix configuration
elastix_path = '/path/to/elastix';
setenv('PATH', [fullfile(elastix_path, 'bin') ':' getenv('PATH')]);
setenv('DYLD_LIBRARY_PATH', [fullfile(elastix_path, 'lib') ':' getenv('DYLD_LIBRARY_PATH')]);

% Set up elastix parameters for affine registration
fprintf('Setting up elastix parameters...\n');
p = elastix_p_affine;
p_fn = elastix_p_write(p, fullfile(o_path, 'p.txt'));

% Perform b0-based motion correction on reference
fprintf('Performing b0-based motion correction on reference...\n');
s_ref = mdm_mec_b0(s_ref, p_fn, o_path, opt);

% Perform extrapolation-based motion correction on full dataset
fprintf('Performing extrapolation-based motion correction on full dataset...\n');
fprintf('This may take a while...\n');
s_registered = mdm_mec_eb(s_merged, s_ref, p_fn, o_path, opt);

% =========================================================================
% CREATE BRAIN MASK USING FSL
% =========================================================================

fprintf('\n=== Creating brain mask using FSL ===\n');

% Get the base filename without extension
[~, base_name, ~] = fileparts(denoised_nii_fn);
base_name = strrep(base_name, '.nii', ''); % Remove .nii if it's .nii.gz

% Motion-corrected filename
mc_nii_fn = fullfile(o_path, [base_name '_mc.nii.gz']);

% Create mean image
fprintf('Creating mean image...\n');
mean_fn = fullfile(o_path, 'mean.nii.gz');
cmd = sprintf('%s "%s" -Tmean "%s"', fsl_bin, mc_nii_fn, strrep(mean_fn, '.nii.gz', ''));
system(cmd);

% Create binary mask (threshold at 100)
fprintf('Creating binary mask...\n');
mask_fn = fullfile(o_path, 'mask.nii.gz');
cmd = sprintf('%s "%s" -thr 100 -bin "%s"', fsl_bin, mean_fn, strrep(mask_fn, '.nii.gz', ''));
system(cmd);

% =========================================================================
% CLEAN UP INTERMEDIATE FILES
% =========================================================================

fprintf('\n=== Cleaning up intermediate files ===\n');

% Get the list of intermediate files to remove
[~, nii_base, ~] = fileparts(denoised_nii_fn);
nii_base = strrep(nii_base, '.nii', '');

cleanup_patterns = {
    [nii_base '_sub_mc.nii.gz']
    [nii_base '_sub.nii.gz']
    [nii_base '_sub_mc_xps.mat']
    [nii_base '_tp.txt']
    [nii_base '_sub_ref.nii.gz']
    [nii_base '_sub_tp.txt']
    [nii_base '_ref.nii.gz']
    [nii_base '_sub_xps.mat']
    'p.txt'
    'mean.nii.gz'
};

for i = 1:length(cleanup_patterns)
    file_to_delete = fullfile(o_path, cleanup_patterns{i});
    if exist(file_to_delete, 'file')
        delete(file_to_delete);
        fprintf('  Deleted: %s\n', cleanup_patterns{i});
    end
end

% =========================================================================
% RUN DTD FITTING
% =========================================================================

fprintf('\n=== Running DTD fitting ===\n');

% Motion-corrected xps filename
mc_xps_fn = fullfile(o_path, [base_name '_mc_xps.mat']);

% Run mdm_fit for DTD
mdm_fit_cmd = sprintf(['mdm_fit --data ''%s'' ', ...
    '--mask ''%s'' ', ...
    '--method dtd ', ...
    '--out ''%s'' ', ...
    '--xps ''%s'''], ...
    mc_nii_fn, mask_fn, o_path, mc_xps_fn);

fprintf('Running DTD fit:\n%s\n\n', mdm_fit_cmd);
eval(mdm_fit_cmd);

% Run mdm_fit for DTD covariance
mdm_fit_cmd2 = sprintf(['mdm_fit --data ''%s'' ', ...
    '--mask ''%s'' ', ...
    '--method dtd_covariance ', ...
    '--out ''%s'' ', ...
    '--xps ''%s'''], ...
    mc_nii_fn, mask_fn, o_path, mc_xps_fn);

fprintf('Running DTD covariance fit:\n%s\n\n', mdm_fit_cmd2);
eval(mdm_fit_cmd2);

% =========================================================================
% COMPLETION
% =========================================================================

fprintf('\n========================================\n');
fprintf('Processing Complete for %s!\n', subject_id);
fprintf('========================================\n');
fprintf('Motion-corrected data: %s\n', mc_nii_fn);
fprintf('Brain mask: %s\n', mask_fn);
fprintf('XPS file: %s\n', mc_xps_fn);
fprintf('Results saved to: %s\n', o_path);

end