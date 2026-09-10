# Energy measurement

Instrumentation for measuring the energy consumed by this project's CI cell. It
adds five files and modifies none of the upstream tree (`git diff` against
`puppeteer/puppeteer` at `499c713ae7256c4322dc3f760f223ead2afcb0a3` shows only
them).

```
.github/workflows/energy-measurement.yml
energy-measurement/
├── README.md
├── Dockerfile
├── run_pipeline.sh
└── commands.sh
```

## Measured cell

`.github/workflows/ci.yml` is the workflow that builds and tests on every push
to `main`. The measured cell is one entry of the `chrome-tests` matrix
(`ci.yml:76-153`): suite `chrome-headless`, `runs-on: ubuntu-latest`, whose two
shards (`1-2`, `2-2`) run here in sequence. The other four Chrome suites, the
Windows and macOS entries, `firefox-tests`, `unit-tests`, `installation-test`,
`docker-tests`, `ng-schematics-*`, `browsers-tests`, `inspect-code` and the
other 13 workflows are outside the cell.

## Stages

| stage | commands | source |
|---|---|---|
| `build` | `npm run build --workspace @puppeteer-test/test` | `ci.yml:128-129` |
| `test` | `xvfb-run --auto-servernum npm run test -- --shard '1-2' --test-suite chrome-headless --save-stats-to /tmp/artifacts/push_INSERTID.json`, then `--shard '2-2'` | `ci.yml:143-145` |

Every command in `commands.sh` is literal. The differences against the job, and
no others:

| # | difference | why |
|---|---|---|
| D-1 | `ubuntu:24.04` by digest under `docker run`, user `runner` (uid 1000), workspace at `/workspace` | dedicated bench; the hosted runner image is `ubuntu-24.04` |
| D-2 | one `--rm` container per stage. The build stage runs on a per-run volume where a setup container, outside the measured window, has run `npm run clean` and removed every `.wireit` directory; the test stage runs from the untouched image, which holds the build output and a primed wireit cache | the job restores the wireit cache from the Actions cache (`google/wireit`), so its build step is a cache hit and its test step compiles nothing; the measured build reproduces the cache miss, the measured test the cache hit |
| D-3 | `npm ci` (`ci.yml:122-125`), the full `npm run build` of the `check-changes` job (`changed-packages.yml:45-46`) and `npm run postinstall` (`ci.yml:135-136`) run at image build; the stages run with `--network none` | the hosted runner downloads the npm tree, the browsers and the build cache ready-made |
| D-4 | Node 24.15.0 (`.nvmrc`) sha256-verified; Chrome for Testing 153.0.8010.36 (`packages/puppeteer-core/src/revisions.ts`) unpacked from the two archives of the `chrome-for-testing-public` bucket, whose sha256 is computed at bake and kept at `/opt/browsers/SHA256SUMS` | the bucket publishes crc32c and md5 only, and the postinstall verifies no checksum |
| D-5 | Firefox `stable_155.0.1`, which `puppeteer.config.js` also requests, is not downloaded (`PUPPETEER_SKIP_FIREFOX_DOWNLOAD=true` on the postinstall step) | the cell never launches Firefox |
| D-6 | Chrome's setuid sandbox helper, shipped in the archive as `chrome_sandbox`, is installed root-owned with mode 4755 and named by `CHROME_DEVEL_SANDBOX` | the job lifts the AppArmor restriction on unprivileged user namespaces with `sudo` on the host (`ci.yml:119-121`), which a container cannot do; where the restriction is in force Chrome uses this helper, where it is not it keeps the namespace sandbox. `--no-sandbox` is never used |
| D-7 | the two shards run in sequence in one container | reproducing the concurrency would need two instrumented benches; two containers on one bench would contaminate the RAPL reading, which is per package |
| D-8 | `CI=true` and `WIREIT_CACHE=local` in the image environment | the Actions runner defines `CI` for every step (`.mocharc.cjs` reads it for `retries: 3`, `reporter: spec` and `exit`); the local cache is the only wireit cache available without the `google/wireit` action |

`xvfb-run` is part of the literal command and stays inside the measured test
stage; the suite launches real windows in `test/src/cdp/devtools.test.ts`.

## Browser archives

| archive | sha256 |
|---|---|
| `153.0.8010.36/linux64/chrome-linux64.zip` | `167a098c4fdec156b58a9f678c90a84f9072d789f9c6e7b35496a6987b8b7ef8` |
| `153.0.8010.36/linux64/chrome-headless-shell-linux64.zip` | `a0079df5617da34bcd1debad18196568b072ec3d8ec57944008972a4fc970580` |

## Running

```
docker build -t puppeteer-medicao -f energy-measurement/Dockerfile .
gh workflow run energy-measurement.yml -f campaign=validation
gh workflow run energy-measurement.yml -f campaign=full
```

`validation` runs run 0 only. `full` runs a discarded warm-up plus runs 1..10 and
writes the medians. Each run rests 120 s to measure the idle baseline; an idle
package rate above 1.0 W aborts the run before any stage (exit 90), since the
bench is then not idle. A stage that exceeds its ceiling is killed (exit 91) and
the run is substituted, at most twice per campaign.

## Exit codes

The test runner (`tools/mocha-runner`) judges each shard against
`test/TestExpectations.json` and exits 1 only on a result it did not expect, so
the failures the upstream expects do not change its exit code. Under
`--network none` seven tests fail that pass with a network interface: one in
`console.test.ts` (`fetch('http://wat')` reports `ERR_INTERNET_DISCONNECTED`
instead of `ERR_NAME_NOT_RESOLVED`), five in `proxy.test.ts` (the container
hostname `proxy.test.ts:17-33` relies on does not resolve without an interface)
and `Page.setOfflineMode should emulate navigator.onLine` in `page.test.ts`. The
pre-registered aggregate exit is 0 for `build` and 1 for `test`; the full failure
list per shard is in the stage log as a diagnostic series.

## Network

Both stages run under `--network none`. The test server binds loopback
(`packages/testserver/src/index.ts`) and the `.test` domains are mapped to
127.0.0.1 by `--host-resolver-rules` (`test/src/mocha-utils.ts`). No mitigation
is applied to the seven tests above.
