#!/usr/bin/env bash

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
if [ -d "pub/static/frontend" ]; then
    operating_dir="pub/static/frontend"
elif [ -d "init/pub/static/frontend" ]; then
    operating_dir="init/pub/static/frontend"
else
    echo "ERROR: You need to be in the main directory of Magento for this script to be run."
    exit 1
fi

# Default values
verbose=0
max_jobs=1
pids=()
display_progress_bar=1
silent=0
gzip=0
gzip_keep=0

# Parse arguments
while (( $# )); do
    case $1 in
        -j)
            if [[ ${2} =~ ^[0-9]+$ ]]; then
                max_jobs="$2"
                shift
            else
                echo "ERROR: Option requires an argument -- 'j'"
                exit 1
            fi
            shift
        ;;
        -j*)
            if [[ ${1#-j} =~ ^[0-9]+$ ]]; then
                max_jobs="${1#-j}"
            else
                echo "ERROR: Option requires a valid number as an argument following -j (e.g. -j3)"
                exit 1
            fi
            shift
        ;;
        --jobs=*)
            if [[ ${1#*=} =~ ^[0-9]+$ ]]; then
                max_jobs="${1#*=}"
            elif [[ ${1#*=} == "auto" ]]; then
                max_jobs=$(nproc)
            else
                echo "ERROR: Invalid value for jobs."
                exit 1
            fi
            shift
        ;;
        -v|--verbose)
            verbose=1
            shift
        ;;
        --gzip)
            gzip=1
            shift
        ;;
        --gzip-keep)
            gzip_keep=1
            shift
        ;;
        -h|--help)
            echo "Usage: $0 [-j NUM_JOBS] [-v]"
            echo ""
            echo "Options:"
            echo "  -j NUM_JOBS, --jobs=NUM_JOBS   The number of jobs to run in parallel. Default is 1."
            echo "  -v, --verbose                  Enable verbose mode."
            echo "  -h, --help                     Display this help message and exit."
            exit 0
        ;;
        --no-progress-bar)
            display_progress_bar=0
            shift
        ;;
        --silent)
            silent=1
            shift
        ;;
        *)
            # Unknown option
            shift
        ;;
    esac
done

if (( gzip_keep )); then
    gzip=1
fi

if (( silent )); then
    display_progress_bar=0
fi

# Function to wait for a free slot in the jobs pool
wait_for_slot() {
    while : ; do
        new_pids=()
        for pid in "${pids[@]}"; do
            # If the process is still running, add it to the new_pids array
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            else
                # A job has finished. Update the progress bar.
                if (( display_progress_bar )); then
                    processed_files=$((processed_files+1))
                    bar_length=$((processed_files * 50 / num_files))
                    printf "\r["
                    for _ in $(seq 1 $bar_length); do
                        printf "="
                    done
                    for _ in $(seq 1 $((50 - bar_length))); do
                        printf " "
                    done
                    printf "] %d/%d" "$processed_files" "$num_files"
                fi
            fi
        done
        pids=("${new_pids[@]}")
        # If there's a free slot, break the loop
        (( ${#pids[@]} < max_jobs )) && return
        sleep 0.01
    done
}

run_terser() {
    local file=$1
    terser -c -m reserved=['$','jQuery','define','require','exports'] -o "$file" "$file" || printf "\rERROR: Failed to minify %s\n" "$file"
}

# Count the number of JavaScript files that need to be minified.
num_files=$(find "$operating_dir/" -type f -name '*.js' -not -name '*.min.js' -not -name 'requirejs-bundle-config.js' | wc -l)
processed_files=0

if (( ! silent )); then
    printf "Minifying %d JavaScript files with %d jobs...\n" "$num_files" "$max_jobs"
fi

# Find all JavaScript files in the $operating_dir directory that need to be minified.
# Use the -print0 option to handle filenames with spaces and other special characters.
while IFS= read -r -d $'\0' file; do
    wait_for_slot

    # Print the filename if the script is started with the -v or --verbose flag.
    if [ $verbose -eq 1 ]; then
        printf "\rMinifying %s\n" "$file"
    fi

    # Minify the JavaScript file using the terser command in the background
    run_terser "$file" &
    pids+=("$!")
done < <(find "$operating_dir/" -type f -name '*.js' -not -name '*.min.js' -not -name 'requirejs-bundle-config.js' -print0)

# After the find loop, wait for remaining jobs
for pid in "${pids[@]}"; do
    wait "$pid"
done

if (( gzip )); then
    if (( ! silent )); then
        printf "\n"
        printf "Gzipping %d JavaScript files with %d jobs...\n" "$num_files" "$max_jobs"
    fi

    if (( gzip_keep )); then
      find "$operating_dir/" -type f -name '*.js' -not -name '*.min.js' -not -name 'requirejs-bundle-config.js' -print0 | xargs -0 -P "$max_jobs" -I {} gzip -f -k {}
    else
      find "$operating_dir/" -type f -name '*.js' -not -name '*.min.js' -not -name 'requirejs-bundle-config.js' -print0 | xargs -0 -P "$max_jobs" -I {} gzip -f {}
    fi
fi

# Move the cursor to the next line after the progress bar is finished.
if (( display_progress_bar )); then
  printf "\n"
fi
