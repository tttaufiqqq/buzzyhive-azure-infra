# BuzzyHive on Azure: containers, IoT and ML (Terraform)

This is a learning project. It designs how to run [BuzzyHive 2.0](https://github.com/tttaufiqqq/Kelulut-Hive-Harvest-Readiness-Prediction), a kelulut (stingless bee) harvest readiness platform, on Azure with Docker containers and Terraform, using services such as Azure IoT Hub, Container Apps and Azure Machine Learning.

> [!NOTE]
> This is a personal learning design. It is not official Microsoft guidance. The architecture is drawn and documented, and the Terraform is scaffolded and passes `terraform validate`, but **nothing has been applied to Azure yet**, so this repository has no measured results. Costs and problems in these docs are estimates and expectations, and each one is labelled that way.

<img src="docs/architecture/network-and-runtime.png" alt="Azure architecture page 1: ESP32 or simulator to IoT Hub to Function to Container Apps (laravel-web, flask-ml, worker, Jobs) with MySQL, private endpoints, Key Vault, a private and a public Storage account, ACR, Azure ML and monitoring" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Page 1, network and runtime: how a sensor reading travels from the ESP32 to the dashboard. Source: [`docs/architecture/architecture.drawio`](docs/architecture/architecture.drawio).*

## Summary

- **Goal:** move BuzzyHive from Exabytes shared hosting to containers on Azure, and learn IoT Hub, Container Apps, Azure ML, private networking, governance and CI/CD with OIDC on the way.
- **Approach:** three container apps (`laravel-web`, `laravel-worker`, `flask-ml`) in a VNet, MySQL Flexible Server on a private subnet, IoT Hub with a Function in front of Laravel, and Azure ML for training. Everything is defined in Terraform and deployed from GitHub Actions.
- **Run time:** the environment is meant to run for about a day, then be destroyed.

## Status

| Part | State |
|---|---|
| Architecture diagram and documentation | Done |
| Terraform (`bootstrap`, `foundation`, `lab`) | Scaffolded. `validate` passes and CI (fmt, validate, tflint) is green |
| Preflight against a real subscription | Passed (providers, MySQL SKU, quota, IoT Hub region) |
| Docker images and local Compose stack | Built and tested end to end. 168 app tests pass |
| Apply to Azure | **Not run yet** |
| IoT Hub forwarder function, CI plan and apply | Not written yet |

What was found along the way, and what is still open, is in the [implementation log](docs/implementation-log.md).

## 1. Learning goals

- Containerize a Laravel + React app and a Flask ML API, and run them on Azure Container Apps.
- Ingest device data through Azure IoT Hub and an Azure Function.
- Train and register a model with Azure Machine Learning, then rebuild the serving image from it.
- Keep data private with a VNet, a delegated MySQL subnet, private endpoints and private DNS.
- Apply governance (Policy, tags, budget, locks, RBAC) and deploy with Terraform and GitHub OIDC, with no stored secrets.

## 2. What this deploys

| Resource | Purpose |
|---|---|
| IoT Hub (free tier), Azure Function | Receives ESP32 readings over MQTT and forwards them to Laravel |
| Container Apps environment: `laravel-web`, `laravel-worker`, `flask-ml`, plus Jobs | Runs the web app, queue worker, ML API, scheduler and migrations |
| MySQL Flexible Server (Burstable B1ms) in a delegated subnet | Application database, no public endpoint |
| Key Vault, two Storage accounts (one private), private endpoints, private DNS zones | Secrets and Laravel files reached only over Private Link; the Function and ML use the public account |
| Container Registry (Basic) | Holds the three images |
| Azure Machine Learning workspace | Trains the KNN model and registers it |
| Log Analytics, Application Insights, alert rules | Logs, traces and alerts |
| Governance: Policy, tags, budget, locks, Defender free tier | Subscription-scope guardrails |
| Entra groups, managed identity, GitHub OIDC app registration | Access without passwords |
| Optional: Front Door Standard, Azure Load Testing | Edge routing and a load test |

The two container images (Laravel on FrankenPHP and Alpine, 333 MB; flask-ml on Python slim, 452 MB) are built and tested locally with Docker Compose. Why they are built that way, with measurements: [Docker images](docs/docker.md).

<img src="docs/architecture/governance-and-devops.png" alt="Azure architecture page 2: governance, identity and access, DevOps and infrastructure as code, operations and resilience around the resource group" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Page 2, governance, identity, DevOps and operations around `rg-hive-lab`.*

For a full explanation, see [Architecture](docs/architecture.md).

### Limitations

- **Scaffolded, not applied.** The three Terraform roots validate, but none of the steps in [Deploy](docs/deploy.md) have been run, so the first apply will likely turn up provider or quota errors.
- **Synthetic ML data.** The KNN model is trained on a synthetic dataset, so Azure ML here is a pipeline exercise, not a modelling one.
- **No Function code.** The Function app can be created (`enable_function`), but the function that forwards IoT Hub messages to Laravel is not written yet, so the IoT Hub path is incomplete. It is off by default.
- **Simulated device.** The real ESP32 firmware posts plain HTTP with an API key. Talking to IoT Hub needs firmware changes, so the lab uses a Python device simulator.
- **One environment.** There is a single `rg-hive-lab` group with no separate dev or staging.
- **Pusher and Telegram stay external.** They are SaaS and are called over outbound HTTPS.

### Cost

- **Estimate, not measured:** about US$50 to 70 per month if everything is left running, so well under $5 for a one-day lab. The drivers are MySQL B1ms, the always-on worker, two private endpoints and the registry.
- **What can break the budget:** Front Door Premium (WAF managed rules, about $330 per month) and a dedicated Container Apps workload profile (about $140 per month). Neither is in the plan.
- **Credit:** $135.68 remaining at the time of writing, so a one-day run uses only a small part of it. Check the expiry date under Cost Management, then Credits.
- **Keep it low:** destroy the `lab` root when you finish. See [Cost and teardown](docs/cost-and-teardown.md).

## 3. Prerequisites

- An Azure subscription (the free account has a $200 credit for 30 days; $135.68 was left when this was written)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- Azure CLI, Docker, and Git
- Rights to create Entra groups and app registrations in your tenant
- The [BuzzyHive repository](https://github.com/tttaufiqqq/Kelulut-Hive-Harvest-Readiness-Prediction) for the application code and `ml/` folder

## 4. Planned build order

1. Preflight (register resource providers, check quota), then subscription, tags, policy and budget
2. Entra groups and RBAC
3. Terraform state storage and the GitHub OIDC pipeline
4. Network, MySQL, Key Vault, Storage, ACR
5. Container Apps, IoT Hub and Function
6. Monitoring and alerts
7. Azure ML and the optional load test

The commands for each root are in [Deploy, redeploy, and destroy](docs/deploy.md).

> [!WARNING]
> MySQL, the registry and private endpoints bill hourly even with no traffic. Destroy the environment when you finish. See [Cost and teardown](docs/cost-and-teardown.md).

## 5. Design decisions at a glance

| Choice | Reason |
|---|---|
| Container Apps, consumption plan only | Scale to zero, no cluster to run, and no fixed workload-profile cost |
| `schedule:run` and `migrate` as Container Apps Jobs | A worker replica should not run migrations or the scheduler, and several replicas would run them twice |
| Terraform with `azurerm`, plus `azapi` where needed | `azurerm` covers most services. `azapi` writes Key Vault secrets and storage shares through ARM, because private data planes return 403 from outside the VNet |
| Three Terraform roots: `bootstrap`, `foundation`, `lab` | Only `lab` is destroyed after each session, with fewer state files than separate stacks |
| Locks behind a variable, off in the lab | A `CanNotDelete` lock makes `terraform destroy` fail |
| Python simulator in place of the ESP32 | No firmware change, same IoT Hub path |
| Database sessions and cache | Any replica can serve any request |

The reasoning behind each is in [Architecture](docs/architecture.md#6-design-decisions).

## 6. Results so far

Nothing has run on Azure yet. These come from local builds, CI and read-only commands against the subscription. Measured on one laptop (Docker 29.7 in WSL2), one run each.

| Check | Result |
|---|---|
| Laravel image | 333 MB on Alpine (a Debian build is 900 MB) |
| ML image | 452 MB (533 MB before removing bundled test folders) |
| Alpine against Debian, 0.5 CPU | `/up` 77.5 against 88.9 requests per second, `/login` 32.2 against 35.7, memory 51 MB for both |
| Local stack | MySQL, flask-ml, migrate, web, worker and scheduler run end to end. A sensor POST returns 201 in 0.16 s warm |
| App tests with the changed code | 168 passed, 842 assertions |
| CI on the first push | `fmt`, `validate` and `tflint` green for all three roots |
| Preflight on the real subscription | Providers registered, MySQL B1ms offered in Malaysia West, 4 vCPU quota, IoT Hub listed for Southeast Asia |

Why the images are built this way: [Docker images](docs/docker.md). The full list of 13 problems found before deploying, and how each was found: [Implementation log](docs/implementation-log.md#4-problems-found-before-deployment).

## 7. What I learned

- **Run it before reasoning about it.** Building the images exposed problems a design review had missed: a MySQL trigger that needs a server parameter, Pusher values that must exist at build time, and an app that does not trust proxies.
- **Check an assumption before it reaches a diagram.** "Malaysia West has fewer services" sat in the docs until a one-line provider query disproved it. Only the IoT Hub is missing there.
- **Test the checking tools.** The preflight script had two bugs that only showed against the real subscription.
- **Measure the choices you can.** Alpine saved 567 MB for about 10 to 13 percent less throughput on the web image, and failed outright for the ML image because the numeric packages have no musl wheels.
- **Private data planes break Terraform.** With public access off, secrets and file shares fail with 403 from outside the VNet, so those writes go through ARM with `azapi`. This is from review and not yet confirmed on Azure.

## 8. Related resources

- [BuzzyHive 2.0](https://github.com/tttaufiqqq/Kelulut-Hive-Harvest-Readiness-Prediction): the application this infrastructure hosts
- [Azure Container Apps documentation](https://learn.microsoft.com/en-us/azure/container-apps/)
- [Azure IoT Hub documentation](https://learn.microsoft.com/en-us/azure/iot-hub/)
- [Azure Machine Learning documentation](https://learn.microsoft.com/en-us/azure/machine-learning/)
- [Docs index](docs/README.md): Architecture, Deploy, Implementation log, Troubleshooting and Cost, in the order to read them
