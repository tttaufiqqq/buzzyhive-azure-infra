# Load test

k6 scripts for the lab. Nothing here has been run against Azure yet.

## Run

In Windows PowerShell, from the repo root. The key is read from the environment, so it never lands in a file:

```powershell
$env:K6_INCLUDE_SYSTEM_ENV_VARS = "true"   # k6 2.x ignores shell variables unless this is set
$env:BUZZYHIVE_URL     = "https://laravel-web.<env>.malaysiawest.azurecontainerapps.io"
$env:BUZZYHIVE_API_KEY = "<the iot-api-key value from app_secrets>"

k6 run loadtest/ingest.js                                # smoke: 1 request/s for 30 s
$env:PROFILE = "ramp"; $env:PEAK = "20"; k6 run loadtest/ingest.js
```

Run the smoke profile first. Its only job is to show the script, the URL and the key work.

Do not pass the key with `-e`: it would sit in the process arguments and in the shell history. The environment variable `K6_INCLUDE_SYSTEM_ENV_VARS` (checked with k6 v2.1.0, `k6 inspect`) is what lets the script see the shell variables. Without it the script stops in `setup()` with "Set BUZZYHIVE_URL and BUZZYHIVE_API_KEY first."

## `ingest.js`

- Posts to `/api/sensor-data` across hives 1 to 8, with the same baseline reading as `scripts/simulate_sensor.py`.
- The baseline classifies as `not_ready`, so it queues no Telegram alert.
- Thresholds: error rate under 1%, p95 under 500 ms (the app's `NFR-PERF-01`), and no `ml_unavailable` responses.
- Failing a threshold is a result, not a bug: one 0.5 vCPU web replica is expected to saturate, and the rate where p95 crosses 500 ms is what to record.

## While it runs, capture

- The k6 end-of-test summary (copy the text).
- Container Apps requests and replica count for `laravel-web`, and CPU for `flask-ml`.
- MySQL `cpu_percent` (the alert fires above 80%).
- Any alert email.

Blur identifiers in every screenshot before it is committed.
