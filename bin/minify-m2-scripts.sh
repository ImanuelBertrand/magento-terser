#!/usr/bin/env bash

# Check if the terser command is available. TERSER_PACKAGE, below, stands in for it.
if [ -z "$TERSER_PACKAGE" ] && ! command -v terser &> /dev/null; then
    if command -v npm &> /dev/null; then
        echo "ERROR: The terser command is not available. Please install terser by running:"
        echo "npm install terser -g"
    else
        echo "ERROR: The terser command requires npm to be installed. Please install npm and run 'npm install terser -g' to install terser."
    fi
    exit 1
fi

if ! command -v node &> /dev/null; then
    echo "ERROR: terser is installed, but the node command it runs on is not available."
    exit 1
fi

# Resolves symlinks through node rather than `readlink -f`, which macOS before 12.3 lacks.
realpath_of() {
    node -e 'process.stdout.write(require("fs").realpathSync(process.argv[1]))' "$1"
}

is_terser_package() {
    [ -f "$1/package.json" ] && node -e 'process.exit(require(process.argv[1]).name === "terser" ? 0 : 1)' "$1/package.json" 2> /dev/null
}

# The minification runs through terser's API rather than its command, so it needs the package the
# command belongs to. npm links the command to bin/terser inside it; a shim that is a script rather
# than a link (pnpm, Volta) leads nowhere, so npm's global root is tried after that, and
# TERSER_PACKAGE overrides both.
# It is made absolute because the workers resolve it relative to their own file, not to the cwd.
if [ -n "$TERSER_PACKAGE" ]; then
    if ! terser_package=$(realpath_of "$TERSER_PACKAGE" 2> /dev/null) || ! is_terser_package "$terser_package"; then
        echo "ERROR: TERSER_PACKAGE ($TERSER_PACKAGE) is not the directory of the terser package."
        exit 1
    fi
else
    terser_package=$(dirname "$(dirname "$(realpath_of "$(command -v terser)")")")
    if ! is_terser_package "$terser_package" && command -v npm &> /dev/null; then
        terser_package="$(npm root -g 2> /dev/null)/terser"
    fi
fi
if ! is_terser_package "$terser_package"; then
    echo "ERROR: Could not find the terser package that the terser command at $(command -v terser) belongs to."
    echo "Set TERSER_PACKAGE to the directory of the terser package."
    exit 1
fi

script_dir=$(dirname "$(realpath_of "${BASH_SOURCE[0]}")")

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
display_progress_bar=1
silent=0
gzip=0
gzip_keep=0
themes=()

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
        --theme=*|--theme)
            if [[ $1 == --theme ]]; then
                theme=$2
                shift
            else
                theme=${1#*=}
            fi
            if [[ ! $theme =~ ^[^/]+/[^/]+$ || /$theme/ == */./* || /$theme/ == */../* ]]; then
                echo "ERROR: Invalid value for theme, expected Vendor/theme."
                exit 1
            fi
            # Naming a theme twice would minify its files twice.
            if [[ ! " ${themes[*]} " == *" $theme "* ]]; then
                themes+=("$theme")
            fi
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
            echo "Usage: $0 [-j NUM_JOBS] [--theme=Vendor/theme] [-v]"
            echo ""
            echo "Options:"
            echo "  -j NUM_JOBS, --jobs=NUM_JOBS   The number of jobs to run in parallel. Default is 1."
            echo "  --theme=Vendor/theme           Only minify this theme. Can be given more than once."
            echo "                                 Default is every theme."
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

# The directories to minify: the whole of $operating_dir, or each theme named with --theme.
search_dirs=()
if (( ${#themes[@]} )); then
    for theme in "${themes[@]}"; do
        if [ ! -d "$operating_dir/$theme" ]; then
            echo "ERROR: Theme $theme has not been deployed to $operating_dir."
            exit 1
        fi
        search_dirs+=("$operating_dir/$theme/")
    done
else
    search_dirs=("$operating_dir/")
fi

find_scripts() {
    find "${search_dirs[@]}" -type f -name '*.js' -not -name '*.min.js' -not -name 'requirejs-bundle-config.js' -print0
}

# Count the number of JavaScript files that need to be minified.
num_files=$(find_scripts | tr -cd '\0' | wc -c)

if (( ! silent )); then
    printf "Minifying %d JavaScript files with %d jobs...\n" "$num_files" "$max_jobs"
fi

minify_args=("--terser=$terser_package" "--jobs=$max_jobs")
if (( verbose )); then
    minify_args+=(--verbose)
fi
if (( ! display_progress_bar )); then
    minify_args+=(--no-progress-bar)
fi

# A file terser cannot parse is reported and left as it was; only a failure of the run itself
# ends the script.
find_scripts | node "$script_dir/minify-m2-scripts.cjs" "${minify_args[@]}" || exit 1

if (( gzip )); then
    if (( ! silent )); then
        printf "\n"
        printf "Gzipping %d JavaScript files with %d jobs...\n" "$num_files" "$max_jobs"
    fi

    if (( gzip_keep )); then
      find_scripts | xargs -0 -P "$max_jobs" -I {} gzip -f -k {}
    else
      find_scripts | xargs -0 -P "$max_jobs" -I {} gzip -f {}
    fi
fi

# Move the cursor to the next line after the progress bar is finished.
if (( display_progress_bar )); then
  printf "\n"
fi
