# artcoins keeper runner. build context: the repo root (the image needs keeper/ and deployments/mainnet.json).
#   fly deploy . --config keeper/fly.toml --dockerfile keeper/Dockerfile --ignorefile keeper/.dockerignore --ha=false
#   docker build -f keeper/Dockerfile -t artcoins-keeper .        (local)
# KR-13: base pinned by digest (node:22-alpine as resolved on docker hub 2026-10-06). bump deliberately:
#   docker buildx imagetools inspect node:22-alpine   then replace the digest
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402

ENV NODE_ENV=production
WORKDIR /app/keeper

COPY keeper/package.json keeper/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

COPY keeper/*.mjs ./
COPY keeper/abi ./abi
# the registry is the address source (config.mjs reads ../deployments/mainnet.json). rebuild to pick up changes
COPY deployments/mainnet.json /app/deployments/mainnet.json

EXPOSE 8080
# the fly volume mounts root owned: hand the state dir to the unprivileged user, then drop to it. KR-10: a missing
# state dir means the volume is not mounted; refuse to start (empty state would re run every keeper and forget the
# tx in flight) unless EPHEMERAL_STATE=1. the image has no /data of its own
CMD ["sh", "-c", "d=$(dirname \"${STATE_PATH:-/data/state.json}\") && if [ ! -d \"$d\" ]; then if [ \"$EPHEMERAL_STATE\" = 1 ]; then install -d \"$d\"; else echo \"state dir $d missing (volume not mounted). set EPHEMERAL_STATE=1 to run without one\" >&2; exit 1; fi; fi && chown node:node \"$d\" && exec su -s /bin/sh node -c 'exec node /app/keeper/index.mjs'"]
