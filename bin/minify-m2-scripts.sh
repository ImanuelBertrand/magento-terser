#!/usr/bin/env bash

# This script minifies all JavaScript files in the pub/static/frontend directory of a Magento installation,
# except for those that are already minified or the requirejs-bundle-config.js file.

# Check if the terser command is available.
if ! command -v terser &> /dev/null; then
    if command -v npm &> /dev/null; then
        echo "ERROR: The terser command is not available. Please install terser by running:"
        echo "npm install terser -g"
    else
        echo "ERROR: The terser command requires npm to be installed. Please install npm and run 'npm install terser -g' to install terser."
    fi
    exit 1
fi

# Check if the script is being run from the main directory of Magento.
if [ ! -d "pub/static/frontend" ]; then
    echo "ERROR: You need to be in the main directory of Magento for this script to be run."
    exit 1
fi

# Check if the script is started with the -v or --verbose flag.
verbose=0
for arg in "$@"; do
    if [ "$arg" = "-v" ] || [ "$arg" = "--verbose" ]; then
        verbose=1
    fi
done

# Count the number of JavaScript files that need to be minified.
num_files=$(find pub/static/frontend/ -name '*.js' -not -name '*.min.js' -not -name 'requirejs-bundle-config.js' | wc -l)
processed_files=0

# Find all JavaScript files in the pub/static/frontend directory that need to be minified.
# Use the -print0 option to handle filenames with spaces and other special characters.
find pub/static/frontend/ -name '*.js' -not -name '*.min.js' -not -name 'requirejs-bundle-config.js' -print0 | while IFS= read -r -d $'\0' file; do
    # Print the filename if the script is started with the -v or --verbose flag.
    if [ $verbose -eq 1 ]; then
        printf "\rMinifying $file\n"
    fi

    # Calculate the length of the progress bar.
    bar_length=$((processed_files * 50 / num_files))
    # Display the progress bar.
    printf "\r["
    for i in $(seq 1 $bar_length); do
        printf "="
    done
    for i in $(seq 1 $((50 - bar_length))); do
        printf " "
    done
    printf "] %d/%d" $processed_files $num_files

    # Minify the JavaScript file using the terser command.
    terser -c -m reserved=['$','jQuery','define','require','exports'] -o "$file" "$file"
    # Check the return code of the terser command and display an error message if it failed.
    if [ $? -ne 0 ]; then
        echo "\rERROR: Failed to minify $file.\n"
    fi
    processed_files=$((processed_files+1))

done

# Move the cursor to the next line after the progress bar is finished.
printf "\n"
