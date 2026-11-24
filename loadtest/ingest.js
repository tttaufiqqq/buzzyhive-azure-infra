// k6 ingest test for BuzzyHive: POST /api/sensor-data across eight hives.
//
// The URL and the key come from the environment, never from this file.
// k6 2.x only sees shell variables when K6_INCLUDE_SYSTEM_ENV_VARS=true:
//   $env:K6_INCLUDE_SYSTEM_ENV_VARS = "true"
//   $env:BUZZYHIVE_URL    = "https://laravel-web.<env>.malaysiawest.azurecontainerapps.io"
//   $env:BUZZYHIVE_API_KEY = "<iot-api-key value>"
//   k6 run loadtest/ingest.js
//
// Options (environment variables, all optional):
//   PROFILE = smoke | ramp   (default smoke: 1 request per second for 30 s, a check that the script works)
//   PEAK    = peak requests per second for the ramp profile (default 20)
//
// Each request makes Laravel validate the reading, save it, call flask-ml (10 s
// timeout), store the prediction and broadcast two Pusher events. Expect the
// single 0.5 vCPU web replica to saturate: where it does is the useful result.

import http from "k6/http";
import { check } from "k6";
import { Counter } from "k6/metrics";

// Seeded hive ids and their active node identifiers. Not secrets.
const HIVES = [
  { hive_id: 1, device_id: "NODE-28ZRUR" },
  { hive_id: 2, device_id: "NODE-CQM9GE" },
  { hive_id: 3, device_id: "NODE-EMXCNZ" },
  { hive_id: 4, device_id: "NODE-FAI92N" },
  { hive_id: 5, device_id: "NODE-DVUFUP" },
  { hive_id: 6, device_id: "NODE-R1RAMP" },
  { hive_id: 7, device_id: "NODE-POOVAN" },
  { hive_id: 8, device_id: "NODE-74CNHZ" },
];

const BASE = (__ENV.BUZZYHIVE_URL || "").replace(/\/$/, "");
const KEY = __ENV.BUZZYHIVE_API_KEY || "";
const PEAK = parseInt(__ENV.PEAK || "20", 10);

const mlUnavailable = new Counter("ml_unavailable"); // 201 but the model call failed

const profiles = {
  smoke: {
    smoke: {
      executor: "constant-arrival-rate",
      rate: 1,
      timeUnit: "1s",
      duration: "30s",
      preAllocatedVUs: 5,
      maxVUs: 20,
    },
  },
  ramp: {
    ramp: {
      executor: "ramping-arrival-rate",
      startRate: 1,
      timeUnit: "1s",
      preAllocatedVUs: 20,
      maxVUs: 200,
      stages: [
        { target: Math.max(2, Math.round(PEAK / 4)), duration: "1m" },
        { target: Math.max(4, Math.round(PEAK / 2)), duration: "2m" },
        { target: PEAK, duration: "3m" },
        { target: PEAK, duration: "2m" }, // hold at the peak
        { target: 0, duration: "30s" },
      ],
    },
  },
};

export const options = {
  scenarios: profiles[__ENV.PROFILE || "smoke"],
  thresholds: {
    // NFR-PERF-01 in the app: p95 under 500 ms. Errors under 1%.
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<500"],
    checks: ["rate>0.99"],
    ml_unavailable: ["count==0"],
  },
};

export function setup() {
  if (!BASE || !KEY) {
    throw new Error("Set BUZZYHIVE_URL and BUZZYHIVE_API_KEY first.");
  }
}

function jitter(centre, spread) {
  return centre + (Math.random() * 2 - 1) * spread;
}

// Same baseline as scripts/simulate_sensor.py. It classifies as not_ready, so it
// queues no Telegram alert and the test does not spam the bot.
function reading() {
  return {
    temp: Math.round(jitter(33.5, 1.0) * 10) / 10,
    humidity: Math.round(jitter(70.0, 3.0) * 10) / 10,
    mq2_value: Math.round(jitter(250, 20)),
    mq3_value: Math.round(jitter(200, 20)),
    mq5_value: Math.round(jitter(180, 20)),
    mq135_value: Math.round(jitter(220, 20)),
  };
}

export default function () {
  const hive = HIVES[Math.floor(Math.random() * HIVES.length)];
  const body = JSON.stringify({ device_id: hive.device_id, hive_id: hive.hive_id, ...reading() });

  const res = http.post(`${BASE}/api/sensor-data`, body, {
    headers: { "Content-Type": "application/json", Accept: "application/json", "X-API-Key": KEY },
    timeout: "15s",
    tags: { name: "POST /api/sensor-data" },
  });

  check(res, { "status is 201": (r) => r.status === 201 });

  if (res.status === 201 && res.body && res.body.indexOf("ml_unavailable") !== -1) {
    mlUnavailable.add(1);
  }
}
