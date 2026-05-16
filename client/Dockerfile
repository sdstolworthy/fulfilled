# syntax=docker/dockerfile:1.7
#
# Two-stage build for the Flutter web client.
#
#   builder  — cirruslabs flutter image; runs `flutter build web --release`
#              with API_BASE_URL baked in via --dart-define.
#   runtime  — nginx:alpine serving the static bundle with SPA routing.
#
# API_BASE_URL is a build-arg because the Flutter client reads it via
# `String.fromEnvironment` (compile-time). Changing it requires a rebuild.

FROM ghcr.io/cirruslabs/flutter:stable AS builder

WORKDIR /build

# Cache pub deps separately from source. Copy manifests first.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# Now copy the rest of the source. `web/` is gitignored — `flutter create`
# regenerates it from the platform template.
COPY . .
RUN flutter create . --platforms=web

ARG API_BASE_URL=/api/v1
RUN flutter build web --release \
    --dart-define=API_BASE_URL="${API_BASE_URL}" \
    --base-href "/"

# ---------------------------------------------------------------------------

FROM nginx:1.27-alpine AS runtime

RUN rm -rf /usr/share/nginx/html/*
COPY --from=builder /build/build/web/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Tiny file the healthcheck hits; never cached, always 200.
RUN printf 'ok\n' > /usr/share/nginx/html/health.txt

EXPOSE 80

# nginx:alpine's default entrypoint runs nginx in the foreground.
