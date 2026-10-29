# Magento 2 Terser

A Bash script that uses [terser](https://terser.org/) to minify your JavaScript files and can be run in the root directory of your Magento 2 installation.

The script will minify all JavaScript files in the pub/static/frontend directory of your Magento 2 installation, except for those that are already minified or the requirejs-bundle-config.js file.
The minification tasks can be run in parallel for increased performance.

## Installation

You can install the package using Composer. Run the following command in your terminal:
```bash
composer require ibertrand/magento2-terser
```
Alternatively, you can download the files `minify-m2-scripts.sh` and `minify-m2-scripts.cjs` from the `bin` directory and save them wherever you want, as long as they stay in the same directory.

The script requires the `terser` command and Node.js to be available. If you don't have terser installed, you can install it globally with `npm`:

```bash
npm install terser -g
```

If you don't have `npm` installed, you need to install it first.

The script finds the terser package through the `terser` command, or failing that in npm's global `node_modules`. If terser was installed in a way that leaves neither, as pnpm and Volta do, set `TERSER_PACKAGE` to the directory of the terser package.

## Usage

To run the script, open a terminal in the root directory of your Magento 2 installation and run:

```bash
vendor/bin/minify-m2-scripts.sh
```
This is assuming you installed the package using Composer. If you downloaded the files directly, you need to run `minify-m2-scripts.sh` with its full path.

By default, the script will minify all JavaScript files in the `pub/static/frontend` directory of your Magento 2 installation, except for those that are already minified or the `requirejs-bundle-config.js` file.

The original files will be replaced with the minified versions. If your M2 instance is in developer mode, this might alter files outside of the `pub/static/frontend` directory because of symlinks.

You can run the script with the `-v` or `--verbose` flag to display the name of each file that is being minified.
Alternatively, you can run it with `--no-progress-bar` or with `--silent`, which includes `--no-progress-bar`.

### Parallel execution
The script supports parallel execution of minification tasks to speed up the process. To specify the number of jobs to run in parallel, you can use the -j option followed by the number of jobs or --jobs= followed by the number of jobs.

For example, to run 3 jobs in parallel, you could use either of the below commands:
```
vendor/bin/minify-m2-scripts.sh -j3
vendor/bin/minify-m2-scripts.sh --jobs=3
```

`--jobs=auto` runs one job per CPU.

Each job is a worker thread that loads terser once and then minifies one file after another, so the time goes into minifying rather than into starting Node for every file.

### Minifying only some themes
By default every theme in `pub/static/frontend` is minified. Magento deploys its own Blank and Luma themes alongside yours, and minifying them is wasted work if the store does not use them. To minify only the themes you serve, name each one with `--theme=`:

```
vendor/bin/minify-m2-scripts.sh --theme=Vendor/theme
vendor/bin/minify-m2-scripts.sh --theme=Vendor/theme --theme=Vendor/other
```

The script exits with an error if a named theme has not been deployed.

### Errors
A file that terser cannot parse is left as it was. The script prints `ERROR: Failed to minify <file>`, with the reason on stderr, and continues; it still exits with 0.

If a job itself fails, for example because Node runs out of memory, the script stops handing out files, lets the other jobs finish the file each one is working on, and exits with 1. Files that were not reached by then are left unminified.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
