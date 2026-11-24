#!/usr/bin/env python3
"""Stand-in for the ESP32 that sends readings to Azure IoT Hub over MQTT.

Unlike simulate_sensor.py, which posts HTTP straight to Laravel, this sends the
same JSON as device-to-cloud telemetry, so the readings show up in the hub's
Devices list and message metrics. Nothing forwards them to Laravel until the
IoT Hub forwarder Function is deployed (functions/forwarder, scripts/deploy-function.ps1),
so with the Function off they stop at the hub.

Requires one package:

    pip install azure-iot-device

The IoT Hub device ID must equal the node_identifier of an active device in the
app, because the payload's device_id is taken from the connection string. Create
the device and read its connection string without printing it:

    az extension add --name azure-iot
    az iot hub device-identity create -n <hub name> -d <node identifier> -o none
    $env:IOTHUB_DEVICE_CONNECTION_STRING = az iot hub device-identity connection-string show -n <hub name> -d <node identifier> --query connectionString -o tsv

Then send readings:

    python scripts/simulate_device.py --hive-id 1 --count 10 --interval 5

(-o none matters: without it the command prints the device keys.) The connection string contains a device key. Keep it in the environment, never in
a file, a command line or a screenshot.
"""

import argparse
import json
import os
import sys
import time

try:
    from azure.iot.device import IoTHubDeviceClient, Message
except ImportError:
    sys.exit("Install the SDK first: pip install azure-iot-device")

# Reuse the reading generators so both simulators send the same kind of data.
from simulate_sensor import PROFILES


def device_id_from(connection_string):
    for part in connection_string.split(";"):
        if part.lower().startswith("deviceid="):
            return part.split("=", 1)[1]
    sys.exit("The connection string has no DeviceId=... part.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hive-id", type=int, required=True, help="id of the hive this device is installed on")
    parser.add_argument("--count", type=int, default=1, help="number of readings to send (default 1)")
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between readings (default 5)")
    parser.add_argument("--profile", choices=sorted(PROFILES), default="baseline")
    args = parser.parse_args()

    connection_string = os.environ.get("IOTHUB_DEVICE_CONNECTION_STRING")
    if not connection_string:
        sys.exit("Set IOTHUB_DEVICE_CONNECTION_STRING first (see the top of this file).")

    device_id = device_id_from(connection_string)
    client = IoTHubDeviceClient.create_from_connection_string(connection_string)
    failures = 0

    try:
        client.connect()
        print(f"connected as device {device_id}")
        for n in range(1, args.count + 1):
            reading = PROFILES[args.profile]()
            payload = {"device_id": device_id, "hive_id": args.hive_id, **reading}
            message = Message(json.dumps(payload))
            message.content_type = "application/json"
            message.content_encoding = "utf-8"
            try:
                started = time.monotonic()
                client.send_message(message)
                print(f"[{n}/{args.count}] sent in {time.monotonic() - started:.2f}s  {json.dumps(reading)}")
            except Exception as error:  # the SDK raises several error types
                failures += 1
                print(f"[{n}/{args.count}] failed: {error}")
            if n < args.count:
                time.sleep(args.interval)
    finally:
        client.shutdown()

    print(f"done: {args.count - failures} sent, {failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
