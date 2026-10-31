# First stage. Building a binary
# -----------------------------------------------------------------------------
ARG USE_NVIDIA

FROM golang:1.27.3-trixie AS builder

WORKDIR /app

# Copy go mod files first for better caching
COPY go.mod go.sum ./
RUN go mod download

# Copy the source code
COPY . .

# Build the application with optimizations
RUN CGO_ENABLED=0 go build -mod=mod -ldflags="-s -w" -trimpath -o threadfin threadfin.go

# Second stage. Creating a minimal image
# -----------------------------------------------------------------------------
ARG USE_NVIDIA
FROM ubuntu:24.04 AS standard
FROM nvidia/cuda:12.8.0-base-ubuntu24.04 AS nvidia
FROM standard AS final
FROM nvidia AS final-nvidia

ARG USE_NVIDIA
FROM final${USE_NVIDIA:+-nvidia}

ARG BUILD_DATE
ARG VCS_REF
ARG THREADFIN_PORT=34400
ARG THREADFIN_VERSION

LABEL org.label-schema.build-date="${BUILD_DATE}" \
      org.label-schema.name="Threadfin" \
      org.label-schema.description="Dockerized Threadfin" \
      org.label-schema.url="https://hub.docker.com/r/fyb3roptik/threadfin/" \
      org.label-schema.vcs-ref="${VCS_REF}" \
      org.label-schema.vcs-url="https://github.com/Threadfin/Threadfin" \
      org.label-schema.vendor="Threadfin" \
      org.label-schema.version="${THREADFIN_VERSION}" \
      org.label-schema.schema-version="1.0" \
      DISCORD_URL="https://discord.gg/bEPPNP2VG8"

ENV THREADFIN_BIN=/home/threadfin/bin \
    THREADFIN_CONF=/home/threadfin/conf \
    THREADFIN_HOME=/home/threadfin \
    THREADFIN_TEMP=/tmp/threadfin \
    THREADFIN_CACHE=/home/threadfin/cache \
    THREADFIN_UID=31337 \
    THREADFIN_GID=31337 \
    THREADFIN_USER=threadfin \
    THREADFIN_BRANCH=main \
    THREADFIN_DEBUG=0 \
    THREADFIN_PORT=34400 \
    THREADFIN_LOG=/var/log/threadfin.log \
    THREADFIN_BIND_IP_ADDRESS=0.0.0.0 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/threadfin/bin \
    DEBIAN_FRONTEND=noninteractive

# Set working directory
WORKDIR $THREADFIN_HOME

ARG TARGETARCH
# Fork patch: FFmpeg branch to fetch from BtbN static builds (see RUN below)
ARG FFMPEG_BRANCH=8.1

# Install dependencies in a single layer
# Fork patch (Jonathall): FFmpeg comes from the BtbN static build of the
# pinned branch below instead of Ubuntu noble's ffmpeg (6.1.1) and
# jellyfin-ffmpeg7 (7.1.x). Both shipped versions are below the fixed
# thresholds for PixelSmash CVE-2026-8461 (6.1.6 / 7.1.5 / 8.1.2).
# Symlinks keep the legacy paths (/usr/bin/ffmpeg,
# /usr/lib/jellyfin-ffmpeg/ffmpeg) resolving to the patched binary.
# TARGETARCH is provided by BuildKit; classic builders leave it empty,
# so fall back to the architecture of the image being built.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    vlc \
    tzdata \
    xz-utils && \
    mkdir -p $THREADFIN_BIN $THREADFIN_CONF $THREADFIN_TEMP $THREADFIN_HOME/cache && \
    chmod a+rwX $THREADFIN_CONF $THREADFIN_TEMP && \
    sed -i 's/geteuid/getppid/' /usr/bin/vlc && \
    BUILD_ARCH="${TARGETARCH:-$(dpkg --print-architecture)}" && \
    case "${BUILD_ARCH}" in \
        amd64) BTBN_ARCH="linux64" ;; \
        arm64) BTBN_ARCH="linuxarm64" ;; \
        *) echo "No BtbN build for architecture=${BUILD_ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/ffmpeg-btbn.tar.xz \
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n${FFMPEG_BRANCH}-latest-${BTBN_ARCH}-gpl-${FFMPEG_BRANCH}.tar.xz" && \
    mkdir -p /tmp/btbn && \
    tar -xJf /tmp/ffmpeg-btbn.tar.xz -C /tmp/btbn --strip-components=1 && \
    install -m 0755 /tmp/btbn/bin/ffmpeg /tmp/btbn/bin/ffprobe /usr/local/bin/ && \
    mkdir -p /usr/lib/jellyfin-ffmpeg && \
    ln -sf /usr/local/bin/ffmpeg /usr/lib/jellyfin-ffmpeg/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/lib/jellyfin-ffmpeg/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    rm -rf /tmp/ffmpeg-btbn.tar.xz /tmp/btbn && \
    ffmpeg -version && \
    apt-get clean autoclean --yes && \
    apt-get autoremove --yes && \
    rm -rf /var/cache/apt/archives* /var/lib/apt/lists/*

# Copy built binary from builder image
COPY --from=builder /app/threadfin $THREADFIN_BIN/
RUN chmod +rx $THREADFIN_BIN/threadfin

# Configure container volume mappings
VOLUME $THREADFIN_CONF
VOLUME $THREADFIN_TEMP

EXPOSE $THREADFIN_PORT

ENTRYPOINT ["sh", "-c", "${THREADFIN_BIN}/threadfin -port=${THREADFIN_PORT} -bind=${THREADFIN_BIND_IP_ADDRESS} -config=${THREADFIN_CONF} -debug=${THREADFIN_DEBUG}"]
