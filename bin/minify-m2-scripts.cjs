#!/usr/bin/env node
'use strict';

// Minifies the files named on stdin (NUL-separated) in place, using terser's API in a pool of
// worker threads. Started by minify-m2-scripts.sh, which finds the files and parses the options.
//
// Loading terser takes longer than minifying a typical Magento file, so starting the terser
// command once per file spent most of the run starting Node. Each worker here loads terser once.
//
// Rewriting a deployed file invalidates the Subresource Integrity hash Magento recorded for it, and
// current Magento and Mage-OS releases put those hashes on the checkout's script tags: a stale
// one makes the browser refuse require.js there, and only there. So once every worker is done, the
// hash of each rewritten file is updated in the sri-hashes.json that lists it.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
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
    const options = { terser: null, staticRoot: null, jobs: 1, verbose: false, progressBar: true, silent: false };
    for (const arg of process.argv.slice(2)) {
        const [name, value] = arg.split(/=(.*)/s);
        if (name === '--terser') options.terser = value;
        else if (name === '--static-root') options.staticRoot = value;
        else if (name === '--jobs') options.jobs = Math.max(1, parseInt(value, 10) || 1);
        else if (name === '--verbose') options.verbose = true;
        else if (name === '--no-progress-bar') options.progressBar = false;
        else if (name === '--silent') options.silent = true;
    }
    if (!options.terser || !options.staticRoot) {
        console.error('ERROR: --terser=<path to the terser package> and --static-root=<pub/static> are required.');
        process.exit(1);
    }

    const files = fs.readFileSync(0).toString().split('\0').filter(Boolean);
    const numFiles = files.length;
    let next = 0;
    let processed = 0;
    let failed = false;
    // file => its new SRI hash, for every file that was rewritten. A file terser could not parse
    // is left as it was, and so is its hash.
    const rewritten = new Map();

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

    // Runs after a failed run too: whatever was rewritten by then has to match its hash.
    const numWorkers = Math.min(options.jobs, numFiles);
    let exited = 0;
    const finish = () => updateSriHashes(options.staticRoot, rewritten, options.silent);
    if (numWorkers === 0) finish();

    for (let i = 0; i < numWorkers; i++) {
        const worker = new Worker(__filename, { workerData: { terser: options.terser } });
        worker.on('message', ({ file, hash, error }) => {
            if (error) {
                process.stderr.write(`${error}\n`);
                process.stdout.write(`\rERROR: Failed to minify ${file}\n`);
            } else {
                rewritten.set(file, hash);
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
            if (++exited === numWorkers) finish();
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
            const minified = Buffer.from(result.code, 'utf8');
            fs.writeFileSync(file, minified);
            parentPort.postMessage({ file, hash: sriHash(minified) });
        } catch (error) {
            const where = error.line ? ` at ${file}:${error.line},${error.col}` : '';
            parentPort.postMessage({ file, error: `${error.name || 'Error'}${where}: ${error.message}` });
        }
    });
}

// The format of Magento's HashGenerator: the algorithm, a dash, the base64 of the raw digest.
function sriHash(content) {
    return `sha256-${crypto.createHash('sha256').update(content).digest('base64')}`;
}

// Magento 2.4.7-p8 to 2.4.8-p5 keep one sri-hashes.json per area, pub/static/<area>/; Magento 2.4.9
// and Mage-OS keep one per package, pub/static/<area>/<Vendor>/<theme>/<locale>/. Both key each file by its path
// relative to pub/static, so whichever of the two exist are updated. Only entries for rewritten
// files are touched; a rewritten file a hash file does not list was never hashed, and is left so.
//
// Anything that does not look like that format is an error, not a skip: carrying on would leave
// stale hashes in place, which is exactly the broken checkout this is here to prevent. Finding no
// hash file at all is fine — there is nothing to update, and the run says so once.
function updateSriHashes(staticRoot, rewritten, silent) {
    const contexts = new Map();
    for (const [file, hash] of rewritten) {
        const key = path.relative(staticRoot, file).split(path.sep).join('/');
        const parts = key.split('/');
        for (const context of [parts[0], parts.slice(0, 4).join('/')]) {
            if (!contexts.has(context)) contexts.set(context, new Map());
            contexts.get(context).set(key, hash);
        }
    }

    let hashFiles = 0;
    let failures = 0;
    let updated = 0;
    for (const [context, hashes] of contexts) {
        const hashFile = path.join(staticRoot, context, 'sri-hashes.json');
        if (!fs.existsSync(hashFile)) continue;
        hashFiles++;
        try {
            const stored = JSON.parse(fs.readFileSync(hashFile, 'utf8'));
            if (stored === null || typeof stored !== 'object' || Array.isArray(stored)) {
                throw new Error('it is not a JSON object');
            }
            let changed = false;
            let listed = 0;
            for (const [key, hash] of hashes) {
                if (!(key in stored)) continue;
                listed++;
                if (typeof stored[key] !== 'string' || !stored[key].startsWith('sha256-')) {
                    throw new Error(`the entry for ${key} is not a sha256 hash`);
                }
                if (stored[key] !== hash) {
                    stored[key] = hash;
                    changed = true;
                    updated++;
                }
            }
            // Magento hashes every script it deploys, so a file that lists none of the rewritten
            // ones keys its entries some other way now.
            if (!listed) throw new Error('it lists none of the rewritten files');
            if (changed) fs.writeFileSync(hashFile, JSON.stringify(stored));
        } catch (error) {
            console.error(`ERROR: Could not update the SRI hashes in ${hashFile}: ${error.message}`);
            console.error('The checkout may refuse the minified scripts listed there.');
            failures++;
            process.exitCode = 1;
        }
    }

    if (silent) return;
    if (rewritten.size && !hashFiles) {
        process.stdout.write('\nNo sri-hashes.json found, so no SRI hashes were updated.\n');
    } else if (hashFiles > failures) {
        process.stdout.write(`\nUpdated ${updated} SRI hashes in ${hashFiles - failures} sri-hashes.json files.\n`);
    }
}
