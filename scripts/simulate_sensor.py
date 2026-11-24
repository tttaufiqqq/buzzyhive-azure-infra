#!/usr/bin/env python3
"""Stand-in for the ESP32: posts sensor readings to BuzzyHive's /api/sensor-data.

The ESP32 cannot speak IoT Hub, so this script sends the same JSON the device
would, straight to the Laravel app, with the shared X-API-Key header.

Standard library only. No pip install needed.

Settings come from the environment so the key never lands in a file or in shell
history as an argument:

    $env:BUZZYHIVE_URL     = "https://laravel-web.<env>.malaysiawest.azurecontainerapps.io"
    $env:BUZZYHIVE_API_KEY = "<the iot-api-key value from app_secrets>"
    python scripts/simulate_sensor.py --hive-id 1 --device-id NODE-001 --count 5

The hive and the device (node_identifier) must already exist in the app and the
device must be active, or the API answers 404.
"""

import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

# Values taken from the app's documented happy-path test (docs/modules/
# sensor-monitoring-module.md, Test A). They are a plausible baseline, not a
# claim about what makes a hive "ready".
BASELINE = {"temp": 33.5, "humidity": 70.0, "mq2_value": 250, "mq3_value": 200, "mq5_value": 180, "mq135_value": 220}


def clamp(value, low, high):
    return max(low, min(high, value))


def baseline_reading():
    """The documented example values with a little noise."""
    return {
        "temp": round(clamp(BASELINE["temp"] + random.uniform(-1.0, 1.0), -10, 60), 1),
        "humidity": round(clamp(BASELINE["humidity"] + random.uniform(-3.0, 3.0), 0, 100), 1),
        "mq2_value": int(clamp(BASELINE["mq2_value"] + random.randint(-20, 20), 0, 4095)),
        "mq3_value": int(clamp(BASELINE["mq3_value"] + random.randint(-20, 20), 0, 4095)),
        "mq5_value": int(clamp(BASELINE["mq5_value"] + random.randint(-20, 20), 0, 4095)),
        "mq135_value": int(clamp(BASELINE["mq135_value"] + random.randint(-20, 20), 0, 4095)),
    }


def random_reading():
    """Anywhere inside the ranges the API accepts."""
    return {
        "temp": round(random.uniform(20, 45), 1),
        "humidity": round(random.uniform(30, 95), 1),
        "mq2_value": random.randint(0, 4095),
        "mq3_value": random.randint(0, 4095),
        "mq5_value": random.randint(0, 4095),
        "mq135_value": random.randint(0, 4095),
    }


def _in_ranges(temp, humidity, mq2, mq3, mq5, mq135):
    return {
        "temp": round(random.uniform(*temp), 1),
        "humidity": round(random.uniform(*humidity), 1),
        "mq2_value": random.randint(*mq2),
        "mq3_value": random.randint(*mq3),
        "mq5_value": random.randint(*mq5),
        "mq135_value": random.randint(*mq135),
    }


def ready_reading():
    """Readings the model in service labels `ready` (a Telegram alert is queued).

    Found on 24/11/2026 by running the app repo's committed model.pkl and runtime
    guardrails over 2000 random samples of these ranges: all 2000 were `ready` with
    no warning. This is the stale k=1 model; a retrained model may label them
    differently. Each reading queues one alert, with no cooldown, so keep --count small.
    """
    return _in_ranges((32.0, 34.0), (66, 74), (150, 175), (160, 190), (232, 250), (275, 295))


def nearly_ready_reading():
    """Same check as ready_reading, 2000 of 2000 samples were `nearly_ready`."""
    return _in_ranges((32.0, 34.0), (62, 68), (120, 145), (115, 150), (190, 215), (225, 250))


PROFILES = {
    "baseline": baseline_reading,
    "random": random_reading,
    "ready": ready_reading,
    "nearly_ready": nearly_ready_reading,
}


def post(url, api_key, payload, timeout):
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json", "X-API-Key": api_key},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace"), time.monotonic() - started
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace"), time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("BUZZYHIVE_URL"), help="app base URL (or BUZZYHIVE_URL)")
    parser.add_argument("--hive-id", type=int, required=True, help="id of an existing hive")
    parser.add_argument("--device-id", required=True, help="node_identifier of an active device on that hive")
    parser.add_argument("--count", type=int, default=1, help="number of readings to send (default 1)")
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between readings (default 5)")
    parser.add_argument("--profile", choices=sorted(PROFILES), default="baseline")
    parser.add_argument("--timeout", type=float, default=60.0, help="request timeout in seconds; the first call can be slow while the app scales up from zero")
    args = parser.parse_args()

    api_key = os.environ.get("BUZZYHIVE_API_KEY")
    if not args.url or not api_key:
        sys.exit("Set BUZZYHIVE_URL (or --url) and BUZZYHIVE_API_KEY first.")

    endpoint = args.url.rstrip("/") + "/api/sensor-data"
    failures = 0

    for n in range(1, args.count + 1):
        reading = PROFILES[args.profile]()
        payload = {"device_id": args.device_id, "hive_id": args.hive_id, **reading}
        try:
            status, text, seconds = post(endpoint, api_key, payload, args.timeout)
        except (urllib.error.URLError, TimeoutError) as error:
            failures += 1
            print(f"[{n}/{args.count}] network error: {error}")
        else:
            ok = status == 201
            failures += 0 if ok else 1
            print(f"[{n}/{args.count}] {status} in {seconds:.2f}s  {json.dumps(reading)}")
            if not ok or "warnings" in text:
                print(f"    response: {text[:300]}")
        if n < args.count:
            time.sleep(args.interval)

    print(f"done: {args.count - failures} ok, {failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
