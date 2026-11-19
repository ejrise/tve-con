#!/bin/bash

# =============================================================
# T1 Skull Stripping and Control Population Template Pipeline
# =============================================================
# 1. Skull-strips every participant's T1w image from a BIDS dataset
#    (ANTs antsBrainExtraction.sh)
# 2. Builds a population template from the control participants
#    (ANTs antsMultivariateTemplateConstruction.sh)
# 3. Resamples the template to 2mm isotropic (FSL flirt)
#
# Outputs are named to match what registration_pipe.sh expects:
#   $T1_OUT_DIR/sub-XX_t1_BrainExtractionBrain.nii.gz
#   $TEMPLATE_DIR/control_templatetemplate0.nii.gz   (full resolution)
#   $TEMPLATE_DIR/control_temp_2mm.nii.gz            (2mm, used by registration_pipe.sh)
#
# Requires: ANTs, FSL
# -------------------------------------------------------------

# -----------------------------------------------
# USER INPUTS - EDIT THESE
# -----------------------------------------------

BIDS_DIR="/path/to/bids"

# Output folder for skull-stripped T1s (= T1_DIR in registration_pipe.sh)
T1_OUT_DIR="/path/to/t1s"

# Output folder for the control template
TEMPLATE_DIR="$T1_OUT_DIR/control_t1s"

# Brain extraction templates (OASIS templates from the ANTs/ANTsR Brain Templates
# collection, https://doi.org/10.6084/m9.figshare.915436; CC BY-NC)
ANTS_TEMPLATE_DIR="/path/to/Ants_templates"
BE_TEMPLATE="$ANTS_TEMPLATE_DIR/T_template0.nii.gz"
BE_PROB_MASK="$ANTS_TEMPLATE_DIR/T_template0_BrainCerebellumProbabilityMask.nii.gz"
BE_REG_MASK="$ANTS_TEMPLATE_DIR/T_template0_BrainCerebellumRegistrationMask.nii.gz"

# participants.tsv column and value that identify controls
GROUP_COLUMN="group_id"
CONTROL_LABEL="0"

# Template construction settings
TEMPLATE_ITERATIONS=4       # -i
THREADS=4                   # -j
TEMPLATE_RES=2              # mm, resolution of the template used downstream

# -----------------------------------------------
# SETUP
# -----------------------------------------------

mkdir -p "$T1_OUT_DIR" "$TEMPLATE_DIR"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$THREADS

for f in "$BE_TEMPLATE" "$BE_PROB_MASK" "$BE_REG_MASK" "$BIDS_DIR/participants.tsv"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file not found: $f"
        exit 1
    fi
done

# -----------------------------------------------
# STEP 1: SKULL STRIP ALL T1s
# -----------------------------------------------

echo "========================================"
echo "STEP 1: Skull stripping T1s (antsBrainExtraction.sh)"
echo "========================================"

for SUB_DIR in "$BIDS_DIR"/sub-*/; do
    SUB_ID=$(basename "$SUB_DIR")

    T1_RAW=$(find "$SUB_DIR" -path "*/anat/*" -name "${SUB_ID}*_T1w.nii.gz" | sort | head -1)
    N_T1=$(find "$SUB_DIR" -path "*/anat/*" -name "${SUB_ID}*_T1w.nii.gz" | wc -l)

    if [ -z "$T1_RAW" ]; then
        echo "  Missing T1w for $SUB_ID — skipping"
        continue
    fi
    if [ "$N_T1" -gt 1 ]; then
        echo "  Warning: $N_T1 T1w images for $SUB_ID, using $(basename $T1_RAW)"
    fi

    OUT_PREFIX="$T1_OUT_DIR/${SUB_ID}_t1_"
    T1_BRAIN="${OUT_PREFIX}BrainExtractionBrain.nii.gz"

    if [ -f "$T1_BRAIN" ]; then
        echo "  Already exists, skipping: $SUB_ID"
        continue
    fi

    echo "  Processing $SUB_ID..."
    antsBrainExtraction.sh -d 3 \
        -a "$T1_RAW" \
        -e "$BE_TEMPLATE" \
        -m "$BE_PROB_MASK" \
        -f "$BE_REG_MASK" \
        -o "$OUT_PREFIX"

    if [ ! -f "$T1_BRAIN" ]; then
        echo "  Error: brain extraction failed for $SUB_ID"
        continue
    fi
    echo "  ✓ $(basename $T1_BRAIN)"
