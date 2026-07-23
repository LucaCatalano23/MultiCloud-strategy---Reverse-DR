# syntax=docker/dockerfile:1.7
FROM node:22-alpine AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund

COPY index.html tsconfig.json tsconfig.app.json tsconfig.node.json vite.config.ts ./
COPY public ./public
COPY src ./src
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

USER root
RUN rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /usr/share/nginx/html/config /opt/helios \
    && chown -R 101:101 /usr/share/nginx/html /opt/helios

COPY --from=build --chown=101:101 /app/dist /usr/share/nginx/html
COPY --chown=101:101 deploy/default.conf.template /etc/nginx/templates/default.conf.template
COPY --chown=101:101 deploy/runtime-config.json.template /opt/helios/runtime-config.json.template
COPY deploy/40-runtime-config.sh /docker-entrypoint.d/40-runtime-config.sh
RUN chmod 0755 /docker-entrypoint.d/40-runtime-config.sh

ENV HELIOS_API_UPSTREAM=http://helios-bff.helios-desk.svc.cluster.local:8000 \
    HELIOS_API_BASE_PATH=/api/v1 \
    HELIOS_DEMO_MODE=false \
    HELIOS_CSRF_COOKIE_NAME=__Host-helios_csrf \
    HELIOS_CSRF_HEADER_NAME=X-CSRF-Token \
    NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1

USER 101
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O - http://127.0.0.1:8080/healthz || exit 1
