import importlib.util
import os
import pathlib
import sys
import types
import unittest


MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "autoscaler.py"


def ensure_dependency_stubs():
    class StubRedisError(Exception):
        pass

    class StubConnectionError(StubRedisError):
        pass

    class StubResponseError(StubRedisError):
        pass

    redis_stub = types.SimpleNamespace(
        exceptions=types.SimpleNamespace(
            RedisError=StubRedisError,
            ConnectionError=StubConnectionError,
            ResponseError=StubResponseError,
        ),
        Redis=lambda *args, **kwargs: None,
    )
    docker_stub = types.SimpleNamespace(from_env=lambda: None, errors=types.SimpleNamespace(APIError=Exception))
    dotenv_stub = types.SimpleNamespace(load_dotenv=lambda: None)

    sys.modules.setdefault("redis", redis_stub)
    sys.modules.setdefault("docker", docker_stub)
    sys.modules.setdefault("dotenv", dotenv_stub)


def load_autoscaler_module():
    ensure_dependency_stubs()
    required_env = {
        "REDIS_HOST": "redis",
        "REDIS_PORT": "6379",
        "QUEUE_NAME_PREFIX": "bull",
        "QUEUE_NAME": "jobs",
        "N8N_WORKER_SERVICE_NAME": "n8n-worker",
        "COMPOSE_PROJECT_NAME": "n8n-autoscaling",
        "COMPOSE_FILE_PATH": "/app/docker-compose.yml",
        "MIN_REPLICAS": "1",
        "MAX_REPLICAS": "5",
        "SCALE_UP_QUEUE_THRESHOLD": "5",
        "SCALE_DOWN_QUEUE_THRESHOLD": "1",
        "POLLING_INTERVAL_SECONDS": "10",
        "COOLDOWN_PERIOD_SECONDS": "10",
    }
    os.environ.update(required_env)

    spec = importlib.util.spec_from_file_location("autoscaler_under_test", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeRedisConnection:
    def __init__(self, key_types, key_lengths, redis_error=None):
        self.key_types = key_types
        self.key_lengths = key_lengths
        self.redis_error = redis_error

    def type(self, key):
        if self.redis_error:
            raise self.redis_error
        return self.key_types.get(key, "none")

    def llen(self, key):
        if self.redis_error:
            raise self.redis_error
        return self.key_lengths.get(key, 0)


class AutoscalerQueueLengthTests(unittest.TestCase):
    def test_prefers_waiting_key_when_wait_key_missing(self):
        module = load_autoscaler_module()
        conn = FakeRedisConnection(
            key_types={
                "bull:jobs:wait": "none",
                "bull:jobs:waiting": "list",
            },
            key_lengths={
                "bull:jobs:waiting": 4,
            },
        )
        self.assertEqual(module.get_queue_length(conn), 4)

    def test_skips_non_list_key_and_uses_legacy_list_key(self):
        module = load_autoscaler_module()
        conn = FakeRedisConnection(
            key_types={
                "bull:jobs:wait": "set",
                "bull:jobs:waiting": "none",
                "bull:jobs": "list",
            },
            key_lengths={
                "bull:jobs": 2,
            },
        )
        self.assertEqual(module.get_queue_length(conn), 2)

    def test_returns_none_when_redis_error_occurs(self):
        module = load_autoscaler_module()
        conn = FakeRedisConnection(
            key_types={},
            key_lengths={},
            redis_error=module.redis.exceptions.ConnectionError("redis down"),
        )
        self.assertIsNone(module.get_queue_length(conn))


class AutoscalerReplicaReadTests(unittest.TestCase):
    def test_returns_none_when_project_name_missing(self):
        module = load_autoscaler_module()
        docker_client = types.SimpleNamespace(containers=types.SimpleNamespace(list=lambda **kwargs: []))
        self.assertIsNone(module.get_current_replicas(docker_client, "n8n-worker", ""))

    def test_returns_none_when_docker_query_raises(self):
        module = load_autoscaler_module()

        def raise_error(**kwargs):
            raise RuntimeError("docker unavailable")

        docker_client = types.SimpleNamespace(containers=types.SimpleNamespace(list=raise_error))
        self.assertIsNone(module.get_current_replicas(docker_client, "n8n-worker", "proj"))


if __name__ == "__main__":
    unittest.main()