done

# -----------------------------------------------
# STEP 2: BUILD CONTROL POPULATION TEMPLATE
# -----------------------------------------------

echo ""
echo "========================================"
echo "STEP 2: Building control template (antsMultivariateTemplateConstruction.sh)"
echo "========================================"

TEMPLATE_PREFIX="control_template"
TEMPLATE_FULL="$TEMPLATE_DIR/${TEMPLATE_PREFIX}template0.nii.gz"
TEMPLATE_2MM="$TEMPLATE_DIR/control_temp_2mm.nii.gz"

if [ -f "$TEMPLATE_FULL" ]; then
    echo "  Template already exists, skipping construction"
else
    # Find control participants from participants.tsv
    GROUP_COL_IDX=$(head -1 "$BIDS_DIR/participants.tsv" | tr '\t' '\n' | grep -n -x "$GROUP_COLUMN" | cut -d: -f1)
    if [ -z "$GROUP_COL_IDX" ]; then
        echo "ERROR: Column '$GROUP_COLUMN' not found in participants.tsv"
        exit 1
    fi

    CONTROLS=$(awk -F'\t' -v col="$GROUP_COL_IDX" -v lab="$CONTROL_LABEL" \
        'NR > 1 && $col == lab {print $1}' "$BIDS_DIR/participants.tsv")

    CONTROL_T1S=()
    for SUB_ID in $CONTROLS; do
        T1_BRAIN="$T1_OUT_DIR/${SUB_ID}_t1_BrainExtractionBrain.nii.gz"
        if [ -f "$T1_BRAIN" ]; then
            CONTROL_T1S+=("$T1_BRAIN")
        else
            echo "  Warning: no skull-stripped T1 for control $SUB_ID — excluded from template"
        fi
    done

    echo "  Building template from ${#CONTROL_T1S[@]} control participants"
    if [ ${#CONTROL_T1S[@]} -lt 2 ]; then
        echo "ERROR: Need at least 2 control T1s to build a template"
        exit 1
    fi

    # Record which participants went into the template
    printf "%s\n" "${CONTROL_T1S[@]}" > "$TEMPLATE_DIR/template_inputs.txt"

    cd "$TEMPLATE_DIR" || exit 1
    antsMultivariateTemplateConstruction.sh -d 3 \
        -o "$TEMPLATE_PREFIX" \
        -i "$TEMPLATE_ITERATIONS" \
        -c 2 \
        -j "$THREADS" \
        -r 1 \
        -n 1 \
        -s CC \
        -t GR \
        -m 100x70x50x10 \
        "${CONTROL_T1S[@]}"

    if [ ! -f "$TEMPLATE_FULL" ]; then
        echo "ERROR: Template construction failed"
        exit 1
    fi
    echo "  ✓ Template saved: $TEMPLATE_FULL"
fi

# -----------------------------------------------
# STEP 3: RESAMPLE TEMPLATE TO 2MM
# -----------------------------------------------

echo ""
echo "STEP 3: Resampling template to ${TEMPLATE_RES}mm isotropic..."

if [ -f "$TEMPLATE_2MM" ]; then
    echo "  Already exists, skipping resampling"
else
    flirt -in "$TEMPLATE_FULL" -ref "$TEMPLATE_FULL" -out "$TEMPLATE_2MM" -applyisoxfm "$TEMPLATE_RES"
    echo "  ✓ $(basename $TEMPLATE_2MM)"
fi

echo ""
echo "========================================"
echo "DONE"
echo "  Skull-stripped T1s: $T1_OUT_DIR"
echo "  Control template:   $TEMPLATE_2MM"
echo "  Set T1_DIR and CONTROLS_TEMPLATE in registration_pipe.sh to these paths."
echo "========================================"
