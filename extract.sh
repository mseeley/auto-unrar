#!/bin/bash

# Environment variables and their defaults
source_directory="${SOURCE_DIRECTORY:-/data}"
sleep_time="${SLEEP_TIME:-3600}" # Default to 3600 seconds (1 hour)
do_not_use_markers="${DO_NOT_USE_MARKERS:-false}"
overwrite_files="${OVERWRITE_FILES:-false}"
extract_to_directory="${EXTRACT_TO_DIRECTORY:-}"
delete_rar_after_extraction="${DELETE_RAR_AFTER_EXTRACTION:-false}"

# Check for 'unrar' command availability
if ! command -v unrar &> /dev/null; then
    echo "Error: 'unrar' is not installed. Please install 'unrar' to use this script."
    exit 1
fi

# Create the output directory if it doesn't exist
if [ -n "$extract_to_directory" ] && [ ! -d "$extract_to_directory" ]; then
    echo "Output directory $extract_to_directory does not exist. Attempting to create..."
    mkdir -p "$extract_to_directory"
    if [ $? -ne 0 ]; then
        echo "Critical Error: Failed to create directory $extract_to_directory. Exiting script."
        exit 1
    fi
fi

# Function to extract RAR files, considering overwrite flag and handling errors
extract_rars() {
    find "$source_directory" -type f -iname "*.rar" -print0 | while IFS= read -r -d $'\0' rarfile; do
        # Archives written on Windows often arrive as .RAR or .Rar, so compare
        # against a lowercased copy of the name. unrar itself builds the name of
        # each following volume from the one it was given, preserving case, so
        # nothing past this point needs to care.
        filename=$(basename "$rarfile" | tr '[:upper:]' '[:lower:]')

        # Only the first volume of a multi-part set is an entry point; unrar
        # pulls in the remaining volumes itself. rar pads part numbers to a
        # width that depends on how many volumes there are (.part1.rar up to 9,
        # .part01.rar up to 99, .part001.rar beyond), so match any width and
        # treat a 1 with any amount of zero padding as the first volume.
        if [[ "$filename" =~ \.part([0-9]+)\.rar$ ]]; then
            if [[ ! "${BASH_REMATCH[1]}" =~ ^0*1$ ]]; then
                continue # A later volume of a set we either handled or will handle
            fi
        fi

        base_dir=$(dirname "$rarfile")
        output_dir="${extract_to_directory:-$base_dir}"

        # Construct unique marker files for each archive file
        marker_file="$base_dir/$(basename "$rarfile").extracted.marker"
        errormarker_file="$base_dir/$(basename "$rarfile").extracted.error"
        errorskipmarker_file="$base_dir/$(basename "$rarfile").extracted.errorskip"

        if [ "$do_not_use_markers" = "false" ] && { [ -f "$marker_file" ] || [ -f "$errorskipmarker_file" ]; }; then
            continue # Skip if markers indicate extraction or skipping is warranted
        fi

        # Set the overwrite flag based on the environment variable
        overwrite_flag="-o-"
        if [ "$overwrite_files" = "true" ]; then
            overwrite_flag="-o+"
        fi
        
        echo # This adds a blank line before each extraction attempt for better readability
        echo -e "\n\nAttempting to extract: $rarfile to $output_dir"
        output=$(unrar x $overwrite_flag "$rarfile" "$output_dir/" 2>&1)
        result=$?
        
        if [ $result -eq 0 ]; then
            echo "Extraction successful: $rarfile"
            touch "$marker_file"
        else
            # Check output for indication of skipped files due to -o- flag
            if echo "$output" | grep -iE 'already exists|All OK|no files to extract'; then
                echo "Completed with file skips (existing files not overwritten): $rarfile"
                touch "$marker_file" # Still mark as successfully extracted
            else
                # Increment error count in the errormarker file
                if [ -f "$errormarker_file" ]; then
                    error_count=$(<"$errormarker_file")
                    error_count=$((error_count + 1))
                    echo "$error_count" > "$errormarker_file"
                else
                    echo "1" > "$errormarker_file"
                fi

                # Create error skip marker if error count exceeds 5
                if [ "$(cat "$errormarker_file")" -ge 5 ]; then
                    touch "$errorskipmarker_file"
                fi

                echo "Error extracting $rarfile" 
            fi
        fi

        if [ "$delete_rar_after_extraction" = "true" ] && [ -f "$marker_file" ]; then
            # Ask unrar which volumes it actually opened rather than guessing at
            # extensions. It prints one "Extracting from <path>" line per volume,
            # including the entry point, so this covers every naming scheme:
            # .rar/.r00../.s00../.t00.. for sets over 100 volumes, and .partNN.rar
            # regardless of how many digits the part numbers use.
            deleted_count=0
            while IFS= read -r volume; do
                if [ -n "$volume" ] && [ -f "$volume" ]; then
                    rm -f "$volume"
                    deleted_count=$((deleted_count + 1))
                fi
            done <<< "$(printf '%s\n' "$output" | sed -n 's/^Extracting from //p')"

            if [ "$deleted_count" -gt 0 ]; then
                echo "Deleted $deleted_count archive volume(s) for: $rarfile"
            else
                # No volume lines in the output. Remove the entry point so it is
                # never left behind, but leave anything we cannot identify alone.
                echo "Warning: could not determine the volume list for $rarfile. Deleting the entry point only."
                rm -f "$rarfile"
            fi
        fi
    done
}



# Display ASCII art and welcome message
cat << "EOF"
   _____          __                    ____ ___     __________    _____ __________ 
  /  _  \  __ ___/  |_  ____           |    |   \____\______   \  /  _  \\______   \
 /  /_\  \|  |  \   __\/  _ \   ______ |    |   /    \|       _/ /  /_\  \|       _/
/    |    \  |  /|  | (  <_> ) /_____/ |    |  /   |  \    |   \/    |    \    |   \
\____|__  /____/ |__|  \____/          |______/|___|  /____|_  /\____|__  /____|_  /
        \/                                          \/       \/         \/       \/ 
Auto-UnRAR by nicxx2
Thank you for using my tool.
EOF

echo # Adds an extra line after the welcome message

# Calculate hours and minutes from sleep_time for the welcome message
hours=$((sleep_time / 3600))
minutes=$(((sleep_time % 3600) / 60))

echo # Adds an extra line before the check frequency message

# Show initial message about check frequency
echo "Checks will be done every $hours hour(s) and $minutes minute(s)."

echo # Adds an extra line after the check frequency message

# Message about the log behavior
echo "Below it will show the extraction of the RAR files when the checking process is running."
echo "If nothing is shown below, it's because nothing was extracted yet, or files were already marked in the past using this tool and thus are skipped."


echo # Adds an extra line before starting the infinite loop

# Infinite loop to run extraction based on user-defined frequency
while true; do
    extract_rars

    sleep "$sleep_time"
done
