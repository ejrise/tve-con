#!/bin/bash

# =============================================================
# DWI Registration and ROI Transform Pipeline
# =============================================================

# -----------------------------------------------
# USER INPUTS - EDIT THESE
# -----------------------------------------------

SUBJECTS_DIR="/path/to/results/01_denoised"
T1_DIR="/path/to/t1s"
MNI_TEMPLATE="/path/to/MNI152_T1_2mm_brain.nii.gz"
ROI_DIR="/path/to/rois"   # HCP1065 tract masks, MNI space, thresholded at >= 50%
OUTPUT_DIR="/path/to/results/04_registration"

# -----------------------------------------------
# >>> ADD YOUR CONTROLS TEMPLATE PATH HERE <<<
# This should be a skull-stripped, ideally 2mm isotropic brain template
# built from your control subjects (e.g. from ANTs buildtemplateparallel.sh)
# Example: CONTROLS_TEMPLATE="/path/to/your/controls_template_brain.nii.gz"
# -----------------------------------------------
CONTROLS_TEMPLATE="/path/to/t1s/control_t1s/control_temp_2mm.nii.gz"   # <-- SET THIS PATH

# DTI maps from 03_dti/sub-XX/ (named sub-XX_MAPNAME.nii.gz)
DTI_MAPS=(
    "FA"
    "MD"
)

# dwi_dtd params from 01_denoised/sub-XX/ (named dwi_dtd_PARAMNAME.nii.gz)
DTD_PARAMS=(
    "miso"
    "msqanison"
    "op"
    "ufa"
    "vison"
)

# BET fractional intensity threshold
BET_F=0.3

# Number of threads for ANTs
THREADS=4

# -----------------------------------------------
# SETUP
# -----------------------------------------------

mkdir -p "$OUTPUT_DIR"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$THREADS

# Validate controls template is set
if [ -z "$CONTROLS_TEMPLATE" ]; then
    echo "ERROR: CONTROLS_TEMPLATE is not set. Please set the path at the top of this script."
    exit 1
fi
if [ ! -f "$CONTROLS_TEMPLATE" ]; then
    echo "ERROR: CONTROLS_TEMPLATE not found at: $CONTROLS_TEMPLATE"
    exit 1
fi

# -----------------------------------------------
# TRANSFORM FUNCTION
# Applies brain mask and warps input to T1, MNI,
# and controls template space.
# -----------------------------------------------
transform_image() {
    local INPUT=$1
    local OUTPUT_T1=$2
    local OUTPUT_MNI=$3
    local OUTPUT_CON=$4
    local LABEL=$5

    # Apply brain mask
    MASKED="$(dirname $OUTPUT_T1)/$(basename $INPUT .nii.gz)_masked.nii.gz"
    fslmaths "$INPUT" -mas "$MEAN_B0_MASK" "$MASKED" -odt float

    # → 2mm T1 space (skip if already done)
    if [ -f "$OUTPUT_T1" ]; then
        echo "  Already exists, skipping: $LABEL → T1 space"
    else
        antsApplyTransforms -d 3 \
            -i "$MASKED" \
            -r "$T1_2MM" \
            -o "$OUTPUT_T1" \
            -t "$B0_TO_T1_WARP" \
            -n Linear
        echo "  ✓ $LABEL → T1 space (2mm)"
    fi

    # → MNI space (skip if already done)
    if [ -f "$OUTPUT_MNI" ]; then
        echo "  Already exists, skipping: $LABEL → MNI space"
    else
        antsApplyTransforms -d 3 \
            -i "$MASKED" \
            -r "$MNI_TEMPLATE" \
            -o "$OUTPUT_MNI" \
            -t "$T1_TO_MNI_WARP" \
            -t "$T1_TO_MNI_AFFINE" \
            -t "$B0_TO_T1_WARP" \
            -n Linear
        echo "  ✓ $LABEL → MNI space"
    fi

    # → Controls template space (skip if already done)
    if [ -f "$OUTPUT_CON" ]; then
        echo "  Already exists, skipping: $LABEL → controls template space"
    else
        antsApplyTransforms -d 3 \
            -i "$MASKED" \
            -r "$CONTROLS_TEMPLATE" \
            -o "$OUTPUT_CON" \
            -t "$T1_TO_CON_WARP" \
            -t "$T1_TO_CON_AFFINE" \
            -t "$B0_TO_T1_WARP" \
            -n Linear
        echo "  ✓ $LABEL → controls template space"
    fi

    rm -f "$MASKED"
}

