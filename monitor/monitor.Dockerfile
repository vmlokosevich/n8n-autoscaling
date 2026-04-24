# Use an official Python runtime as a parent image
FROM python:3.12-slim

# Set the working directory in the container
WORKDIR /usr/src/app

# Copy the Python script into the container
COPY ./monitor/monitor_redis_queue.py .

# Install any needed packages specified in requirements.txt
# For this script, we only need 'redis'
RUN pip install --no-cache-dir redis

# Create non-root user for security
RUN useradd -m -u 1000 monitor && \
    chown -R monitor:monitor /usr/src/app
USER monitor

# Define environment variables that can be overridden at runtime
# These defaults should work with the existing docker-compose.yml
ENV REDIS_HOST=redis
ENV REDIS_PORT=6379
ENV QUEUE_NAME_PREFIX=bull
ENV QUEUE_NAME=jobs
ENV POLL_INTERVAL_SECONDS=5

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import pathlib,sys; args=pathlib.Path('/proc/1/cmdline').read_bytes().split(b'\x00'); sys.exit(0 if any(b'monitor_redis_queue.py' in arg for arg in args) else 1)"

# Run monitor_redis_queue.py when the container launches
CMD ["python", "-u", "monitor_redis_queue.py"]
