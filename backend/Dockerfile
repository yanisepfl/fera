# syntax=docker/dockerfile:1
# FERA backend image — indexer (Ponder) + API (Hono/node:http) + keepers + emissions pipeline.
# The backend is run DIRECTLY as TypeScript via tsx/ponder (no compile step; "type":"module",
# Node >=20), so the image must include devDependencies (tsx/typescript live there). One image,
# many roles: the default command runs the indexer; the deploy overrides `command` per role.
#
#   indexer   : (default)                 npm run start          # ponder start
#   api       : command ["npm","run","api:dev"]                  # :42070
#   keepers   : command ["npm","run","keeper:root-poster"] | keeper:market-hours | keeper:oracle-monitor | ...
#   pipeline  : command ["npm","run","pipeline:dryrun"]
FROM node:20-slim

# npm hygiene; do NOT set NODE_ENV=production before install — tsx/typescript are devDependencies
# the runtime needs (the backend executes .ts directly). NODE_ENV is set for runtime just below.
ENV NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_AUDIT=false \
    CI=true

WORKDIR /app
RUN chown node:node /app
USER node

# Install deps against the committed lockfile (reproducible). Cached layer unless deps change.
COPY --chown=node:node package.json package-lock.json ./
RUN npm ci

# App source (node_modules/.git/etc. excluded by .dockerignore).
COPY --chown=node:node . .

ENV NODE_ENV=production
# Ponder serve (42069) + the standalone market-data API (42070). Deploy maps what each role needs.
EXPOSE 42069 42070

CMD ["npm", "run", "start"]