# -----------------------------------------------
# PRE-LOOP: REGISTER MNI → CONTROLS TEMPLATE (once)
# and transform all ROIs into controls template space
# -----------------------------------------------

echo "========================================"
echo "One-time: MNI → controls template ROI transform"
echo "========================================"

MNI_TO_CON_PREFIX="$OUTPUT_DIR/MNI_to_CON_"
MNI_TO_CON_WARP="${MNI_TO_CON_PREFIX}1Warp.nii.gz"
MNI_TO_CON_AFFINE="${MNI_TO_CON_PREFIX}0GenericAffine.mat"
ROI_CON_DIR="$OUTPUT_DIR/ROIs_CONspace"
mkdir -p "$ROI_CON_DIR"

if [ -f "$MNI_TO_CON_WARP" ]; then
    echo "  MNI→CON registration already exists, skipping"
else
    echo "  Registering MNI → controls template..."
    antsRegistrationSyN.sh -d 3 \
        -f "$CONTROLS_TEMPLATE" \
        -m "$MNI_TEMPLATE" \
        -o "$MNI_TO_CON_PREFIX" \
        -t s \
        -n "$THREADS"

    if [ $? -ne 0 ]; then
        echo "ERROR: MNI→controls template registration failed. Exiting."
        exit 1
    fi
    echo "  ✓ MNI→controls template registration complete"
fi

