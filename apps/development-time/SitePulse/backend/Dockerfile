# Multi-stage build for the SitePulse Rust/Axum backend.
# Migrations and the system seed are compiled into the binary (include_str!),
# so the runtime image needs no SQL files and no secrets (pass them as env vars).

# Stage 1: build (dependencies are cached in their own layer)
FROM rust:1.99-slim-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src/bin && echo 'fn main() {}' > src/main.rs && echo 'fn main() {}' > src/bin/hash_password.rs \
    && touch src/lib.rs && cargo build --release --locked --bin sitepulse-backend || true
COPY src ./src
COPY migrations ./migrations
COPY db/seed ./db/seed
RUN touch src/main.rs src/lib.rs && cargo build --release --locked --bin sitepulse-backend

# Stage 2: minimal runtime, non-root
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home sitepulse
COPY --from=build /app/target/release/sitepulse-backend /usr/local/bin/sitepulse-backend
USER 10001
ENV APP_ENV=production
ENV SITEPULSE_BIND_ADDR=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/sitepulse-backend"]
