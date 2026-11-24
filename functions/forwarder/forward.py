"""Forwarding logic for the IoT Hub forwarder Function.

Kept free of azure.functions so it can be unit-tested with the standard library.
The Function in function_app.py is a thin wrapper around these two functions.
"""

import json
import time
import urllib.error
import urllib.request


def parse_message(body, hub_device_id=None):
    """Turn one IoT Hub message body into the JSON that Laravel expects.

    Returns (payload, None) when the message can be forwarded, or (None, reason)
    when it must be dropped.

    hub_device_id is the device identity that IoT Hub authenticated, when the trigger
    exposes it. It is trusted over the device_id inside the body: a device that
    claims another device's id is dropped, and a body without a device_id gets the
    authenticated one.
    """
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, "the body is not JSON"
    if not isinstance(payload, dict):
        return None, "the body is not a JSON object"

    if hub_device_id:
        claimed = payload.get("device_id")
        if claimed is not None and str(claimed) != str(hub_device_id):
            return None, "device_id in the body does not match the IoT Hub identity"
        payload["device_id"] = hub_device_id

    if payload.get("device_id") is None or payload.get("hive_id") is None:
        return None, "device_id or hive_id is missing"
    return payload, None


def post_reading(payload, base_url, api_key, timeout=15, attempts=3, sleep=time.sleep, opener=urllib.request.urlopen):
    """POST one reading to Laravel's /api/sensor-data.

    Returns a pair:
      ("sent", status)      Laravel accepted it (201).
      ("rejected", status)  Laravel answered 4xx (unknown device, validation, bad key). Retrying
                            cannot help, so it is not retried. 408 and 429 are treated as transient.
      ("failed", detail)    Network errors, timeouts and 5xx, after `attempts` tries with a 2 s
                            then 4 s pause.
    """
    url = base_url.rstrip("/") + "/api/sensor-data"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json", "X-API-Key": api_key},
    )
    last = "no attempt was made"
    for attempt in range(1, attempts + 1):
        try:
            with opener(request, timeout=timeout) as response:
                return "sent", response.status
        except urllib.error.HTTPError as error:  # must come before URLError: it is a subclass
            if 400 <= error.code < 500 and error.code not in (408, 429):
                return "rejected", error.code
            last = "HTTP %d" % error.code
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last = "%s: %s" % (type(error).__name__, error)
        if attempt < attempts:
            sleep(2 ** attempt)
    return "failed", last
