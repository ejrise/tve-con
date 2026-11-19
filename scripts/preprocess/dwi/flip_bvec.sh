#!/bin/bash

# Script to flip first two rows of bvec files and make them negative
# For BIDS formatted datasets
# Skips files that already have backups

# Set your BIDS directory
BIDS_DIR="/path/to/bids"

# Find all bvec files in the BIDS directory
find "$BIDS_DIR" -name "*.bvec" | while read bvec_file; do
    
    # Check if backup already exists
    if [ -f "${bvec_file}.backup" ]; then
        echo "Skipping (backup exists): $bvec_file"
        continue
    fi
    
    echo "Processing: $bvec_file"
    
    # Create backup
    cp "$bvec_file" "${bvec_file}.backup"
    
    # Read the three rows
    row1=$(sed -n '1p' "$bvec_file")
    row2=$(sed -n '2p' "$bvec_file")
    row3=$(sed -n '3p' "$bvec_file")
    
    # Negate and swap rows 1 and 2
    neg_row1=$(echo "$row2" | awk '{for(i=1;i<=NF;i++) printf "%.6f ", -$i; print ""}')
    neg_row2=$(echo "$row1" | awk '{for(i=1;i<=NF;i++) printf "%.6f ", -$i; print ""}')
    
    # Write back to file
    echo "$neg_row1" > "$bvec_file"
    echo "$neg_row2" >> "$bvec_file"
    echo "$row3" >> "$bvec_file"
    
    echo "  ✓ Updated (backup saved as ${bvec_file}.backup)"
    
done

echo "Done! All bvec files processed."