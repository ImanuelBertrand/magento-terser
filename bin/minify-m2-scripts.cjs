#!/usr/bin/env node
'use strict';

// Minifies the files named on stdin (NUL-separated) in place, using terser's API in a pool of
// worker threads. Started by minify-m2-scripts.sh, which finds the files and parses the options.
//
// Loading terser takes longer than minifying a typical Magento file, so starting the terser
// command once per file spent most of the run starting Node. Each worker here loads terser once.

const fs = require('fs');
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');

// The same options `terser -c -m reserved=[...]` passes to minify(). The CLI also sets
// rename: false whenever --rename is not given.
const MINIFY_OPTIONS = {
    compress: true,
    mangle: { reserved: ['$', 'jQuery', 'define', 'require', 'exports'] },
    rename: false,
};

if (isMainThread) {
    main();
} else {
    work();
}

function main() {
    const options = { terser: null, jobs: 1, verbose: false, progressBar: true };
    for (const arg of process.argv.slice(2)) {
        const [name, value] = arg.split(/=(.*)/s);
        if (name === '--terser') options.terser = value;
        else if (name === '--jobs') options.jobs = Math.max(1, parseInt(value, 10) || 1);
        else if (name === '--verbose') options.verbose = true;
        else if (name === '--no-progress-bar') options.progressBar = false;
    }
    if (!options.terser) {
        console.error('ERROR: --terser=<path to the terser package> is required.');
        process.exit(1);
    }

    const files = fs.readFileSync(0).toString().split('\0').filter(Boolean);
    const numFiles = files.length;
    let next = 0;
    let processed = 0;
    let failed = false;

    const progress = () => {
        if (!options.progressBar) return;
        const length = Math.floor(processed * 50 / numFiles);
        process.stdout.write(`\r[${'='.repeat(length)}${' '.repeat(50 - length)}] ${processed}/${numFiles}`);
    };

    // After a failure, no worker gets another file. Each one finishes the file it has instead of
    // being killed in the middle of writing it back.
    const dispatch = (worker) => {
        if (failed || next >= numFiles) {
            worker.finished = true;
            worker.postMessage(null);
            return;
        }
        const file = files[next++];
        if (options.verbose) process.stdout.write(`\rMinifying ${file}\n`);
        worker.postMessage(file);
    };

    for (let i = 0; i < Math.min(options.jobs, numFiles); i++) {
        const worker = new Worker(__filename, { workerData: { terser: options.terser } });
        worker.on('message', ({ file, error }) => {
            if (error) {
                process.stderr.write(`${error}\n`);
                process.stdout.write(`\rERROR: Failed to minify ${file}\n`);
            }
            processed++;
            progress();
            dispatch(worker);
        });
        // A worker that dies takes the file it was given with it, so this is a failure of the
        // run, not of one file.
        worker.on('error', (error) => {
            console.error(`ERROR: A minification worker failed: ${error.stack || error}`);
            worker.crashed = true;
            failed = true;
            process.exitCode = 1;
        });
        worker.on('exit', (code) => {
            if (worker.finished || worker.crashed) return;
            console.error(`ERROR: A minification worker exited with code ${code} before it had finished.`);
            failed = true;
            process.exitCode = 1;
        });
        dispatch(worker);
    }
}

function work() {
    const { minify } = require(workerData.terser);
    parentPort.on('message', async (file) => {
        if (file === null) {
            parentPort.close();
            return;
        }
        try {
            const code = fs.readFileSync(file, 'utf8');
            const result = await minify({ [file]: code }, MINIFY_OPTIONS);
            // terser before 5 returns its errors instead of throwing them.
            if (result.error) throw result.error;
            fs.writeFileSync(file, result.code);
            parentPort.postMessage({ file });
        } catch (error) {
            const where = error.line ? ` at ${file}:${error.line},${error.col}` : '';
            parentPort.postMessage({ file, error: `${error.name || 'Error'}${where}: ${error.message}` });
        }
    });
}
