import os
import time
import redis
import docker
import subprocess
import logging
from dotenv import load_dotenv

load_dotenv()

# --- Logging Setup ---
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO').upper()
logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO), format='%(asctime)s - %(levelname)s - %(message)s')

# --- Configuration from Environment Variables ---
REDIS_HOST = os.getenv('REDIS_HOST')
REDIS_PORT = int(os.getenv('REDIS_PORT'))
REDIS_PASSWORD = os.getenv('REDIS_PASSWORD') # Added for completeness
QUEUE_NAME_PREFIX = os.getenv('QUEUE_NAME_PREFIX')
QUEUE_NAME = os.getenv('QUEUE_NAME')

N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
N8N_WORKER_RUNNER_SERVICE_NAME = os.getenv('N8N_WORKER_RUNNER_SERVICE_NAME', 'n8n-worker-runner')  # n8n 2.0 task runner sidecar
COMPOSE_PROJECT_NAME = os.getenv('COMPOSE_PROJECT_NAME') # e.g., "n8n-workers"
COMPOSE_FILE_PATH = os.getenv('COMPOSE_FILE_PATH') # Path inside this container

MIN_REPLICAS = int(os.getenv('MIN_REPLICAS'))
MAX_REPLICAS = int(os.getenv('MAX_REPLICAS'))
SCALE_UP_QUEUE_THRESHOLD = int(os.getenv('SCALE_UP_QUEUE_THRESHOLD'))
SCALE_DOWN_QUEUE_THRESHOLD = int(os.getenv('SCALE_DOWN_QUEUE_THRESHOLD'))

POLLING_INTERVAL_SECONDS = int(os.getenv('POLLING_INTERVAL_SECONDS'))
COOLDOWN_PERIOD_SECONDS = int(os.getenv('COOLDOWN_PERIOD_SECONDS'))
SUBPROCESS_TIMEOUT_SECONDS = 120  # Timeout for docker compose commands

last_scale_time = 0
last_known_replicas = None  # Track replica changes for event-driven logging

def get_redis_connection():
    """Establishes a connection to Redis."""
    logging.info(f"Connecting to Redis at {REDIS_HOST}:{REDIS_PORT}")
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, password=REDIS_PASSWORD, decode_responses=True)

def get_queue_length(r_conn):
    """Gets the length of the specified BullMQ waiting queue."""
    queue_keys = [
        f"{QUEUE_NAME_PREFIX}:{QUEUE_NAME}:wait",
        f"{QUEUE_NAME_PREFIX}:{QUEUE_NAME}:waiting",
        f"{QUEUE_NAME_PREFIX}:{QUEUE_NAME}",
    ]
    try:
        for key_to_check in queue_keys:
            key_type = r_conn.type(key_to_check)
            if key_type == "list":
                length = r_conn.llen(key_to_check)
                logging.debug(f"Using queue key '{key_to_check}' for queue length: {length}")
                return length
            if key_type not in ("none", "list"):
                logging.debug(
                    f"Queue key '{key_to_check}' exists but has type '{key_type}', expected list. Skipping."
                )

        logging.debug(
            "No known queue keys exist as lists for patterns %s. Assuming queue length 0.",
            queue_keys,
        )
        return 0
    except redis.exceptions.RedisError as e:
        logging.error(f"Redis error when checking length of queue keys: {e}. Queue length unknown.")
        return None
    except Exception as e:
        logging.error(f"Unexpected error checking queue length: {e}. Queue length unknown.")
        return None


def get_current_replicas(docker_client, service_name, project_name):
    """Gets the current number of running containers for a Docker Compose service."""
    if not project_name:
        logging.warning("COMPOSE_PROJECT_NAME is not set. Cannot accurately determine current replicas.")
        return None

    try:
        filters = {
            "label": [
                f"com.docker.compose.service={service_name}",
                f"com.docker.compose.project={project_name}"
            ],
            "status": "running"
        }
        service_containers = docker_client.containers.list(filters=filters, all=True) # all=True to catch restarting ones too
        
        # Further filter by status in Python if 'status' filter is not precise enough
        running_count = 0
        for container in service_containers:
            if container.status == 'running':
                 running_count +=1
        logging.debug(f"Found {running_count} running containers for service '{service_name}' in project '{project_name}'.")
        return running_count
    except Exception as e:
        logging.error(f"Error getting current replicas for {service_name} in {project_name}: {e}")
        return None


