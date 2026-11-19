#!/bin/bash

# Simplified DWI Processing Pipeline
# Focus: Denoising and SNR analysis
# 
# Usage: ./denoise_pipe.sh <bids_directory> <t1_wm_directory> <output_directory> [--remove-temp]

set -e  # Exit on error

# Check if required arguments are provided
if [ $# -lt 3 ] || [ $# -gt 4 ]; then
    echo "Usage: $0 <bids_directory> <t1_wm_directory> <output_directory> [--remove-temp]"
    echo ""
    echo "Arguments:"
    echo "  bids_directory:       Original BIDS DWI data directory"
    echo "                        Expected: sub-XX/dwi/*_dwi.nii.gz (with .bval/.bvec)"
    echo "  t1_wm_directory:      Directory with T1 brain and WM masks"
    echo "                        Expected: sub-XX_t1_BrainExtractionBrain.nii.gz"
    echo "                                  sub-XX_wm_bin_mask.nii.gz (generated if missing)"
    echo "  output_directory:     Directory to save all outputs"
    echo "  --remove-temp:        Optional flag to delete temporary files after each subject"
    echo "                        (default: keep them; registration_pipe.sh needs temp/sub-XX_mean_b0.nii.gz)"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/bids /path/to/t1s /path/to/results"
    exit 1
fi

BIDS_DIR="$1"
T1_WM_DIR="$2"
OUTPUT_DIR="$3"
KEEP_TEMP=true

# Check for optional flag
if [ $# -eq 4 ]; then
    if [ "$4" == "--remove-temp" ]; then
        KEEP_TEMP=false
        echo "Note: Temporary files will be deleted after each subject"
    else
        echo "Error: Unknown flag '$4'"
        exit 1
    fi
fi

# Check if directories exist
if [ ! -d "$BIDS_DIR" ]; then
    echo "Error: BIDS directory does not exist: $BIDS_DIR"
    exit 1
fi

if [ ! -d "$T1_WM_DIR" ]; then
    echo "Error: T1/WM directory does not exist: $T1_WM_DIR"
    exit 1
fi

# Check if required tools are installed
for cmd in mrconvert mrcat dwidenoise mrstats mrinfo mrcalc mrmath dwiextract mrdump; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd (MRtrix3) not found. Please install MRtrix3."
        exit 1
    fi
done

for cmd in flirt fslmaths fslstats fast; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd (FSL) not found. Please install FSL."
        exit 1
    fi
done

if ! command -v bc &> /dev/null; then
    echo "Error: bc not found. Please install bc for calculations."
    exit 1
fi

# Create output directories
mkdir -p "$OUTPUT_DIR"
DENOISED_DIR="$OUTPUT_DIR/01_denoised"
SNR_DIR="$OUTPUT_DIR/02_snr_analysis"

mkdir -p "$DENOISED_DIR"
mkdir -p "$SNR_DIR"

# Master log file
LOG_FILE="$OUTPUT_DIR/pipeline_processing.log"
echo "========================================" | tee "$LOG_FILE"
echo "Simplified DWI Processing Pipeline" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Started at: $(date)" | tee -a "$LOG_FILE"
echo "BIDS directory: $BIDS_DIR" | tee -a "$LOG_FILE"
echo "T1/WM directory: $T1_WM_DIR" | tee -a "$LOG_FILE"
echo "Output directory: $OUTPUT_DIR" | tee -a "$LOG_FILE"
echo "----------------------------------------" | tee -a "$LOG_FILE"

# Find all subjects
SUBJECTS=$(find "$BIDS_DIR" -maxdepth 1 -type d -name "sub-*" | sort)

if [ -z "$SUBJECTS" ]; then
    echo "Error: No subjects found in BIDS directory" | tee -a "$LOG_FILE"
    exit 1
fi

NUM_SUBJECTS=$(echo "$SUBJECTS" | wc -l)
echo "Found $NUM_SUBJECTS subjects to process" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Initialize aggregate CSV files
echo "Initializing aggregate CSV files..." | tee -a "$LOG_FILE"

# SNR statistics CSV (original data only, within WM mask)
SNR_CSV="$OUTPUT_DIR/all_subjects_snr_summary.csv"
if [ ! -f "$SNR_CSV" ]; then
    echo "subject,bvalue,acquisition_type,mean_signal_wm,snr_mean_wm,snr_min_wm,snr_max_wm,snr_std_wm" > "$SNR_CSV"
fi

echo "" | tee -a "$LOG_FILE"

# Process each subject
CURRENT_SUB=0

for SUB_DIR in $SUBJECTS; do
    SUB_ID=$(basename "$SUB_DIR")
    CURRENT_SUB=$((CURRENT_SUB + 1))
    
    echo "========================================" | tee -a "$LOG_FILE"
    echo "Processing subject $CURRENT_SUB/$NUM_SUBJECTS: $SUB_ID" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    
    # Remove any existing rows for this subject from CSVs (prevents duplicates on rerun)
    # Uses portable syntax that works on both macOS (BSD sed) and Linux (GNU sed)
    #sed -i'' "/^${SUB_ID},/d" "$SNR_CSV"
    #sed -i'' "/^${SUB_ID},/d" "$FA_CSV"
    
    # Create subject output directories
    SUB_DENOISED_DIR="$DENOISED_DIR/$SUB_ID/dwi"
    SUB_SNR_DIR="$SNR_DIR/$SUB_ID"
    
    mkdir -p "$SUB_DENOISED_DIR"
    mkdir -p "$SUB_SNR_DIR"
    
    # Create temporary directory
    TEMP_DIR="$SUB_DENOISED_DIR/temp"
    mkdir -p "$TEMP_DIR"
    
    # Check for DWI directory
    DWI_DIR="$SUB_DIR/dwi"
    
    if [ ! -d "$DWI_DIR" ]; then
        echo "  Warning: No dwi directory found for $SUB_ID, skipping" | tee -a "$LOG_FILE"
        continue
    fi
    
    # Find all DWI files
    DWI_FILES=$(find "$DWI_DIR" -name "*_dwi.nii.gz" -o -name "*_dwi.nii" | sort)
    
    if [ -z "$DWI_FILES" ]; then
        echo "  Warning: No DWI files found for $SUB_ID, skipping" | tee -a "$LOG_FILE"
        continue
    fi
    
    # Convert to array
    DWI_ARRAY=($DWI_FILES)
    
    # Define output file paths (used to check if already done)
    ORIGINAL_CONCAT_NIFTI="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi_original.nii.gz"
    DENOISED_NIFTI="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi_denoised.nii.gz"
    NOISE_NIFTI="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi_noise.nii.gz"
    CONCAT_BVAL="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi.bval"
    CONCAT_BVEC="$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi.bvec"
    VOLUME_MAP="$SUB_DENOISED_DIR/${SUB_ID}_volume_mapping.txt"
    
    # Temp MIF paths (needed by downstream steps)
    CONCAT_DWI="$TEMP_DIR/${SUB_ID}_concat_dwi.mif"
    DENOISED_MIF="$TEMP_DIR/${SUB_ID}_denoised.mif"
    NOISE_MIF="$TEMP_DIR/${SUB_ID}_noise.mif"
    
    # Check if steps 1+2 were already completed
    if [ -f "$ORIGINAL_CONCAT_NIFTI" ] && [ -f "$DENOISED_NIFTI" ] && [ -f "$NOISE_NIFTI" ] && [ -f "$CONCAT_BVAL" ] && [ -f "$CONCAT_BVEC" ] && [ -f "$VOLUME_MAP" ]; then
        echo "" | tee -a "$LOG_FILE"
        echo "STEPS 1+2: Previously completed - reloading from disk" | tee -a "$LOG_FILE"
        echo "----------------------------------------" | tee -a "$LOG_FILE"
        echo "  Found: $(basename $ORIGINAL_CONCAT_NIFTI)" | tee -a "$LOG_FILE"
        echo "  Found: $(basename $DENOISED_NIFTI)" | tee -a "$LOG_FILE"
        echo "  Found: $(basename $NOISE_NIFTI)" | tee -a "$LOG_FILE"
        
        # Use existing MIF files if present, otherwise convert from NIfTI
        if [ -f "$CONCAT_DWI" ] && [ -f "$DENOISED_MIF" ] && [ -f "$NOISE_MIF" ]; then
            echo "  Found existing MIF files in temp, using directly" | tee -a "$LOG_FILE"
        else
            echo "  MIF files not found, converting from NIfTI..." | tee -a "$LOG_FILE"
            mrconvert "$ORIGINAL_CONCAT_NIFTI" "$CONCAT_DWI" -fslgrad "$CONCAT_BVEC" "$CONCAT_BVAL" -force
            mrconvert "$DENOISED_NIFTI" "$DENOISED_MIF" -fslgrad "$CONCAT_BVEC" "$CONCAT_BVAL" -force
            mrconvert "$NOISE_NIFTI" "$NOISE_MIF" -force
        fi
        
        echo "  ✓ Skipping to Step 3" | tee -a "$LOG_FILE"
    else
        # ========================================
        # STEP 1: CONCATENATE WITH MRCONVERT
        # ========================================
        echo "" | tee -a "$LOG_FILE"
        echo "STEP 1: Concatenating DWI files with embedded gradients" | tee -a "$LOG_FILE"
        echo "----------------------------------------" | tee -a "$LOG_FILE"
        
        VALID_DWI_FILES=()
        VALID_BVAL_FILES=()
        VALID_BVEC_FILES=()
        ACQ_TYPES=()
        
        # Verify files and extract acquisition types
        for DWI_FILE in "${DWI_ARRAY[@]}"; do
            BASE="${DWI_FILE%.nii.gz}"
            BASE="${BASE%.nii}"
            BVAL_FILE="${BASE}.bval"
            BVEC_FILE="${BASE}.bvec"
            
            if [ -f "$BVAL_FILE" ] && [ -f "$BVEC_FILE" ]; then
                VALID_DWI_FILES+=("$DWI_FILE")
                VALID_BVAL_FILES+=("$BVAL_FILE")
                VALID_BVEC_FILES+=("$BVEC_FILE")
                
                # Extract acquisition type
                BASENAME=$(basename "$DWI_FILE")
                if [[ $BASENAME =~ acq-linear ]]; then
                    ACQ_TYPES+=("linear")
                    echo "  Found linear: $BASENAME" | tee -a "$LOG_FILE"
                elif [[ $BASENAME =~ acq-spherical ]]; then
                    ACQ_TYPES+=("spherical")
                    echo "  Found spherical: $BASENAME" | tee -a "$LOG_FILE"
                else
                    ACQ_TYPES+=("unknown")
                    echo "  Warning: Unknown acquisition type: $BASENAME" | tee -a "$LOG_FILE"
                fi
            fi
        done
        
        NUM_VALID=${#VALID_DWI_FILES[@]}
        
        if [ $NUM_VALID -eq 0 ]; then
            echo "  Error: No valid DWI files with bval/bvec found for $SUB_ID" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            continue
        fi
        
        echo "  Converting $NUM_VALID scans to MIF format..." | tee -a "$LOG_FILE"
        
        # Convert each file to MIF with gradients
        MIF_FILES=()
        
        for i in "${!VALID_DWI_FILES[@]}"; do
            DWI_FILE="${VALID_DWI_FILES[$i]}"
            BVAL_FILE="${VALID_BVAL_FILES[$i]}"
            BVEC_FILE="${VALID_BVEC_FILES[$i]}"
            
            DWI_BASENAME=$(basename "$DWI_FILE")
            DWI_BASENAME="${DWI_BASENAME%.nii.gz}"
            DWI_BASENAME="${DWI_BASENAME%.nii}"
            
            MIF_FILE="$TEMP_DIR/${DWI_BASENAME}.mif"
            
            if mrconvert "$DWI_FILE" "$MIF_FILE" -fslgrad "$BVEC_FILE" "$BVAL_FILE" -force; then
                MIF_FILES+=("$MIF_FILE")
            else
                echo "    Error: Failed to convert $DWI_BASENAME" | tee -a "$LOG_FILE"
            fi
        done
        
        if [ ${#MIF_FILES[@]} -eq 0 ]; then
            echo "  Error: No MIF files created for $SUB_ID" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            continue
        fi
        
        # Concatenate MIF files
        echo "  Concatenating ${#MIF_FILES[@]} MIF files..." | tee -a "$LOG_FILE"
        
        if ! mrcat "${MIF_FILES[@]}" "$CONCAT_DWI" -axis 3 -force; then
            echo "  Error: mrcat failed for $SUB_ID" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            continue
        fi
        
        # Export gradients to FSL format
        mrinfo "$CONCAT_DWI" -export_grad_fsl "$CONCAT_BVEC" "$CONCAT_BVAL"
        
        # Save original concatenated data as NIfTI
        mrconvert "$CONCAT_DWI" "$ORIGINAL_CONCAT_NIFTI" -export_grad_fsl "$CONCAT_BVEC" "$CONCAT_BVAL" -force
        
        echo "  ✓ Concatenation complete" | tee -a "$LOG_FILE"
        
        # Create volume mapping file
        echo "# Volume mapping for $SUB_ID concatenated DWI" > "$VOLUME_MAP"
        echo "# Format: start_volume end_volume acquisition_type filename" >> "$VOLUME_MAP"
        echo "# Volumes are 0-indexed" >> "$VOLUME_MAP"
        
        CURRENT_VOL=0
        
        for i in "${!VALID_DWI_FILES[@]}"; do
            DWI_FILE="${VALID_DWI_FILES[$i]}"
            BVAL_FILE="${VALID_BVAL_FILES[$i]}"
            ACQ_TYPE="${ACQ_TYPES[$i]}"
            
            NUM_VOLS=$(cat "$BVAL_FILE" | wc -w)
            END_VOL=$((CURRENT_VOL + NUM_VOLS - 1))
            
            echo "$CURRENT_VOL $END_VOL $ACQ_TYPE $(basename $DWI_FILE)" >> "$VOLUME_MAP"
            
            CURRENT_VOL=$((END_VOL + 1))
        done
        
        # ========================================
        # STEP 2: DENOISE
        # ========================================
        echo "" | tee -a "$LOG_FILE"
        echo "STEP 2: Denoising concatenated data" | tee -a "$LOG_FILE"
        echo "----------------------------------------" | tee -a "$LOG_FILE"
        
        echo "  Running dwidenoise..." | tee -a "$LOG_FILE"
        
        if dwidenoise "$CONCAT_DWI" "$DENOISED_MIF" -noise "$NOISE_MIF" -force; then
            echo "  ✓ Denoising complete" | tee -a "$LOG_FILE"
            
            # Convert to NIfTI
            mrconvert "$DENOISED_MIF" "$DENOISED_NIFTI" -export_grad_fsl "$CONCAT_BVEC" "$CONCAT_BVAL" -force
            mrconvert "$NOISE_MIF" "$NOISE_NIFTI" -force
            
            # Copy bval/bvec for denoised data
            cp "$CONCAT_BVAL" "$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi_denoised.bval"
            cp "$CONCAT_BVEC" "$SUB_DENOISED_DIR/${SUB_ID}_concat_dwi_denoised.bvec"
            
            echo "  ✓ Noise map saved" | tee -a "$LOG_FILE"
        else
            echo "  Error: dwidenoise failed for $SUB_ID" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            continue
        fi
    fi
    
    # ========================================
    # STEP 3: FIND T1 AND CREATE/FIND WM MASK
    # ========================================
    echo "" | tee -a "$LOG_FILE"
    echo "STEP 3: Finding T1 and WM mask (generating if needed)" | tee -a "$LOG_FILE"
    echo "----------------------------------------" | tee -a "$LOG_FILE"
    
    # Find skull-stripped T1 (BIDS subject ID)
    T1_FILE=$(find "$T1_WM_DIR" -name "${SUB_ID}_t1_BrainExtractionBrain.nii.gz" | head -1)
    
    if [ -z "$T1_FILE" ]; then
        echo "  Error: T1 file not found for $SUB_ID" | tee -a "$LOG_FILE"
        echo "  Expected: $T1_WM_DIR/${SUB_ID}_t1_BrainExtractionBrain.nii.gz" | tee -a "$LOG_FILE"
        rm -rf "$TEMP_DIR"
        continue
    fi
    
    echo "  Found T1: $(basename $T1_FILE)" | tee -a "$LOG_FILE"
    
    # Check if WM mask already exists
    WM_MASK_FILE=$(find "$T1_WM_DIR" -name "${SUB_ID}_wm_bin_mask.nii.gz" | head -1)
    
    if [ -z "$WM_MASK_FILE" ]; then
        echo "  WM mask not found, generating with FSL FAST..." | tee -a "$LOG_FILE"
        
        # Create WM mask output path
        WM_MASK_FILE="$T1_WM_DIR/${SUB_ID}_wm_bin_mask.nii.gz"
        
        # Run FAST segmentation (3-class tissue segmentation)
        FAST_OUTPUT="$TEMP_DIR/${SUB_ID}_fast"
        
        echo "    Running FAST segmentation (3-class)..." | tee -a "$LOG_FILE"
        
        if fast -t 1 -n 3 -o "$FAST_OUTPUT" "$T1_FILE" > /dev/null 2>&1; then
            
            echo "    ✓ FAST segmentation complete" | tee -a "$LOG_FILE"
            
            # FAST outputs:
            # ${FAST_OUTPUT}_pve_0.nii.gz = CSF partial volume
            # ${FAST_OUTPUT}_pve_1.nii.gz = Gray Matter partial volume
            # ${FAST_OUTPUT}_pve_2.nii.gz = White Matter partial volume
            # ${FAST_OUTPUT}_seg.nii.gz   = Hard segmentation
            
            WM_PVE="${FAST_OUTPUT}_pve_2.nii.gz"
            
            if [ ! -f "$WM_PVE" ]; then
                echo "  Error: FAST did not produce WM probability map" | tee -a "$LOG_FILE"
                rm -rf "$TEMP_DIR"
                continue
            fi
            
            # Create binary WM mask: threshold at 0.9 (90%)
            echo "    Creating binary WM mask (threshold = 0.9)..." | tee -a "$LOG_FILE"
            fslmaths "$WM_PVE" -thr 0.9 -bin "$WM_MASK_FILE"
            
            echo "    ✓ WM mask created: $(basename $WM_MASK_FILE)" | tee -a "$LOG_FILE"
            
            # Optional: Save FAST outputs for QC
            FAST_QC_DIR="$T1_WM_DIR/fast_qc"
            mkdir -p "$FAST_QC_DIR"
            
            # Save tissue probability maps
            cp "${FAST_OUTPUT}_pve_0.nii.gz" "$FAST_QC_DIR/${SUB_ID}_pve_csf.nii.gz" 2>/dev/null
            cp "${FAST_OUTPUT}_pve_1.nii.gz" "$FAST_QC_DIR/${SUB_ID}_pve_gm.nii.gz" 2>/dev/null
            cp "${FAST_OUTPUT}_pve_2.nii.gz" "$FAST_QC_DIR/${SUB_ID}_pve_wm.nii.gz" 2>/dev/null
            cp "${FAST_OUTPUT}_seg.nii.gz" "$FAST_QC_DIR/${SUB_ID}_seg.nii.gz" 2>/dev/null
            
            echo "    QC files saved to: $FAST_QC_DIR" | tee -a "$LOG_FILE"
            
        else
            echo "  Error: FAST segmentation failed for $SUB_ID" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            continue
        fi
    else
        echo "  Found existing WM mask: $(basename $WM_MASK_FILE)" | tee -a "$LOG_FILE"
    fi
    
    # ========================================
    # STEP 4: REGISTER T1 WM MASK TO DWI SPACE
    # ========================================
    echo "" | tee -a "$LOG_FILE"
    echo "STEP 4: Registering T1 WM mask to DWI space" | tee -a "$LOG_FILE"
    echo "----------------------------------------" | tee -a "$LOG_FILE"
    
    WM_MASK_DWI_NIFTI="$SUB_SNR_DIR/${SUB_ID}_WM_mask_DWI_space.nii.gz"
    WM_MASK_DWI_MIF="$TEMP_DIR/${SUB_ID}_WM_mask_DWI.mif"
    
    if [ -f "$WM_MASK_DWI_NIFTI" ]; then
        echo "  WM mask in DWI space already exists, skipping registration" | tee -a "$LOG_FILE"
        
        # Use existing MIF if available, otherwise convert from NIfTI
        if [ -f "$WM_MASK_DWI_MIF" ]; then
            echo "  Found existing MIF, using directly" | tee -a "$LOG_FILE"
        else
            echo "  Converting existing NIfTI to MIF..." | tee -a "$LOG_FILE"
            mrconvert "$WM_MASK_DWI_NIFTI" "$WM_MASK_DWI_MIF" -force
        fi
    else
        # Extract mean b0 from denoised data for registration target
        echo "  Extracting mean b0 from denoised data..." | tee -a "$LOG_FILE"
        B0S_MIF="$TEMP_DIR/${SUB_ID}_b0s.mif"
        MEAN_B0_MIF="$TEMP_DIR/${SUB_ID}_mean_b0.mif"
        MEAN_B0_NIFTI="$TEMP_DIR/${SUB_ID}_mean_b0.nii.gz"
        
        dwiextract "$DENOISED_MIF" -bzero "$B0S_MIF" -force
        mrmath "$B0S_MIF" mean "$MEAN_B0_MIF" -axis 3 -force
        mrconvert "$MEAN_B0_MIF" "$MEAN_B0_NIFTI" -force
        
        # Register T1 to mean b0
        echo "  Registering T1 to DWI space..." | tee -a "$LOG_FILE"
        T1_TO_DWI_MAT="$TEMP_DIR/${SUB_ID}_T1_to_DWI.mat"
        
        if flirt -in "$T1_FILE" -ref "$MEAN_B0_NIFTI" \
                 -omat "$T1_TO_DWI_MAT" \
                 -cost normmi \
                 -searchrx -30 30 -searchry -30 30 -searchrz -30 30; then
            echo "  ✓ T1 to DWI registration complete" | tee -a "$LOG_FILE"
        else
            echo "  Error: T1 to DWI registration failed for $SUB_ID" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            continue
        fi
        
        # Apply transformation to WM mask (nearest neighbor to preserve binary mask)
        echo "  Transforming WM mask to DWI space..." | tee -a "$LOG_FILE"
        
        if flirt -in "$WM_MASK_FILE" -ref "$MEAN_B0_NIFTI" \
                 -out "$WM_MASK_DWI_NIFTI" \
                 -init "$T1_TO_DWI_MAT" -applyxfm \
                 -interp nearestneighbour; then
            
            mrconvert "$WM_MASK_DWI_NIFTI" "$WM_MASK_DWI_MIF" -force
            echo "  ✓ WM mask transformed to DWI space" | tee -a "$LOG_FILE"
        else
            echo "  Error: WM mask transformation failed for $SUB_ID" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            continue
        fi
    fi
    
    # ========================================
    # STEP 5: SNR ANALYSIS (ORIGINAL DATA ONLY, WM MASK)
    # ========================================
    echo "" | tee -a "$LOG_FILE"
    echo "STEP 5: SNR analysis (original data, within WM)" | tee -a "$LOG_FILE"
    echo "----------------------------------------" | tee -a "$LOG_FILE"
    
    # Create SNR maps directory
    SNR_MAPS_DIR="$SUB_SNR_DIR/snr_maps"
    mkdir -p "$SNR_MAPS_DIR"
    
    # Check if SNR analysis was already completed by looking for any SNR map
    SNR_EXISTS=$(find "$SNR_MAPS_DIR" -name "${SUB_ID}_snr_*.nii.gz" 2>/dev/null | head -1)
    
    if [ -n "$SNR_EXISTS" ]; then
        echo "  SNR analysis already completed, skipping" | tee -a "$LOG_FILE"
        echo "  Found: $(ls -1 $SNR_MAPS_DIR/${SUB_ID}_snr_*.nii.gz 2>/dev/null | wc -l) SNR maps" | tee -a "$LOG_FILE"
    else
        # Build shell-acquisition combinations
        SHELL_ACQ_KEYS=()
        SHELL_ACQ_VOLUMES=()
    
    while IFS= read -r line; do
        [[ $line =~ ^# ]] && continue
        [[ -z $line ]] && continue
        
        read START_VOL END_VOL ACQ_TYPE FILENAME <<< "$line"
        
        for vol in $(seq $START_VOL $END_VOL); do
            BVAL=$(awk -v col=$((vol+1)) '{print $col}' "$CONCAT_BVAL")
            BVAL_ROUNDED=$(echo "scale=0; ($BVAL + 50) / 100 * 100" | bc)
            
            KEY="${BVAL_ROUNDED}_${ACQ_TYPE}"
            
            KEY_EXISTS=false
            for i in "${!SHELL_ACQ_KEYS[@]}"; do
                if [ "${SHELL_ACQ_KEYS[$i]}" = "$KEY" ]; then
                    SHELL_ACQ_VOLUMES[$i]="${SHELL_ACQ_VOLUMES[$i]},$vol"
                    KEY_EXISTS=true
                    break
                fi
            done
            
            if [ "$KEY_EXISTS" = false ]; then
                SHELL_ACQ_KEYS+=("$KEY")
                SHELL_ACQ_VOLUMES+=("$vol")
            fi
        done
    done < "$VOLUME_MAP"
    
    # Process each shell-acquisition combination
    for i in "${!SHELL_ACQ_KEYS[@]}"; do
        KEY="${SHELL_ACQ_KEYS[$i]}"
        VOLUMES="${SHELL_ACQ_VOLUMES[$i]}"
        
        IFS='_' read BVAL ACQ_TYPE <<< "$KEY"
        
        echo "  Processing b=$BVAL ($ACQ_TYPE) - WM only..." | tee -a "$LOG_FILE"
        
        # Extract volumes from ORIGINAL data
        ORIG_SUBSET="$TEMP_DIR/${SUB_ID}_orig_b${BVAL}_${ACQ_TYPE}.mif"
        mrconvert "$CONCAT_DWI" "$ORIG_SUBSET" -coord 3 $VOLUMES -force
        
        # Calculate mean across volumes
        ORIG_MEAN_VOL="$TEMP_DIR/${SUB_ID}_orig_b${BVAL}_${ACQ_TYPE}_mean.mif"
        mrmath "$ORIG_SUBSET" mean "$ORIG_MEAN_VOL" -axis 3 -force
        
        # Calculate mean signal within WM
        MEAN_SIGNAL=$(mrstats "$ORIG_MEAN_VOL" -mask "$WM_MASK_DWI_MIF" -output mean)
        
        # Create SNR map (signal / noise)
        SNR_MAP="$SNR_MAPS_DIR/${SUB_ID}_snr_b${BVAL}_${ACQ_TYPE}.nii.gz"
        mrcalc "$ORIG_MEAN_VOL" "$NOISE_MIF" -divide "$SNR_MAP" -force
        
        # Calculate SNR statistics within WM
        SNR_MEAN=$(mrstats "$SNR_MAP" -mask "$WM_MASK_DWI_MIF" -output mean)
        SNR_MIN=$(mrstats "$SNR_MAP" -mask "$WM_MASK_DWI_MIF" -output min)
        SNR_MAX=$(mrstats "$SNR_MAP" -mask "$WM_MASK_DWI_MIF" -output max)
        SNR_STD=$(mrstats "$SNR_MAP" -mask "$WM_MASK_DWI_MIF" -output std)
        
        # Write to CSV
        echo "$SUB_ID,$BVAL,$ACQ_TYPE,$MEAN_SIGNAL,$SNR_MEAN,$SNR_MIN,$SNR_MAX,$SNR_STD" >> "$SNR_CSV"
        
        echo "    ✓ SNR: mean=$SNR_MEAN, range=[$SNR_MIN, $SNR_MAX]" | tee -a "$LOG_FILE"
        
        # Create SNR distribution plot (WM only)
        if command -v python3 &> /dev/null; then
            SNR_VALUES="$SNR_MAPS_DIR/${SUB_ID}_snr_values_b${BVAL}_${ACQ_TYPE}.txt"
            mrdump "$SNR_MAP" -mask "$WM_MASK_DWI_MIF" > "$SNR_VALUES"
            
            SNR_PLOT="$SNR_MAPS_DIR/${SUB_ID}_snr_histogram_b${BVAL}_${ACQ_TYPE}.png"
            
            python3 << EOF
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

try:
    values = np.loadtxt('$SNR_VALUES')
    values = values[~np.isnan(values)]
    values = values[values > 0]
    
    if len(values) > 0:
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))
        
        # Histogram
        ax1.hist(values, bins=50, edgecolor='black', alpha=0.7, color='steelblue')
        ax1.set_xlabel('SNR', fontsize=12)
        ax1.set_ylabel('Number of WM Voxels', fontsize=12)
        ax1.set_title(f'SNR Distribution in WM (b=${BVAL}, ${ACQ_TYPE})', fontsize=14, fontweight='bold')
        ax1.axvline(x=np.mean(values), color='r', linestyle='--', linewidth=2, label=f'Mean: {np.mean(values):.2f}')
        ax1.axvline(x=np.median(values), color='g', linestyle='--', linewidth=2, label=f'Median: {np.median(values):.2f}')
        ax1.legend()
        ax1.grid(True, alpha=0.3)
        
        # Cumulative distribution
        sorted_vals = np.sort(values)
        cumulative = np.arange(1, len(sorted_vals) + 1) / len(sorted_vals) * 100
        ax2.plot(sorted_vals, cumulative, linewidth=2, color='darkblue')
        ax2.set_xlabel('SNR', fontsize=12)
        ax2.set_ylabel('Cumulative % of WM Voxels', fontsize=12)
        ax2.set_title('Cumulative SNR Distribution', fontsize=14, fontweight='bold')
        ax2.grid(True, alpha=0.3)
        
        # Add quality thresholds
        thresholds = [5, 10, 15, 20]
        for thresh in thresholds:
            pct = np.sum(values >= thresh) / len(values) * 100
            if 5 < pct < 95:
                ax2.axvline(x=thresh, color='red', linestyle=':', alpha=0.5)
                ax2.text(thresh, 50, f'{pct:.1f}% ≥ {thresh}', rotation=90, va='center', fontsize=9)
        
        plt.tight_layout()
        plt.savefig('$SNR_PLOT', dpi=150, bbox_inches='tight')
        plt.close()
        
        print(f"    SNR Stats (WM, b=${BVAL}, ${ACQ_TYPE}): Mean={np.mean(values):.2f}, % ≥ 10: {np.sum(values >= 10) / len(values) * 100:.1f}%")
except Exception as e:
    print(f"    Error creating SNR plot: {e}")
EOF
            
        fi
    done
    
    echo "  ✓ SNR analysis complete" | tee -a "$LOG_FILE"
    fi  # End of SNR skip check
    
    # Clean up temporary directory
    if [ "$KEEP_TEMP" = "true" ]; then
        echo "  Preserving temporary files in $TEMP_DIR" | tee -a "$LOG_FILE"
    else
        echo "  Cleaning up temporary files..." | tee -a "$LOG_FILE"
        rm -rf "$TEMP_DIR"
    fi
    
    echo "✓ Completed processing for $SUB_ID" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
done

# Final summary
echo "========================================" | tee -a "$LOG_FILE"
echo "PIPELINE COMPLETE" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Finished at: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Output directories:" | tee -a "$LOG_FILE"
echo "  Denoised data: $DENOISED_DIR" | tee -a "$LOG_FILE"
echo "  SNR analysis: $SNR_DIR" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Aggregate CSV file:" | tee -a "$LOG_FILE"
echo "  SNR (WM only): $SNR_CSV" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"