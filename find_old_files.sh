#!/bin/bash

# --- CONFIGURATION (DEFAULTS) ---
TARGET_DIR="."
AGE_DAYS=365  # Default fallback if no flag is provided
DELETE_MODE=false
# ---------------------

# Parse runtime arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -d|--delete) 
            DELETE_MODE=true 
            shift 
            ;;
        -a|--age) 
            # Check if the next argument exists and is a positive integer
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                AGE_DAYS="$2"
                shift 2
            else
                echo "Error: --age requires a numeric value in days." >&2
                exit 1
            fi
            ;;
        *) 
            TARGET_DIR="$1" 
            shift 
            ;; 
    esac
done

# Safety check: Verify the target directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist." >&2
    exit 1
fi

# Print execution banner
if [ "$DELETE_MODE" = true ]; then
    echo "⚠️  WARNING: DELETION MODE ACTIVE"
    echo "Removing files in '$TARGET_DIR' unmodified for $AGE_DAYS+ days..."
else
    echo "🔍 SCAN MODE"
    echo "Listing files in '$TARGET_DIR' unmodified for $AGE_DAYS+ days..."
fi
echo "--------------------------------------------------------------------------------"

total_bytes=0
count=0

# Loop through matching files
while IFS= read -r -d '' file; do
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    total_bytes=$((total_bytes + size))
    count=$((count + 1))

    if [ "$DELETE_MODE" = true ]; then
        echo "Deleting: $file"
        rm "$file"
    else
        ls -lh "$file"
    fi

done < <(find "$TARGET_DIR" -type f -mtime +"$AGE_DAYS" -print0)

echo "--------------------------------------------------------------------------------"

# Format total bytes into human-readable units
human_size=$(awk -v b="$total_bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", u);
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++; }
    printf "%.2f %s", b, u[i]
}')

# Visual verification summary block
if [ "$DELETE_MODE" = true ]; then
    echo "Verification: Successfully deleted $count files."
    echo "Space reclaimed:      $human_size ($total_bytes bytes)"
else
    echo "Verification: Found $count files matching the age criteria."
    echo "Total potential size: $human_size ($total_bytes bytes)"
fi
echo "Age Threshold Rule:   $AGE_DAYS days"
