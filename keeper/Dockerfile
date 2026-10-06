# artcoins keeper runner. build context: the repo root (the image needs keeper/ and deployments/mainnet.json).
#   fly deploy . --config keeper/fly.toml --dockerfile keeper/Dockerfile --ignorefile keeper/.dockerignore --ha=false
#   docker build -f keeper/Dockerfile -t artcoins-keeper .        (local)
FROM node:22-alpine

ENV NODE_ENV=production
WORKDIR /app/keeper

COPY keeper/package.json keeper/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

COPY keeper/*.mjs ./
COPY keeper/abi ./abi
# the registry is the address source (config.mjs reads ../deployments/mainnet.json). rebuild to pick up changes
COPY deployments/mainnet.json /app/deployments/mainnet.json

EXPOSE 8080
# the fly volume mounts root owned: hand the state dir to the unprivileged user, then drop to it
CMD ["sh", "-c", "d=$(dirname \"${STATE_PATH:-/data/state.json}\") && mkdir -p \"$d\" && chown node:node \"$d\" && exec su -s /bin/sh node -c 'exec node /app/keeper/index.mjs'"]
