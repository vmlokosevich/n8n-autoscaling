import redis
import time
import os
import logging

# --- Logging Setup ---
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO').upper()
logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO), format='%(asctime)s - %(levelname)s - %(message)s')

REDIS_HOST = os.getenv('REDIS_HOST', 'localhost')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
REDIS_PASSWORD = os.getenv('REDIS_PASSWORD', None)
QUEUE_NAME_PREFIX = os.getenv('QUEUE_NAME_PREFIX', 'bull') # BullMQ default prefix
QUEUE_NAME = os.getenv('QUEUE_NAME', 'jobs')
POLL_INTERVAL_SECONDS = int(os.getenv('POLL_INTERVAL_SECONDS', 5))

def get_redis_connection():
    """Establishes a connection to Redis."""
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, password=REDIS_PASSWORD, decode_responses=True)
        r.ping()
        logging.info(f"Successfully connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
        return r
    except redis.exceptions.ConnectionError as e:
        logging.error(f"Error connecting to Redis: {e}")
        return None

def get_queue_length(r_conn, queue_name_prefix, queue_name):
    """Gets the length of the specified BullMQ queue."""
    queue_keys = [
        f"{queue_name_prefix}:{queue_name}:wait",
        f"{queue_name_prefix}:{queue_name}:waiting",
        f"{queue_name_prefix}:{queue_name}",
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
        logging.error(f"Redis error when checking queue length: {e}. Queue length unknown.")
        return None
    except Exception as e:
        logging.error(f"Unexpected error when checking queue length: {e}. Queue length unknown.")
        return None


if __name__ == "__main__":
    redis_conn = get_redis_connection()
    if redis_conn:
        logging.info(f"Monitoring Redis queue '{QUEUE_NAME_PREFIX}:{QUEUE_NAME}' every {POLL_INTERVAL_SECONDS} seconds...")
        last_known_length = None  # Track queue length changes for event-driven logging
        try:
            while True:
                length = get_queue_length(redis_conn, QUEUE_NAME_PREFIX, QUEUE_NAME)
                if length is None:
                    logging.warning("Skipping queue report because Redis state is currently unavailable.")
                    time.sleep(POLL_INTERVAL_SECONDS)
                    continue

                # Event-driven logging: only log when queue has items or length changes
                if length > 0:
                    logging.info(f"Queue '{QUEUE_NAME_PREFIX}:{QUEUE_NAME}' length: {length}")
                elif last_known_length is not None and last_known_length > 0 and length == 0:
                    # Log when queue drains to zero (transition event)
                    logging.info(f"Queue '{QUEUE_NAME_PREFIX}:{QUEUE_NAME}' drained to 0")

                last_known_length = length
                time.sleep(POLL_INTERVAL_SECONDS)
        except KeyboardInterrupt:
            logging.info("Monitoring stopped by user.")
        finally:
            redis_conn.close()
            logging.info("Redis connection closed.")