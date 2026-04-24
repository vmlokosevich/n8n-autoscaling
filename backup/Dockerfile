# Backup runtime image
FROM python:3.9-slim

WORKDIR /app

# Install runtime tools from Debian packages.
# This avoids copying Alpine (musl) binaries into Debian (glibc).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    postgresql-client \
    rclone \
    gnupg \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY backup/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Create backup working directory and empty default rclone config
RUN mkdir -p /backups /config/rclone && \
    touch /config/rclone/rclone.conf

# Copy application
COPY backup/backup.py .

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import pathlib,sys; args=pathlib.Path('/proc/1/cmdline').read_bytes().split(b'\x00'); sys.exit(0 if any(b'backup.py' in arg for arg in args) else 1)"

CMD ["python", "-u", "backup.py"]
