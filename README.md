# Magento 2 Terser

A Bash script that uses `terser` to minify your JavaScript files and can be run in the root directory of your Magento 2 installation.

The script will minify all JavaScript files in the pub/static/frontend directory of your Magento 2 installation, except for those that are already minified or the requirejs-bundle-config.js file.
The minification tasks can be run in parallel for increased performance.

## Installation

You can install the package using Composer. Run the following command in your terminal:
```bash
composer require ibertrand/magento2-terser
```
Alternatively, you can download the file `minify-m2-scripts.sh` directly and save it wherever you want.

The script requires the `terser` command to be available. If you don't have it installed, you can install it globally with `npm`:

```bash
npm install terser -g
```

If you don't have `npm` installed, you need to install it first.

## Usage

To run the script, open a terminal in the root directory of your Magento 2 installation and run:

```bash
vendor/bin/minify-m2-scripts.sh
```
This is assuming you installed the package using Composer. If you downloaded the file directly, you need to run the script with the full path to the file.

By default, the script will minify all JavaScript files in the `pub/static/frontend` directory of your Magento 2 installation, except for those that are already minified or the `requirejs-bundle-config.js` file.

The original files will be replaced with the minified versions. If your M2 instance is in developer mode, this might alter files outside of the `pub/static/frontend` directory because of symlinks.

You can run the script with the `-v` or `--verbose` flag to display the name of each file that is being minified.

### Parallel execution
The script supports parallel execution of minification tasks to speed up the process. To specify the number of jobs to run in parallel, you can use the -j option followed by the number of jobs or --jobs= followed by the number of jobs.

For example, to run 3 jobs in parallel, you could use either of the below commands:
```
vendor/bin/minify-m2-scripts.sh -j3
vendor/bin/minify-m2-scripts.sh -jobs=3
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
