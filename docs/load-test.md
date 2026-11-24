# Load test with k6

This article records the k6 ingest test run against the lab on 24/11/2026: what was sent, what failed, what the logs showed, what was changed, and what is still unknown.

> [!NOTE]
> **Three runs, one laptop, one lab.** Each run was a single execution from a laptop on a home connection, so the latencies include that network path. No run was repeated. The saturation point of the web replica was **not** found: the highest rate tried was 10 requests per second, and the failures at that rate came from a database deadlock and a probe restart, not from CPU.

## 1. What was tested

| Item | Value |
|---|---|
| Script | `loadtest/ingest.js` (k6 2.1.0) |
| Target | `POST /api/sensor-data` on `laravel-web`, which validates, saves the reading, calls `flask-ml`, stores a prediction and sends two Pusher events |
| Hives | Eight seeded hives, picked at random per request |
| Readings | The baseline reading with a little noise. It classifies as `not_ready`, so no Telegram alert is queued |
| Profile `ramp` | Arrival rate from 1 per second up to 10 per second over 6 minutes, held for 2 minutes, then down. About 8.5 minutes and about 3,300 requests |
| Thresholds | Error rate under 1%, p95 under 500 ms (the app's `NFR-PERF-01`), and no `ml_unavailable` responses |
| Deployment | One `laravel-web` replica (0.5 vCPU) and one `flask-ml` replica, both with `min_replicas = 1` |

A smoke run of 30 requests at 1 per second passed first (p95 187 ms, no failures).

## 2. Results

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| What was different | First ramp | Liveness probes lengthened | Deadlock retry in the app |
| Requests | 3,292 | 3,251 | 3,299 |
| Failed (no `201`) | 50 (1.51%) | 149 (4.58%) | **0 (0.00%)** |
| `ml_unavailable` | 16 | 0 | 0 |
| Median latency | 122 ms | 150 ms | 131 ms |
| p95 latency | 151 ms | **6.89 s** | 154 ms |
| Max latency | 15.11 s | 15 s | 303 ms |
| Thresholds | 3 of 4 failed | 3 of 4 failed | **All passed** |

*Table 2.1. Run 1 and run 2 failed their thresholds. Run 3 passed all four.*

The median stayed near 130 ms in every run. The failures came from short stalls where requests waited until k6's 15-second timeout, not from a gradual slowdown.

## 3. What the logs showed

Times are UTC in the logs; the lab's local time is UTC+8.

### 3.1 Run 1: web restarted after `flask-ml` was unreachable

- A `flask-ml` replica was started at 12:57:55.
- From 12:58:09, nearly every request logged `ml_unavailable` with a `ConnectionException` for about 20 seconds: the web app could not connect to `flask-ml`.
- The `laravel-web` liveness probe failed three times with its **1-second default timeout**, and the container was killed and restarted at 12:58:28. Requests in flight at that moment never got an answer.
- Why `flask-ml` was unreachable is **not confirmed**. A replica replacement with no overlap is the likely cause.
- Resource use during this run (portal charts): `laravel-web` peaked at 0.30 cores of 0.5, `flask-ml` at 0.06 cores, MySQL host CPU at 29.25% with 13 connections at most. Nothing was saturated.

### 3.2 Run 2: MySQL deadlocks, then another restart

- 81 requests logged `prediction_persist_failed`, all with the same MySQL error: `SQLSTATE[40001] 1213 Deadlock found when trying to get lock` on `insert into predictions`.
- They began at 13:37, when the ramp reached its 10-per-second hold, and rose from 20 to 28 to 33 per minute.
- The web liveness probe (now with a 5-second timeout) failed five times in a row from 13:39:00 and the container was restarted at 13:39:37. That is when k6's timeouts appeared.
- `flask-ml` caused no errors in this run.

### 3.3 Why the deadlock happens

The trigger `trg_predictions_after_insert` runs on every prediction insert. It re-aggregates **all of that hive's `sensor_logs` for the day** and upserts the result into `hri_summary`. Concurrent readings for one hive therefore read and lock the same rows while each other's inserts are in flight, and InnoDB aborts one of them. This is read from the trigger code and the error message. It was not reproduced in isolation.

## 4. What was changed

| Change | Where | Effect |
|---|---|---|
| `min_replicas = 1` on `laravel-web` and `flask-ml` (variable `keep_web_and_ml_warm`) | `lab/` | Removes scale-from-zero cold starts from the test |
| Liveness probes set to a 5-second timeout, 5 failures, 10-second initial delay | `lab/containerapps.tf` | A short stall no longer gets the container killed |
| `DB::transaction(..., 3)` in `persistPrediction` | App repo, `MlPredictionService.php` | Laravel retries the save up to 3 times when MySQL reports a deadlock |

The retry and the image built from it were deployed under the tag `300b276-deadlock-retry`. The change was built from a working tree with the edit uncommitted at the time.

## 5. What is not known

- **The retry may be hiding the deadlocks.** Laravel retries silently, so "no `1213` lines in the log" means no deadlock survived three attempts, not that none occurred. The server counter `Innodb_deadlocks` would show the real number. It was not read.
- **The trigger is still the cause.** It still scans the whole day on every insert, so latency can still climb as a hive's day fills. The proper fix is to update the summary incrementally, which was not done.
- **Probe failures still happened in run 3.** Seventeen `laravel-web` and seven `flask-ml` probe events timed out at 5 seconds between 14:08:58 and 14:15:50, even though every request in that run succeeded in under 303 ms. No liveness probe failed five times in a row, so no container restarted. Whether the longer probe settings are what prevented a restart is plausible but **not proven**, and why the probes timed out while requests were fast is **not explained**.
- **The saturation point was not found.** The highest rate was 10 requests per second.
- **Run 3 charts were not captured.** CPU and connection figures above come from run 1 only.
- **Pusher and Telegram were not stressed.** The readings stay `not_ready`, and live websocket delivery was not tested.

## 6. How to repeat it

See [`loadtest/README.md`](../loadtest/README.md). Set `K6_INCLUDE_SYSTEM_ENV_VARS=true` first, because k6 2.x ignores shell variables otherwise, and pass the key through an environment variable, never `-e`. Run the smoke profile before the ramp.

Related troubleshooting entries: [34](troubleshooting.md#34-a-short-stall-restarts-laravel-web-the-default-1-second-liveness-probe) and [35](troubleshooting.md#35-under-load-predictions-fail-to-save-a-mysql-deadlock-in-the-predictions-trigger).