def scale_service(service_name, replicas, compose_file, project_name):
    """Scales a Docker Compose service using docker-compose CLI."""
    if not project_name:
        logging.error("COMPOSE_PROJECT_NAME is not set. Cannot execute docker-compose scale.")
        return False

    command = [
        "docker",
        "compose",
        "-f", compose_file,
        "--project-name", project_name,
        "--project-directory", "/app",
        "up",
        "-d",
        "--no-deps",
        "--scale", f"{service_name}={replicas}",
        service_name
    ]
    logging.info(f"Executing scaling command: {' '.join(command)}")
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=SUBPROCESS_TIMEOUT_SECONDS)
        logging.info(f"Scale command stdout: {result.stdout.strip()}")
        if result.stderr.strip():
             logging.warning(f"Scale command stderr: {result.stderr.strip()}")
        return True
    except subprocess.TimeoutExpired:
        logging.error(f"Timeout ({SUBPROCESS_TIMEOUT_SECONDS}s) scaling service {service_name} to {replicas}. Docker may be unresponsive.")
        return False
    except subprocess.CalledProcessError as e:
        logging.error(f"Error scaling service {service_name} to {replicas}:")
        logging.error(f"  Command: {' '.join(e.cmd)}")
        logging.error(f"  Return Code: {e.returncode}")
        logging.error(f"  Stdout: {e.stdout}")
        logging.error(f"  Stderr: {e.stderr}")
        return False
    except FileNotFoundError:
        logging.error("docker command not found. Ensure Docker CLI with Compose v2 is installed and in PATH.")
        return False


def scale_worker_with_runner(replicas, compose_file, project_name):
    """Scales both the n8n worker and its task runner sidecar together (n8n 2.0 requirement)."""
    logging.info(f"Scaling worker and task runner to {replicas} replicas each...")

    # Scale both services in a single command for atomicity
    if not project_name:
        logging.error("COMPOSE_PROJECT_NAME is not set. Cannot execute docker-compose scale.")
        return False

    command = [
        "docker",
        "compose",
        "-f", compose_file,
        "--project-name", project_name,
        "--project-directory", "/app",
        "up",
        "-d",
        "--no-deps",
        "--scale", f"{N8N_WORKER_SERVICE_NAME}={replicas}",
        "--scale", f"{N8N_WORKER_RUNNER_SERVICE_NAME}={replicas}",
        N8N_WORKER_SERVICE_NAME,
        N8N_WORKER_RUNNER_SERVICE_NAME
    ]
    logging.info(f"Executing scaling command: {' '.join(command)}")
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=SUBPROCESS_TIMEOUT_SECONDS)
        logging.info(f"Scale command stdout: {result.stdout.strip()}")
        if result.stderr.strip():
             logging.warning(f"Scale command stderr: {result.stderr.strip()}")
        return True
    except subprocess.TimeoutExpired:
        logging.error(f"Timeout ({SUBPROCESS_TIMEOUT_SECONDS}s) scaling worker+runner to {replicas}. Docker may be unresponsive.")
        return False
    except subprocess.CalledProcessError as e:
        logging.error(f"Error scaling worker+runner to {replicas}:")
        logging.error(f"  Command: {' '.join(e.cmd)}")
        logging.error(f"  Return Code: {e.returncode}")
        logging.error(f"  Stdout: {e.stdout}")
        logging.error(f"  Stderr: {e.stderr}")
        return False
    except FileNotFoundError:
        logging.error("docker command not found. Ensure Docker CLI with Compose v2 is installed and in PATH.")
        return False


def get_docker_client():
    """Creates a Docker client with connection test."""
    client = docker.from_env()
    client.ping()
    return client


