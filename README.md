# [tve-con]

## Overview

Code for Rizor et al., Characterizing white matter microstructure in acute concussion with tensor-valued diffusion encoding (2026). Diffusion MRI with tensor-valued encoding was performed (linear and spherical b-tensor encoding) in 30 participants with acute concussion (within 5 days of injury) and 32 healthy controls. 

---

## Repository Structure
```
tve-con/
├── resources/
│   ├── ants_templates/   (brain extraction priors — download, see below)
│   ├── cont_template/   
│   └── rois/     (HCP1065 tract masks, MNI152 2mm, thresholded ≥ 50%)
└── scripts/
    ├── analysis/
    ├── plotting/
    ├── preprocess/
    │   ├── anat/
    │   ├── dwi/
    │   │   └── get_tve/
    │   └── registration/
```

---

## Processing Order

Run the scripts in this order. 

1. `flip_bvec.sh` — reorient the raw bvecs (required, see note below)
2. `t1_brainextract_template.sh` — skull-strip T1s and build the control template
3. `denoise_pipe.sh` — concatenate, denoise, SNR
4. `run_dtd_parallel.m` (calls `runmydtd.m`) — motion correction, DTD fits
5. `get_linear_fa.sh` — DTI fit (FA, MD)
6. `registration_pipe.sh` — normalization to template space, WM masks
7. Organize `final_regions/` by hand (see `scripts/analysis/`)
8. `dtd_stats.ipynb` — ROI extraction and statistics
9. `plot_maps.ipynb`, `plot_glass_brains.ipynb` — figures

All outputs go into one results folder:
```
/path/to/results/
├── 01_denoised/        denoise_pipe.sh, runmydtd.m
├── 02_snr_analysis/    denoise_pipe.sh
├── 03_dti/             get_linear_fa.sh
├── 04_registration/    registration_pipe.sh
├── 05_models/          dtd_stats.ipynb (model summary CSVs)
└── 06_figures/         analysis notebooks
```

---

## Details

### Important: bvec orientation

