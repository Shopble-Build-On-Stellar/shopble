# syntax=docker/dockerfile:1

# ---------- builder ----------
# Pinned to an exact patch, not a floating major: the build must be reproducible and the
# version is what carries the security fixes. node 26 ships npm 11, which the committed
# package-lock.json (lockfileVersion 3) needs — npm 10 rejects it as out of sync.
FROM node:26.12.1-alpine AS builder

# Node exists only in this stage, so the nginx runtime cannot be asked what built the
# bundle. Record it here and carry it over — see the COPY in the runtime stage.
RUN node -v > /node-version

WORKDIR /src

# Lockfile before source: this layer only rebuilds when dependencies change.
COPY project/shopble/web/package.json project/shopble/web/package-lock.json ./
RUN npm ci

COPY project/shopble/web/ ./

# Vite inlines env vars at BUILD time — there is no runtime config to change later, so
# these are build args and a rebuild is the only way to repoint the bundle.
#
# VITE_API_BASE defaults to empty: nginx serves the app and proxies /api on the same
# origin, so the browser needs no absolute backend URL and CORS never enters the picture.
# Leaving it unset is NOT the same thing — src/api.ts then falls back to
# http://localhost:8080, which silently points a deployed bundle at the viewer's machine.
ARG VITE_API_BASE=""
ARG VITE_HORIZON="https://horizon-testnet.stellar.org"
ENV VITE_API_BASE=$VITE_API_BASE
ENV VITE_HORIZON=$VITE_HORIZON

RUN npm run build

# ---------- runtime ----------
FROM nginx:alpine

COPY docker/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /src/dist /usr/share/nginx/html

# Deliberately NOT under /usr/share/nginx/html: the build toolchain version is an
# operational detail, not something to serve to every visitor.
#   docker exec shopble_web cat /etc/shopble-build-node
COPY --from=builder /node-version /etc/shopble-build-node

EXPOSE 80
