"""IoT Hub to Laravel forwarder (Azure Functions, Python v2 programming model).

Reads device messages from the IoT Hub's built-in Event Hub-compatible endpoint and posts each
one to laravel-web's /api/sensor-data with the shared API key, exactly as the ESP32 does over HTTP.

App settings (set by Terraform in lab/iot.tf):
  IOTHUB_EVENTS_CONNECTION  connection string of the Event Hub-compatible endpoint
  IOTHUB_EVENTS_PATH        its entity path (the event hub name)
  LARAVEL_URL               https://<laravel-web fqdn>
  LARAVEL_API_KEY           the iot-api-key value
"""

import logging
import os
from typing import List

import azure.functions as func

from forward import parse_message, post_reading

app = func.FunctionApp()


@app.function_name(name="forward_reading")
@app.event_hub_message_trigger(
    arg_name="events",
    event_hub_name="%IOTHUB_EVENTS_PATH%",
    connection="IOTHUB_EVENTS_CONNECTION",
    cardinality="many",
)
def forward_reading(events: List[func.EventHubEvent]):
    base_url = os.environ["LARAVEL_URL"]
    api_key = os.environ["LARAVEL_API_KEY"]
    counts = {"sent": 0, "rejected": 0, "failed": 0, "dropped": 0}

    for event in events:
        # IoT Hub adds the authenticated device id to the message metadata.
        metadata = getattr(event, "iothub_metadata", None) or {}
        payload, problem = parse_message(event.get_body(), metadata.get("connection-device-id"))
        if problem:
            counts["dropped"] += 1
            logging.warning("dropped a message: %s", problem)
            continue

        outcome, detail = post_reading(payload, base_url, api_key)
        counts[outcome] += 1
        if outcome != "sent":
            logging.warning("%s hive=%s device=%s: %s", outcome, payload.get("hive_id"), payload.get("device_id"), detail)

    logging.info("batch of %d messages: %s", len(events), counts)