The `.bvec` files in the [raw dataset]([https://openneuro.org/datasets/ds006445]) are the original, unmodified files from the scanner. When used as-is, we found that their tensor fits give principal diffusion directions that don’t agree with the expected anatomy. Swap the first two rows of every `.bvec` file and negate both, leaving the third row unchanged:

- New row 1 (x) = −(original row 2)
- New row 2 (y) = −(original row 1)
- New row 3 (z) = original row 3

`flip_bvec.sh` applies this correction to every `.bvec` in the BIDS folder and keeps a `.backup` of each original. It skips files that already have a backup, so running it twice does not undo the correction.

```
scripts/preprocessing/anat/
    t1_brainextract_template.sh
```
Requires ANTs and FSL.
- Skull-strips each participant's BIDS T1w image (`antsBrainExtraction.sh`) using the OASIS template, brain probability mask and registration mask from `resources/Ants_templates/`. Output: `sub-XX_t1_BrainExtractionBrain.nii.gz`.
- Builds a population template from all control participants listed in `participants.tsv` (`antsMultivariateTemplateConstruction.sh`). Set `GROUP_COLUMN` and `CONTROL_LABEL` to match `participants.tsv` (in this dataset: `group_id` / `0`). Writes `template_inputs.txt` listing the participants used.
- Resamples the template to 2mm isotropic (`flirt`). Output: `control_t1s/control_temp_2mm.nii.gz`.

```
scripts/preprocessing/dwi/
    denoise_pipe.sh
    run_dtd_parallel.m
    runmydtd.m
    get_linear_fa.sh
```
Requires MRtrix3, FSL, MATLAB (Parallel Computing Toolbox), elastix and the md-dmri toolbox.

- `denoise_pipe.sh`: Usage: `./denoise_pipe.sh /path/to/bids /path/to/t1s /path/to/results [--remove-temp]`. Converts each linear (LTE) and spherical (STE) series to `.mif` with its own gradients and concatenates them (`mrconvert -fslgrad`, `mrcat`), writing a volume map recording which volumes are linear and which are spherical. Then runs MP-PCA denoising on the concatenated data (`dwidenoise`) and saves the original, denoised data and noise map. Computes SNR from the original data within a native-space WM mask (FSL FAST on the T1, WM partial volume ≥ 0.9, registered to the mean b0 with FLIRT), for each b-value shell and acquisition type. Writes `all_subjects_snr_summary.csv` and per-shell histograms. Temporary files are kept by default because `registration_pipe.sh` needs `temp/sub-XX_mean_b0.nii.gz`.
- `run_dtd_parallel.m` + `runmydtd.m`: Runs `runmydtd` for every subject in parallel. For each subject: builds the acquisition description (`xps`) from the 8 BIDS bval/bvec files (`acq-linear_run-1…4`, `acq-spherical_run-5…8`). Runs affine motion and eddy-current correction with elastix (`mdm_mec_b0` on a b ≤ 1000 s/mm² reference, then `mdm_mec_eb` on all volumes). Makes a brain mask (mean motion-corrected image thresholded at 100) and fits the `dtd` and `dtd_covariance` models (`mdm_fit`). Outputs `sub-XX_concat_dwi_denoised_mc.nii.gz` and `dwi_dtd_*.nii.gz` parameter maps in `01_denoised/`.
- `get_linear_fa.sh`: Fits a diffusion tensor to the linear-encoding volumes of the motion-corrected data (`dwi2tensor`) and extracts FA and MD (`tensor2metric`). Output: `03_dti/sub-XX/sub-XX_FA.nii.gz`, `sub-XX_MD.nii.gz`.

```
scripts/preprocessing/registration/
    registration_pipe.sh
```
Requires ANTs and FSL. We recommend visually checking all outputs. For each participant:
1. Skull-strips the mean b0 (BET). 
2. Resamples the T1 to 2mm.
3. Registers b0 → T1 (rigid, `antsRegistrationSyNQuick.sh`).
4. Registers T1 → MNI152 and T1 → control template (affine + SyN, `antsRegistrationSyN.sh`).
5. Warps the DTI and DTD maps from diffusion space to T1, MNI and template space in a single interpolation (`antsApplyTransforms`, linear).
6. Segments the template-space T1 with FSL FAST and thresholds the WM partial volume at 0.9 to make an individualized WM mask (`sub-XX_WM_mask_bin.nii.gz`).

Before the subject loop, it registers MNI152 → control template once and warps the HCP1065 tract masks in `resources/rois/` into template space (`04_registration/ROIs_CONspace/`, nearest-neighbour).

```
scripts/analysis/
```
Before running the analysis notebooks, organize the template-space tract masks yourself. `registration_pipe.sh` does not create this folder. Copy the masks from `04_registration/ROIs_CONspace/` into:
```
04_registration/ROIs_CONspace/final_regions/
    Association/    (+ All_assoc.nii.gz, combined mask)
    Commissural/    (+ All_comm.nii.gz)
    Projection/     (+ All_proj.nii.gz)
```
You may use the tract groupings in Fig. 1 of Rizor et al. (or your own).

- `stats/dtd_stats.ipynb`: Extracts the median value of each parameter (DTD: `ufa`, `msqanison`, `op`, `miso`, `vison`; DTI: `FA`, `MD`) within each tract ROI, restricted to each participant's WM mask. Log-transforms V(Diso) (right-skewed) and z-scores within parameter × ROI. Then fits:
  - hierarchical Bayesian logistic regressions of group on each parameter (ROI effects pooled within tract type, with age and sex covariates)
  - a hierarchical regression of OP on µFA and FA
  - isotropic model comparisons (`vison` + `MD`, `vison` + `miso`)
  - cross-validated logistic regression AUCs (stratified 4-fold × 10 repeats) with paired t-tests between parameters

  Outputs summary CSVs to `05_models/` (including `auc_roi.csv`) and figures to `06_figures/`
  - Optional: `drop_ids` excludes controls with a previous concussion history (potential supplementary analysis) 
- `figures/plot_maps.ipynb`: Raw vs. denoised DWI and parameter maps for one representative control and one concussion participant. Outputs to `06_figures/representative/`.
- `figures/plot_glass_brains.ipynb`: Tract ROIs on the control template (2D slices and 3D renders) and 3D renders of regions coloured by AUC, with AUC values entered by hand from `05_models/auc_roi.csv`. Tracts are restricted to a template-space WM mask (`control_temp_WM_mask_2mm.nii.gz`). 

---

## Resources

- `resources/rois/`: HCP1065 Population-Averaged Tractography Atlas (Yeh, 2022) tract masks in MNI152 2mm space, thresholded at ≥ 50%.
- `resources/cont_template/`: Control population template built from the 32 control participants with `t1_brainextract_template.sh` (`antsMultivariateTemplateConstruction.sh`). `control_templatetemplate0.nii.gz` is the full-resolution template; `control_temp_2mm.nii.gz` is the 2mm version used for registration in `registration_pipe.sh`; `control_temp_WM_mask_2mm.nii.gz` is the template-space WM mask used in `plot_glass_brains.ipynb`. Provided so results can be reproduced without rebuilding the template; point `CONTROLS_TEMPLATE` (`registration_pipe.sh`) and `TEMPLATE_DIR` (`plot_glass_brains.ipynb`) to this folder.
- `resources/Ants_templates/`: `T_template0.nii.gz`, `T_template0_BrainCerebellumProbabilityMask.nii.gz` and `T_template0_BrainCerebellumRegistrationMask.nii.gz` from the [ANTs/ANTsR Brain Templates](https://doi.org/10.6084/m9.figshare.915436) (OASIS, CC BY-NC). These are not covered by this repository's license.
- MNI152 2mm brain template: `$FSLDIR/data/standard/MNI152_T1_2mm_brain.nii.gz` (included with FSL).
---

## Requirements

- Neuroimaging tools: FSL v.6.0.7.21, ANTs v.2.6.5, MRtrix3 v.3.0.8, elastix 5.3.0
- MATLAB R2025B with Parallel Computing Toolbox; [md-dmri](https://github.com/markus-nilsson/md-dmri) 
- Python 3.13.9: numpy, pandas, scipy, nibabel, nilearn, matplotlib, pymc, arviz, scikit-learn, pyvista, scikit-image. The notebooks use the ArviZ 0.x API (`hdi_prob`), so install `arviz<1.0`.

---

## Raw Data Repository

- [Raw data](https://openneuro.org/datasets/ds006445) (BIDS). Note that the bvecs are the raw scanner files; see the bvec orientation note above.

---

## Citation

If you use this code, please cite:

Rizor, E.J., Dundon, N.M., Hayes, M., Sabugo, K., & Grafton, S. (2026). Characterizing white matter microstructure in acute concussion with tensor-valued diffusion encoding. *Imaging Neuroscience*. https://doi.org/10.1162/IMAG.a.1483
```bibtex
@article{rizor2026characterizing,
  author  = {Rizor, Elizabeth J. and Dundon, Neil M. and Hayes, Margaret and Sabugo, Kiana and Grafton, Scott T.},
  title   = {Characterizing white matter microstructure in acute concussion with tensor-valued diffusion encoding},
  journal = {Imaging Neuroscience},
  year    = {2026},
  doi     = {10.1162/IMAG.a.1483}
}
```

---

## Acknowledgements

The authors thank Jan Martin and Frederik Bernd Lund at the Institute of Radiology, University Hospital Erlangen, Friedrich-Alexander-Universität Erlangen-Nürnberg (FAU), Erlangen, Germany for providing code for the tensor-valued encoding waveforms. We would also like to thank Mario Mendoza at UC Santa Barbara’s Brain Imaging Center for MRI data collection and participant recruitment assistance.

---

## License

This repository is licensed under the [MIT License](LICENSE). Third-party files in `resources/` keep their original licenses.
