# syntax=docker/dockerfile:1

# ---- build stage: install all deps and compile TypeScript ----
FROM node:20-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Prune to production dependencies for the runtime image.
RUN npm prune --omit=dev

# ---- runtime stage: minimal image, non-root, no dev deps ----
FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production

# Compiled output and production node_modules from the build stage.
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./

# Per-environment allowlists live at the package root, next to dist/,
# where resolveAllowlistPath() looks for allowlist.<env>.yaml.
COPY allowlist.dev.yaml allowlist.prod.yaml ./

# Runs as the unprivileged `node` user shipped in the base image.
USER node

# Listens on 0.0.0.0:8080 inside the container. This port is NOT
# published to the host; the service is reachable only on the private
# gateway Docker network, called by the nginx container (see #4).
ENV HOST=0.0.0.0 \
    PORT=8080 \
    FOUNTEL_ENV=dev
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/index.js"]
