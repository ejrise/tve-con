#!/bin/bash

DENOISED_DIR="/path/to/results/01_denoised"
OUTPUT_DIR="/path/to/results/03_dti"
mkdir -p "$OUTPUT_DIR"

for SUB_DENOISED_DIR in "$DENOISED_DIR"/sub-*/dwi/; do
    SUB_ID=$(basename $(dirname "$SUB_DENOISED_DIR"))
    echo "Processing $SUB_ID..."

    DWI="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi_denoised_mc.nii.gz"
    BVAL="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi.bval"
    BVEC="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi.bvec"
    VOLUME_MAP="$SUB_DENOISED_DIR/${SUB_ID}_volume_mapping.txt"

    # Check required files exist
    for f in "$DWI" "$BVAL" "$BVEC" "$VOLUME_MAP"; do
        if [ ! -f "$f" ]; then
            echo "  Missing: $f — skipping $SUB_ID"
            continue 2
        fi
    done

    # Get linear volume indices from volume map
    LINEAR_VOLS=""
    while IFS= read -r line; do
        [[ $line =~ ^# ]] && continue
        [[ -z $line ]] && continue
        read START END ACQ REST <<< "$line"
        if [ "$ACQ" = "linear" ]; then
            for vol in $(seq $START $END); do
                LINEAR_VOLS="${LINEAR_VOLS}${LINEAR_VOLS:+,}$vol"
            done
        fi
    done < "$VOLUME_MAP"

    if [ -z "$LINEAR_VOLS" ]; then
        echo "  No linear volumes found for $SUB_ID — skipping"
        continue
    fi

    echo "  Linear volumes: $LINEAR_VOLS"

    # Output paths
    SUB_OUT="$OUTPUT_DIR/$SUB_ID"
    mkdir -p "$SUB_OUT"

    LINEAR_MIF="$SUB_OUT/${SUB_ID}_linear.mif"
    TENSOR="$SUB_OUT/${SUB_ID}_tensor.mif"
    FA="$SUB_OUT/${SUB_ID}_FA.nii.gz"
    MD="$SUB_OUT/${SUB_ID}_MD.nii.gz"

    # Extract linear volumes and embed gradients
    mrconvert "$DWI" "$LINEAR_MIF" \
        -fslgrad "$BVEC" "$BVAL" \
        -coord 3 "$LINEAR_VOLS" -force

    # Fit tensor
    dwi2tensor "$LINEAR_MIF" "$TENSOR" -force

    # Extract FA and MD
    tensor2metric "$TENSOR" -fa "$FA" -adc "$MD" -force

    echo "  ✓ FA and MD saved to $SUB_OUT"
done