def main():
    global last_scale_time, last_known_replicas
    
    if not COMPOSE_PROJECT_NAME:
        logging.error("CRITICAL: COMPOSE_PROJECT_NAME environment variable is not set. Autoscaler cannot function correctly.")
        logging.error("Please set COMPOSE_PROJECT_NAME to the name of your Docker Compose project (usually the directory name).")
        return # Exit if critical env var is missing

    try:
        r_conn = get_redis_connection()
        docker_cl = get_docker_client()
        logging.info("Successfully connected to Docker daemon.")
    except Exception as e:
        logging.error(f"CRITICAL: Failed to connect to Redis or Docker: {e}")
        return

    logging.info(f"Autoscaler started. Monitoring n8n worker service '{N8N_WORKER_SERVICE_NAME}' in project '{COMPOSE_PROJECT_NAME}'.")
    logging.info(f"  Min Replicas: {MIN_REPLICAS}, Max Replicas: {MAX_REPLICAS}")
    logging.info(f"  Scale Up Queue Threshold: >{SCALE_UP_QUEUE_THRESHOLD}")
    logging.info(f"  Scale Down Queue Threshold: <{SCALE_DOWN_QUEUE_THRESHOLD}")
    logging.info(f"  Polling Interval: {POLLING_INTERVAL_SECONDS}s, Cooldown: {COOLDOWN_PERIOD_SECONDS}s")

    while True:
        try:
            current_time = time.time()
            if (current_time - last_scale_time) < COOLDOWN_PERIOD_SECONDS:
                logging.debug(f"In cooldown period. Next check in {COOLDOWN_PERIOD_SECONDS - (current_time - last_scale_time):.0f}s.")
                time.sleep(POLLING_INTERVAL_SECONDS) # Still sleep for polling interval
                continue

            queue_len = get_queue_length(r_conn)
            current_reps = get_current_replicas(docker_cl, N8N_WORKER_SERVICE_NAME, COMPOSE_PROJECT_NAME)

            if queue_len is None or current_reps is None:
                logging.warning(
                    "Skipping scaling decision due to dependency read failure "
                    "(queue_len=%s, current_replicas=%s).",
                    queue_len,
                    current_reps,
                )
                time.sleep(POLLING_INTERVAL_SECONDS)
                continue

            # Event-driven logging: only log queue length when there's work
            if queue_len > 0:
                logging.info(f"Queue Length: {queue_len}, Current Replicas: {current_reps}")

            # Log replica changes (state-based tracking)
            if last_known_replicas is not None and current_reps != last_known_replicas:
                logging.info(f"{N8N_WORKER_SERVICE_NAME} replicas changed: {last_known_replicas} -> {current_reps}")
            last_known_replicas = current_reps

            scaled = False
            if queue_len > SCALE_UP_QUEUE_THRESHOLD and current_reps < MAX_REPLICAS:
                new_replicas = min(current_reps + 1, MAX_REPLICAS) # Scale one by one for now
                logging.info(f"Condition met for SCALE UP. Queue: {queue_len} > {SCALE_UP_QUEUE_THRESHOLD}. Replicas: {current_reps} < {MAX_REPLICAS}.")
                if scale_worker_with_runner(new_replicas, COMPOSE_FILE_PATH, COMPOSE_PROJECT_NAME):
                    last_scale_time = current_time
                    scaled = True
            elif queue_len < SCALE_DOWN_QUEUE_THRESHOLD and current_reps > MIN_REPLICAS:
                new_replicas = max(current_reps - 1, MIN_REPLICAS) # Scale one by one
                logging.info(f"Condition met for SCALE DOWN. Queue: {queue_len} < {SCALE_DOWN_QUEUE_THRESHOLD}. Replicas: {current_reps} > {MIN_REPLICAS}.")
                if scale_worker_with_runner(new_replicas, COMPOSE_FILE_PATH, COMPOSE_PROJECT_NAME):
                    last_scale_time = current_time
                    scaled = True
            
            # Removed "No scaling action needed" log - silent when idle

        except redis.exceptions.ConnectionError as e:
            logging.error(f"Redis connection error: {e}. Retrying connection...")
            time.sleep(5)
            try:
                r_conn = get_redis_connection()
                logging.info("Successfully reconnected to Redis.")
            except Exception as recon_e:
                logging.error(f"Failed to reconnect to Redis: {recon_e}")
        except docker.errors.APIError as e:
            logging.error(f"Docker API error: {e}. Retrying connection...")
            time.sleep(5)
            try:
                docker_cl = get_docker_client()
                logging.info("Successfully reconnected to Docker daemon.")
            except Exception as recon_e:
                logging.error(f"Failed to reconnect to Docker: {recon_e}")
        except Exception as e:
            logging.error(f"Error in autoscaler main loop: {e}", exc_info=True)
            # Check if Docker connection is still valid
            try:
                docker_cl.ping()
            except Exception:
                logging.warning("Docker connection lost. Attempting reconnection...")
                try:
                    docker_cl = get_docker_client()
                    logging.info("Successfully reconnected to Docker daemon.")
                except Exception as recon_e:
                    logging.error(f"Failed to reconnect to Docker: {recon_e}")

        time.sleep(POLLING_INTERVAL_SECONDS)

if __name__ == "__main__":
    main()