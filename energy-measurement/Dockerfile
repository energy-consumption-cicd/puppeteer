# syntax=docker/dockerfile:1

# Everything the chrome-tests job downloads ready-made is baked at image build
# time so the measured stages can run with --network none: the npm tree, the
# Chrome for Testing archives and the wireit build cache the job restores from
# the Actions cache. Nothing is compiled from source here that the job compiles
# from a cache miss; the measured build stage does that.
FROM ubuntu@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

# .nvmrc at the reference commit, installed by actions/setup-node on the runner.
ARG NODE_VERSION=24.15.0
ARG NODE_SHA256=472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6
# packages/puppeteer-core/src/revisions.ts at the reference commit. The bucket
# publishes crc32c and md5 only; the sha256 values were computed at bake time.
ARG CHROME_VERSION=153.0.8010.36
ARG CHROME_SHA256=167a098c4fdec156b58a9f678c90a84f9072d789f9c6e7b35496a6987b8b7ef8
ARG CHROME_HEADLESS_SHELL_SHA256=a0079df5617da34bcd1debad18196568b072ec3d8ec57944008972a4fc970580
ARG CFT_BASE=https://storage.googleapis.com/chrome-for-testing-public

ENV DEBIAN_FRONTEND=noninteractive

# xvfb and dbus ship with the hosted runner image; the libraries are the
# deb.deps list inside the Chrome archive, under their noble package names.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils unzip git python3 \
      xvfb xauth dbus dbus-x11 \
      fonts-liberation libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 \
      libatspi2.0-0t64 libcairo2 libcups2t64 libcurl4t64 libdbus-1-3 libexpat1 \
      libgbm1 libglib2.0-0t64 libgtk-3-0t64 libnspr4 libnss3 libpango-1.0-0 \
      libudev1 libvulkan1 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 \
      libxfixes3 libxkbcommon0 libxrandr2 wget xdg-utils; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  node-v${NODE_VERSION}-linux-x64.tar.xz" | sha256sum -c -; \
    tar -xJf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    node --version; npm --version

# uid 1000 matches the bench user, so the timing volume run_pipeline.sh mounts is
# writable from inside the container; the base image already holds that uid.
RUN userdel -r ubuntu && useradd -m -u 1000 runner

RUN mkdir -p /opt/browsers /opt/resolved-tree \
    && chown runner:runner /opt/browsers /opt/resolved-tree

COPY --chown=runner:runner . /workspace
WORKDIR /workspace
USER runner

# The Actions runner defines CI for every step; .mocharc.cjs reads it for
# retries, reporter and exit. WIREIT_CACHE=local keeps wireit on its on-disk
# cache, the only one available without the google/wireit action.
ENV CI=true
ENV WIREIT_CACHE=local

# ci.yml:122-125
RUN PUPPETEER_SKIP_DOWNLOAD=true npm ci

# The check-changes job (changed-packages.yml:45-46) builds every package on
# each push, and the chrome-tests job restores that state from the wireit
# Actions cache. Priming the local cache here is what makes the test stage a
# cache hit, as on the runner.
RUN npm run build

# ci.yml:128-129, the cell's own build step; a cache hit after the line above.
RUN npm run build --workspace @puppeteer-test/test

# Chrome for Testing, unpacked into the layout @puppeteer/browsers expects so
# the postinstall below finds it installed. The archive checksums are kept in
# the image because the bucket publishes none.
RUN set -eux; \
    cache="/home/runner/.cache/puppeteer"; \
    mkdir -p "$cache/chrome/linux-${CHROME_VERSION}" \
             "$cache/chrome-headless-shell/linux-${CHROME_VERSION}" /tmp/cft; \
    curl -fsSL -o /tmp/cft/chrome-linux64.zip \
      "${CFT_BASE}/${CHROME_VERSION}/linux64/chrome-linux64.zip"; \
    curl -fsSL -o /tmp/cft/chrome-headless-shell-linux64.zip \
      "${CFT_BASE}/${CHROME_VERSION}/linux64/chrome-headless-shell-linux64.zip"; \
    ( cd /tmp/cft && sha256sum chrome-linux64.zip chrome-headless-shell-linux64.zip \
        | tee /opt/browsers/SHA256SUMS ); \
    echo "${CHROME_SHA256}  /tmp/cft/chrome-linux64.zip" | sha256sum -c -; \
    echo "${CHROME_HEADLESS_SHELL_SHA256}  /tmp/cft/chrome-headless-shell-linux64.zip" | sha256sum -c -; \
    unzip -q /tmp/cft/chrome-linux64.zip -d "$cache/chrome/linux-${CHROME_VERSION}"; \
    unzip -q /tmp/cft/chrome-headless-shell-linux64.zip -d "$cache/chrome-headless-shell/linux-${CHROME_VERSION}"; \
    rm -rf /tmp/cft; \
    test -x "$cache/chrome/linux-${CHROME_VERSION}/chrome-linux64/chrome"; \
    test -x "$cache/chrome-headless-shell/linux-${CHROME_VERSION}/chrome-headless-shell-linux64/chrome-headless-shell"

# ci.yml:135-136. puppeteer.config.js also requests Firefox, which the cell
# never launches; it is the only download skipped.
RUN PUPPETEER_SKIP_FIREFOX_DOWNLOAD=true npm run postinstall

# The job runs Chrome with its sandbox on, after lifting the AppArmor
# restriction on unprivileged user namespaces with sudo (ci.yml:119-121), which
# a container cannot do. Where the restriction is in force Chrome falls back to
# its setuid helper, shipped in the archive; where it is not, it keeps using the
# namespace sandbox. --no-sandbox is never used.
USER root
RUN cp "/home/runner/.cache/puppeteer/chrome/linux-${CHROME_VERSION}/chrome-linux64/chrome_sandbox"        /usr/local/sbin/chrome-devel-sandbox     && chown root:root /usr/local/sbin/chrome-devel-sandbox     && chmod 4755 /usr/local/sbin/chrome-devel-sandbox
ENV CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox
USER runner

RUN xvfb-run --auto-servernum "/home/runner/.cache/puppeteer/chrome/linux-${CHROME_VERSION}/chrome-linux64/chrome" --version

# The resolved tree, archived and published with the results.
RUN <<'SH'
set -eux
npm ls --all --json > /opt/resolved-tree/npm-ls-all.json 2>/dev/null || true
python3 - <<'PYEOF' > /opt/resolved-tree/node_modules_manifest.tsv
import json, os
root = "/workspace/node_modules"
rows = []
for dirpath, _, filenames in os.walk(root):
    if "package.json" not in filenames:
        continue
    try:
        d = json.load(open(os.path.join(dirpath, "package.json")))
    except Exception:
        continue
    if isinstance(d, dict) and d.get("name") and d.get("version"):
        rows.append("\t".join([os.path.relpath(dirpath, root), d["name"], d["version"]]))
rows.sort()
print("\n".join(rows))
PYEOF
{ node --version; npm --version; node -p 'require("wireit/package.json").version'; node -p 'require("mocha/package.json").version'; } > /opt/resolved-tree/tool_versions.txt
cd /opt/resolved-tree
sha256sum ./* > SHA256SUMS
cat SHA256SUMS
SH
