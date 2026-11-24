"""Unit tests for forward.py. Standard library only: python -m unittest discover -s functions/forwarder/tests"""

import json
import os
import sys
import unittest
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from forward import parse_message, post_reading  # noqa: E402

READING = {"device_id": "NODE-1", "hive_id": 1, "temp": 33.5, "humidity": 70.0,
           "mq2_value": 250, "mq3_value": 200, "mq5_value": 180, "mq135_value": 220}


def body(obj):
    return json.dumps(obj).encode("utf-8")


class FakeResponse:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeOpener:
    """Plays back a list of outcomes: an int status, or an exception to raise."""

    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.requests = []

    def __call__(self, request, timeout=None):
        self.requests.append((request, timeout))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return FakeResponse(outcome)


def http_error(code):
    return urllib.error.HTTPError("https://x/api/sensor-data", code, "err", {}, None)


class ParseMessageTests(unittest.TestCase):
    def test_valid_message_passes_through(self):
        payload, problem = parse_message(body(READING))
        self.assertIsNone(problem)
        self.assertEqual(payload, READING)

    def test_not_json_is_dropped(self):
        self.assertEqual(parse_message(b"\xff\xfe")[1], "the body is not JSON")
        self.assertEqual(parse_message(b"{nope")[1], "the body is not JSON")

    def test_json_array_is_dropped(self):
        self.assertEqual(parse_message(b"[1, 2]")[1], "the body is not a JSON object")

    def test_missing_hive_id_is_dropped(self):
        reading = dict(READING)
        del reading["hive_id"]
        self.assertEqual(parse_message(body(reading))[1], "device_id or hive_id is missing")

    def test_authenticated_device_id_fills_a_missing_one(self):
        reading = dict(READING)
        del reading["device_id"]
        payload, problem = parse_message(body(reading), "NODE-1")
        self.assertIsNone(problem)
        self.assertEqual(payload["device_id"], "NODE-1")

    def test_a_device_claiming_another_identity_is_dropped(self):
        payload, problem = parse_message(body(READING), "NODE-2")
        self.assertIsNone(payload)
        self.assertIn("does not match", problem)

    def test_matching_authenticated_identity_is_accepted(self):
        self.assertIsNone(parse_message(body(READING), "NODE-1")[1])


class PostReadingTests(unittest.TestCase):
    def setUp(self):
        self.sleeps = []
        self.sleep = self.sleeps.append

    def post(self, outcomes, **kwargs):
        opener = FakeOpener(outcomes)
        result = post_reading(READING, "https://web.example/", "KEY", sleep=self.sleep, opener=opener, **kwargs)
        return result, opener

    def test_201_is_sent_with_the_key_and_the_right_url(self):
        result, opener = self.post([201])
        self.assertEqual(result, ("sent", 201))
        request, timeout = opener.requests[0]
        self.assertEqual(request.full_url, "https://web.example/api/sensor-data")
        self.assertEqual(request.get_header("X-api-key"), "KEY")
        self.assertEqual(json.loads(request.data), READING)
        self.assertEqual(timeout, 15)

    def test_4xx_is_rejected_without_retry(self):
        for code in (401, 404, 422):
            result, opener = self.post([http_error(code)])
            self.assertEqual(result, ("rejected", code))
            self.assertEqual(len(opener.requests), 1)
        self.assertEqual(self.sleeps, [])

    def test_5xx_is_retried_then_succeeds(self):
        result, opener = self.post([http_error(502), http_error(500), 201])
        self.assertEqual(result, ("sent", 201))
        self.assertEqual(len(opener.requests), 3)
        self.assertEqual(self.sleeps, [2, 4])

    def test_429_and_408_count_as_transient(self):
        result, _ = self.post([http_error(429), http_error(408), 201])
        self.assertEqual(result, ("sent", 201))

    def test_timeouts_fail_after_all_attempts(self):
        result, opener = self.post([TimeoutError("slow")] * 3)
        self.assertEqual(result[0], "failed")
        self.assertIn("TimeoutError", result[1])
        self.assertEqual(len(opener.requests), 3)
        self.assertEqual(self.sleeps, [2, 4])

    def test_connection_errors_fail_with_the_last_detail(self):
        result, _ = self.post([urllib.error.URLError("refused")] * 3)
        self.assertEqual(result[0], "failed")
        self.assertIn("refused", result[1])

    def test_persistent_5xx_fails(self):
        result, _ = self.post([http_error(503)] * 3)
        self.assertEqual(result, ("failed", "HTTP 503"))


if __name__ == "__main__":
    unittest.main()
