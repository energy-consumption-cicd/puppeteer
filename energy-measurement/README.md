# Energy measurement

Instrumentation for measuring the energy consumed by this project's CI cell at
release `puppeteer-v24.37.0`. Branch `release-24.37.0` is the tag commit
`5dc0f3c7e67da8d4f965795dd2bd64396e00d6fd` plus one commit adding these five files; it
modifies none of the upstream tree (`git diff puppeteer-v24.37.0 release-24.37.0` shows only
them). Only what the tag requires differs from the project's current pipeline
(versions, archives, ceilings).

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
(`ci.yml:154-229`): suite `chrome-headless`, `runs-on: ubuntu-latest`, whose two
shards (`1-2`, `2-2`) run here in sequence. The other four Chrome suites, the
Windows and macOS entries, `firefox-tests`, `unit-tests`, `installation-test`,
`docker-tests`, `ng-schematics-*`, `browsers-tests`, `inspect-code` and the
other 13 workflows are outside the cell.

## Stages

| stage | commands | source |
|---|---|---|
| `build` | `npm run build --workspace @puppeteer-test/test` | `ci.yml:206-207` |
| `test` | `xvfb-run --auto-servernum npm run test -- --shard '1-2' --test-suite chrome-headless --save-stats-to /tmp/artifacts/push_INSERTID.json`, then `--shard '2-2'` | `ci.yml:222-223` |

Every command in `commands.sh` is literal. The differences against the job, and
no others:

| # | difference | why |
|---|---|---|
| D-1 | `ubuntu:24.04` by digest under `docker run`, user `runner` (uid 1000), workspace at `/workspace` | dedicated bench; the hosted runner image is `ubuntu-24.04` |
| D-2 | one `--rm` container per stage. The build stage runs on a per-run volume where a setup container, outside the measured window, has run `npm run clean` and removed every `.wireit` directory; the test stage runs from the untouched image, which holds the build output and a primed wireit cache | the job restores the wireit cache from the Actions cache (`google/wireit`), so its build step is a cache hit and its test step compiles nothing; the measured build reproduces the cache miss, the measured test the cache hit |
| D-3 | `npm ci` (`ci.yml:200-203`), the full `npm run build` of the `check-changes` job (`changed-packages.yml:42-43`) and `npm run postinstall` (`ci.yml:213-214`) run at image build; the stages run with `--network none` | the hosted runner downloads the npm tree, the browsers and the build cache ready-made |
| D-4 | Node 22.22.0 (latest 22.x on the date of the tag's CI run) sha256-verified; Chrome for Testing 145.0.7632.26 (`packages/puppeteer-core/src/revisions.ts`) unpacked from the two archives of the `chrome-for-testing-public` bucket, whose sha256 is computed at bake and kept at `/opt/browsers/SHA256SUMS` | the bucket publishes crc32c and md5 only, and the postinstall verifies no checksum |
| D-5 | Firefox `stable_147.0.2`, which `puppeteer.config.cjs` also requests, is not downloaded (`PUPPETEER_SKIP_FIREFOX_DOWNLOAD=true` on the postinstall step) | the cell never launches Firefox |
| D-6 | Chrome's setuid sandbox helper, shipped in the archive as `chrome_sandbox`, is installed root-owned with mode 4755 and named by `CHROME_DEVEL_SANDBOX` | the job lifts the AppArmor restriction on unprivileged user namespaces with `sudo` on the host (`ci.yml:197-199`), which a container cannot do; where the restriction is in force Chrome uses this helper, where it is not it keeps the namespace sandbox. `--no-sandbox` is never used |
| D-7 | the two shards run in sequence in one container | reproducing the concurrency would need two instrumented benches; two containers on one bench would contaminate the RAPL reading, which is per package |
| D-8 | `CI=true` and `WIREIT_CACHE=local` in the image environment | the Actions runner defines `CI` for every step (`.mocharc.cjs` reads it for `retries: 3`, `reporter: spec` and `exit`); the local cache is the only wireit cache available without the `google/wireit` action |

`xvfb-run` is part of the literal command and stays inside the measured test
stage; the suite launches real windows in `test/src/cdp/devtools.test.ts`.

## Browser archives

| archive | sha256 |
|---|---|
| `145.0.7632.26/linux64/chrome-linux64.zip` | `322676e3f8534da3644470b710506b653e1aa034e42da32c9aaf70d810d11ec2` |
| `145.0.7632.26/linux64/chrome-headless-shell-linux64.zip` | `1559bef17d0a65506401986dd24daaf6c737e76eea9ab3947f63114ba66300e3` |

## Running

```
docker build -t puppeteer-measurement-24.37.0 -f energy-measurement/Dockerfile .
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
`--network none` and in this container, nine tests fail that pass on the
hosted runner, identically in both rehearsal runs on the bench:
`[oopif.spec] OOPIF should support lazy OOP frames`,
`[proxy.spec] request proxy should proxy requests when configured`, `[proxy.spec] request proxy should respect proxy bypass list`,
`[proxy.spec] request proxy in incognito browser context should proxy requests when configured at browser level`,
`[proxy.spec] request proxy in incognito browser context should respect proxy bypass list when configured at browser level`,
`[proxy.spec] request proxy in incognito browser context should respect proxy bypass list when configured at context level`,
`[page.spec] Page Page.Events.Console should have location when fetch fails`,
`[page.spec] Page Page.setOfflineMode should emulate navigator.onLine` and
`[launcher.spec] Launcher specs Puppeteer Puppeteer.executablePath returns executablePath for channel`.
Shard `1-2` ends with `Run failed: 6
unexpected result(s)` and shard `2-2` with `3`. The expected aggregate
exit is 0 for `build` and 1 for `test`; the full failure list per shard is in the
stage log as a diagnostic series.

## Network

Both stages run under `--network none`. The test server binds loopback
(`packages/testserver/src/index.ts`) and the `.test` domains are mapped to
127.0.0.1 by `--host-resolver-rules` (`test/src/mocha-utils.ts`). No mitigation
is applied to the tests above.

## Sidecars

Besides the CSV and the exit-code sidecar, each stage writes
`swap_run_NN_<stage>.txt` (host `pswpin`/`pswpout` from `/proc/vmstat`) and
`temp_run_NN_<stage>.txt` (package temperature from the `coretemp` hwmon sensor
labelled `Package id 0`), both read on the host immediately before and after the
RAPL window, never inside it. The 14 CSV columns are unchanged.
