# Stage 1: Build Flutter web
FROM ghcr.io/cirruslabs/flutter:3.35.6 AS build
# CirrusLabs images are multi-arch; 3.35.x bundles Dart 3.9.x
WORKDIR /app

# Enable web
RUN flutter config --enable-web
# Print versions for sanity
RUN flutter --version && dart --version && flutter doctor -v

# Cache dependencies
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# Copy source and build
COPY . .
# Build web release (no signaling arg)
RUN flutter build web --release -v

# Stage 2: Serve with Nginx
FROM nginx:alpine
RUN apk add --no-cache curl
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built site
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 80

# Healthcheck (optional)
HEALTHCHECK --interval=30s --timeout=3s CMD curl -fsS http://localhost/ || exit 1