echo ""
echo "  Transforming ROI masks MNI → controls template space..."
for ROI_FILE in "$ROI_DIR"/*.nii.gz; do
    ROI_NAME=$(basename "$ROI_FILE" .nii.gz)
    ROI_CON="$ROI_CON_DIR/${ROI_NAME}_CONspace.nii.gz"

    if [ -f "$ROI_CON" ]; then
        echo "  Already exists: $ROI_NAME — skipping"
        continue
    fi

    antsApplyTransforms -d 3 \
        -i "$ROI_FILE" \
        -r "$CONTROLS_TEMPLATE" \
        -o "$ROI_CON" \
        -t "$MNI_TO_CON_WARP" \
        -t "$MNI_TO_CON_AFFINE" \
        -n NearestNeighbor

    echo "  ✓ $ROI_NAME → controls template space"
done

echo ""
echo "✓ ROIs in controls template space saved to: $ROI_CON_DIR"
echo ""

# -----------------------------------------------
# MAIN LOOP
# -----------------------------------------------

for SUB_DWI_DIR in "$SUBJECTS_DIR"/sub-*/dwi/; do
    SUB_ID=$(basename $(dirname "$SUB_DWI_DIR"))

    echo "========================================"
    echo "Processing $SUB_ID"
    echo "========================================"

    TEMP_DIR="$SUB_DWI_DIR/temp"
    DTI_DIR="/path/to/results/03_dti/$SUB_ID"
    DTD_DIR="$SUBJECTS_DIR/$SUB_ID"
    SUB_OUT="$OUTPUT_DIR/$SUB_ID"
    mkdir -p "$SUB_OUT"

    # --- File path definitions ---
    MEAN_B0="$TEMP_DIR/${SUB_ID}_mean_b0.nii.gz"
    MEAN_B0_BRAIN="$TEMP_DIR/${SUB_ID}_mean_b0_brain.nii.gz"
    MEAN_B0_MASK="$TEMP_DIR/${SUB_ID}_mean_b0_brain_mask.nii.gz"
    T1_BRAIN="$T1_DIR/${SUB_ID}_t1_BrainExtractionBrain.nii.gz"
    T1_2MM="$SUB_OUT/${SUB_ID}_T1_2mm.nii.gz"

    B0_TO_T1_PREFIX="$SUB_OUT/${SUB_ID}_b0_to_T1_"
    B0_TO_T1_WARP="${B0_TO_T1_PREFIX}0GenericAffine.mat"

    T1_TO_MNI_PREFIX="$SUB_OUT/${SUB_ID}_T1_to_MNI_"
    T1_TO_MNI_WARP="${T1_TO_MNI_PREFIX}1Warp.nii.gz"
    T1_TO_MNI_AFFINE="${T1_TO_MNI_PREFIX}0GenericAffine.mat"
    T1_TO_MNI_INVWARP="${T1_TO_MNI_PREFIX}1InverseWarp.nii.gz"

    T1_TO_CON_PREFIX="$SUB_OUT/${SUB_ID}_T1_to_CON_"
    T1_TO_CON_WARP="${T1_TO_CON_PREFIX}1Warp.nii.gz"
    T1_TO_CON_AFFINE="${T1_TO_CON_PREFIX}0GenericAffine.mat"
    T1_TO_CON_INVWARP="${T1_TO_CON_PREFIX}1InverseWarp.nii.gz"

    # --- Check required input files ---
    for f in "$MEAN_B0" "$T1_BRAIN"; do
        if [ ! -f "$f" ]; then
            echo "  Missing: $f — skipping $SUB_ID"
            continue 2
        fi
    done

    # -----------------------------------------------
    # STEP 1: SKULL STRIP MEAN B0
    # -----------------------------------------------
    echo ""
    echo "STEP 1: Skull stripping mean b0..."

    if [ -f "$MEAN_B0_BRAIN" ]; then
        echo "  Already exists, skipping BET"
    else
        bet "$MEAN_B0" "$MEAN_B0_BRAIN" -m -f "$BET_F"
        echo "  ✓ BET complete"
    fi

    # -----------------------------------------------
    # STEP 2: RESAMPLE T1 TO 2MM
    # -----------------------------------------------
    echo ""
    echo "STEP 2: Resampling T1 to 2mm isotropic..."

    if [ -f "$T1_2MM" ]; then
        echo "  Already exists, skipping resampling"
    else
        flirt -in "$T1_BRAIN" -ref "$T1_BRAIN" -out "$T1_2MM" -applyisoxfm 2
        echo "  ✓ T1 resampled to 2mm"
    fi

    # -----------------------------------------------
    # STEP 3: REGISTER B0 → 2MM T1
    # -----------------------------------------------
    echo ""
    echo "STEP 3: Registering b0 → 2mm T1..."

    if [ -f "$B0_TO_T1_WARP" ]; then
        echo "  Already exists, skipping b0→T1 registration"
    else
        antsRegistrationSyNQuick.sh -d 3 \
            -f "$T1_2MM" \
            -m "$MEAN_B0_BRAIN" \
            -o "$B0_TO_T1_PREFIX" \
            -t r \
            -n "$THREADS"

        if [ $? -ne 0 ]; then
            echo "  Error: b0→T1 registration failed for $SUB_ID — skipping"
            continue
        fi
        echo "  ✓ b0→2mm T1 registration complete"
    fi

    # -----------------------------------------------
    # STEP 4: REGISTER 2MM T1 → MNI
    # -----------------------------------------------
    echo ""
    echo "STEP 4: Registering 2mm T1 → MNI..."

    if [ -f "$T1_TO_MNI_WARP" ]; then
        echo "  Already exists, skipping T1→MNI registration"
    else
        antsRegistrationSyN.sh -d 3 \
            -f "$MNI_TEMPLATE" \
            -m "$T1_2MM" \
            -o "$T1_TO_MNI_PREFIX" \
            -t s \
            -n "$THREADS"

        if [ $? -ne 0 ]; then
            echo "  Error: T1→MNI registration failed for $SUB_ID — skipping"
            continue
        fi
        echo "  ✓ 2mm T1→MNI registration complete"
    fi

    # -----------------------------------------------
    # STEP 5: REGISTER 2MM T1 → CONTROLS TEMPLATE
    # -----------------------------------------------
    echo ""
    echo "STEP 5: Registering 2mm T1 → controls template..."

    if [ -f "$T1_TO_CON_WARP" ]; then
        echo "  Already exists, skipping T1→controls template registration"
    else
        antsRegistrationSyN.sh -d 3 \
            -f "$CONTROLS_TEMPLATE" \
            -m "$T1_2MM" \
            -o "$T1_TO_CON_PREFIX" \
            -t s \
            -n "$THREADS"

        if [ $? -ne 0 ]; then
            echo "  Error: T1→controls template registration failed for $SUB_ID — skipping"
            continue
        fi
        echo "  ✓ 2mm T1→controls template registration complete"
    fi

    # -----------------------------------------------
    # STEP 6: TRANSFORM DTI MAPS (03_dti)
    # -----------------------------------------------
    echo ""
    echo "STEP 6: Transforming DTI maps from 03_dti..."

    DTI_T1_DIR="$SUB_OUT/dti_T1space"
    DTI_MNI_DIR="$SUB_OUT/dti_MNIspace"
    DTI_CON_DIR="$SUB_OUT/dti_CONspace"
    mkdir -p "$DTI_T1_DIR" "$DTI_MNI_DIR" "$DTI_CON_DIR"

    for MAP in "${DTI_MAPS[@]}"; do
        DTI_FILE="$DTI_DIR/${SUB_ID}_${MAP}.nii.gz"

        if [ ! -f "$DTI_FILE" ]; then
            echo "  Missing: $DTI_FILE — skipping"
            continue
        fi

        transform_image \
            "$DTI_FILE" \
            "$DTI_T1_DIR/${SUB_ID}_${MAP}_T1space.nii.gz" \
            "$DTI_MNI_DIR/${SUB_ID}_${MAP}_MNIspace.nii.gz" \
            "$DTI_CON_DIR/${SUB_ID}_${MAP}_CONspace.nii.gz" \
            "$MAP (03_dti)"
    done

    # -----------------------------------------------
    # STEP 7: TRANSFORM DTD MAPS (01_denoised/sub-XX/)
    # -----------------------------------------------
    echo ""
    echo "STEP 7: Transforming dwi_dtd maps from 01_denoised..."

    DTD_T1_DIR="$SUB_OUT/dtd_T1space"
    DTD_MNI_DIR="$SUB_OUT/dtd_MNIspace"
    DTD_CON_DIR="$SUB_OUT/dtd_CONspace"
    mkdir -p "$DTD_T1_DIR" "$DTD_MNI_DIR" "$DTD_CON_DIR"

    for PARAM in "${DTD_PARAMS[@]}"; do
        DTD_FILE="$DTD_DIR/dwi_dtd_${PARAM}.nii.gz"

        if [ ! -f "$DTD_FILE" ]; then
            echo "  Missing: $DTD_FILE — skipping"
            continue
        fi

        # Convert to FLOAT32
        DTD_F32="$DTD_DIR/dwi_dtd_${PARAM}_f32.nii.gz"
        fslmaths "$DTD_FILE" "$DTD_F32" -odt float

        # Resample to match mask if dimensions differ
        DTD_DIMS=$(fslval "$DTD_F32" dim1)
        MASK_DIMS=$(fslval "$MEAN_B0_MASK" dim1)
        if [ "$DTD_DIMS" != "$MASK_DIMS" ]; then
            echo "  Resampling $PARAM to match mask dimensions..."
            DTD_RESAMPLED="$DTD_DIR/dwi_dtd_${PARAM}_resampled.nii.gz"
            flirt -in "$DTD_F32" -ref "$MEAN_B0_MASK" -out "$DTD_RESAMPLED" -applyxfm -usesqform
            rm "$DTD_F32"
            DTD_F32="$DTD_RESAMPLED"
        fi

        transform_image \
            "$DTD_F32" \
            "$DTD_T1_DIR/${SUB_ID}_dtd_${PARAM}_T1space.nii.gz" \
            "$DTD_MNI_DIR/${SUB_ID}_dtd_${PARAM}_MNIspace.nii.gz" \
            "$DTD_CON_DIR/${SUB_ID}_dtd_${PARAM}_CONspace.nii.gz" \
            "dtd_${PARAM} (01_denoised)"

        rm -f "$DTD_F32"
    done

    # -----------------------------------------------
    # STEP 8: TRANSFORM ROI MASKS → 2MM T1 SPACE
    # -----------------------------------------------
    echo ""
    echo "STEP 8: Transforming ROI masks MNI → 2mm T1 space..."

    ROI_T1_DIR="$SUB_OUT/ROIs_T1space"
    mkdir -p "$ROI_T1_DIR"

    for ROI_FILE in "$ROI_DIR"/*.nii.gz; do
        ROI_NAME=$(basename "$ROI_FILE" .nii.gz)
        ROI_T1="$ROI_T1_DIR/${SUB_ID}_${ROI_NAME}_T1space_2mm.nii.gz"

        if [ -f "$ROI_T1" ]; then
            echo "  Already exists: $ROI_NAME (T1) — skipping"
            continue
        fi

        antsApplyTransforms -d 3 \
            -i "$ROI_FILE" \
            -r "$T1_2MM" \
            -o "$ROI_T1" \
            -t "$T1_TO_MNI_INVWARP" \
            -t ["$T1_TO_MNI_AFFINE", 1] \
            -n NearestNeighbor

        echo "  ✓ $ROI_NAME → 2mm T1 space"
    done

    # -----------------------------------------------
    # STEP 9: WM MASK IN CONTROLS TEMPLATE SPACE (FSL FAST)
    # Segments the T1 warped to the controls template in Step 5
    # (antsRegistrationSyN.sh output: *_T1_to_CON_Warped.nii.gz),
    # then thresholds the WM partial volume map at 0.9 and binarizes.
    # -----------------------------------------------
    echo ""
    echo "STEP 9: Segmenting WM in controls template space (FAST)..."

    T1_CON_WARPED="${T1_TO_CON_PREFIX}Warped.nii.gz"
    FAST_PREFIX="$SUB_OUT/${SUB_ID}_T1_to_CON_fast"
    WM_MASK_PVE="$SUB_OUT/${SUB_ID}_WM_mask.nii.gz"
    WM_MASK_BIN="$SUB_OUT/${SUB_ID}_WM_mask_bin.nii.gz"

    if [ -f "$WM_MASK_BIN" ]; then
        echo "  Already exists, skipping FAST WM segmentation"
    elif [ ! -f "$T1_CON_WARPED" ]; then
        echo "  Missing: $T1_CON_WARPED — skipping WM segmentation"
    else
        # 3-class segmentation of T1 (CSF, GM, WM)
        fast -t 1 -n 3 -o "$FAST_PREFIX" "$T1_CON_WARPED"

        # pve_2 = WM partial volume estimate (0-1)
        mv "${FAST_PREFIX}_pve_2.nii.gz" "$WM_MASK_PVE"

        # Keep voxels with WM probability >= 0.9, binarize
        fslmaths "$WM_MASK_PVE" -thr 0.9 -bin "$WM_MASK_BIN"
        echo "  ✓ WM mask (template space) saved: $(basename $WM_MASK_BIN)"
    fi

    echo ""
    echo "✓ Completed $SUB_ID"
    echo ""
done

echo "========================================"
echo "PIPELINE COMPLETE"
echo "========================================"