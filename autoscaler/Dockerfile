# Use an official Python runtime as a parent image
FROM python:3.12-slim AS builder

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    jq \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory in the container
WORKDIR /app

# Install pinned Docker Compose v2 (multi-architecture support)
ARG DOCKER_COMPOSE_VERSION=v2.40.3
RUN mkdir -p ~/.docker/cli-plugins/ && \
    ARCH=$(dpkg --print-architecture) && \
    case ${ARCH} in \
        amd64) COMPOSE_ARCH='x86_64' ;; \
        arm64) COMPOSE_ARCH='aarch64' ;; \
        armhf) COMPOSE_ARCH='armv7' ;; \
        *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    COMPOSE_FILE="docker-compose-linux-${COMPOSE_ARCH}" && \
    COMPOSE_BASE_URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}" && \
    curl -fsSL "${COMPOSE_BASE_URL}/${COMPOSE_FILE}" -o "/tmp/${COMPOSE_FILE}" && \
    curl -fsSL "${COMPOSE_BASE_URL}/checksums.txt" -o /tmp/checksums.txt && \
    cd /tmp && \
    grep "\\*${COMPOSE_FILE}$" checksums.txt | sha256sum -c - && \
    mv "/tmp/${COMPOSE_FILE}" ~/.docker/cli-plugins/docker-compose && \
    chmod +x ~/.docker/cli-plugins/docker-compose

# Copy requirements first to leverage Docker cache
COPY autoscaler/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Final stage
FROM python:3.12-slim
WORKDIR /app

# Install Docker CLI and dependencies in the final stage
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy from builder
COPY --from=builder /root/.docker/cli-plugins/ /usr/local/lib/docker/cli-plugins/
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages

# Ensure docker compose plugin is in PATH
ENV PATH="/usr/local/lib/docker/cli-plugins:${PATH}"

# Copy application files
COPY autoscaler/autoscaler.py .
COPY docker-compose.yml .
COPY Dockerfile .

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD sh -c "python -c \"import pathlib,sys; args=pathlib.Path('/proc/1/cmdline').read_bytes().split(b'\\x00'); sys.exit(0 if any(b'autoscaler.py' in arg for arg in args) else 1)\" && docker info >/dev/null 2>&1"

# Specify the command to run on container start
CMD ["python", "-u", "autoscaler.py"]
