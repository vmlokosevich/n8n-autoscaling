# Multi-stage build to add tools to n8n image
# This works around apk being stripped from the official image

# Stage 1: Build dependencies in Alpine
# Keep this pinned to a known-compatible Alpine base.
FROM alpine:3.23@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11 AS builder

RUN apk add --no-cache \
    ffmpeg \
    git \
    openssh-client \
    graphicsmagick \
    jq \
    curl

# Stage 2: Copy to n8n image
# Pin digest for deterministic builds.
FROM n8nio/n8n:latest@sha256:a293b89bac876872a0c1ef0fbbb7ce056aa2d215f62917acf032ecb8010199af

USER root

# Copy binaries and libraries from builder
COPY --from=builder /usr/bin/ffmpeg /usr/bin/ffmpeg
COPY --from=builder /usr/bin/ffprobe /usr/bin/ffprobe
COPY --from=builder /usr/bin/git /usr/bin/git
COPY --from=builder /usr/bin/gm /usr/bin/gm
COPY --from=builder /usr/bin/jq /usr/bin/jq
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/lib/libav*.so* /usr/lib/
COPY --from=builder /usr/lib/libsw*.so* /usr/lib/
COPY --from=builder /usr/lib/libcurl*.so* /usr/lib/
COPY --from=builder /usr/lib/libjq*.so* /usr/lib/
COPY --from=builder /usr/lib/libonig*.so* /usr/lib/

# Expose task broker port for external runners (n8n 2.0)
EXPOSE 5679

USER node