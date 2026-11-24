# Implementation log

This log records how the infrastructure was planned, deployed, and fixed. It lists what happened, what failed, and why each decision was made.

> [!NOTE]
> The design and the Terraform scaffold are done, and `terraform validate` passes in all three roots. Nothing has been applied yet, so the apply entries below are left to fill in.

## 1. Goal

Host [BuzzyHive 2.0](https://github.com/tttaufiqqq/Kelulut-Hive-Harvest-Readiness-Prediction) on Azure as a learning project. The requirements were:

- Containerize the Laravel app and the Flask ML API.
- Use Azure IoT Hub, Container Apps and Azure Machine Learning.
- Define everything in Terraform so the environment can be destroyed and recreated at any time.
- Use the free account credit, and run the environment for about a day.

## 2. Decisions

| Decision | Choice | Reason |
|---|---|---|
| Compute | Container Apps, consumption plan | Scales to zero and has no fixed cost |
| Scheduler and migrations | Container Apps Jobs | Replicas would otherwise run them more than once |
| Device | Python simulator | The ESP32 firmware does not speak IoT Hub |
| IaC tool | Terraform with `azurerm`, plus `azapi` where needed | `azurerm` covers most services; `azapi` writes to private data planes through ARM |
| Terraform roots | bootstrap, foundation, lab | Only `lab` is destroyed. Fewer state files than four stacks. |
| Storage | Two accounts, one private | The Function and ML workspace need a reachable account |
| Resource group | `rg-hive-lab` | `rg-hive-prod` contradicted the `env=lab` tag |
| Policy effect | Audit, not deny | Deny can block the apply for resources Azure creates itself |
| Budget | $100 | Credit remaining is $135.68 |
| Laravel runtime | FrankenPHP in classic mode, Debian, non-root | One process per container, no supervisor. Details in [Docker images](docker.md) |
| ML runtime | `python:3.12-slim`, gunicorn, serving requirements only | No training stack in the image. scikit-learn pinned to match the pickle |
| Config cache | At container start, not at build | Secrets from Key Vault must not be baked into the image |
| Container command | `args`, not `command`, in Terraform | `command` would replace the entrypoint that caches the config |
| Uploads | Container disk, one web replica | Durable storage is a later change; see troubleshooting 18 |
| Laravel base image | Alpine, not Debian | Measured: 333 MB against 900 MB, for about 10 to 13% less throughput |
| ML base image | `python:3.12-slim`, not Alpine | The Alpine build failed: no musl wheel, so pip tried to compile |
| MySQL parameter | `log_bin_trust_function_creators = ON` | The migrations create a trigger, which failed locally with error 1419 |
| Locks | Behind `enable_locks`, off in the lab | Locks block `terraform destroy` |
| Pipeline roles | Contributor plus RBAC Administrator | Contributor cannot create role assignments |
| Region | Southeast Asia | More services than Malaysia West |
| Edge | Front Door Standard, optional | WAF managed rules need Premium at about $330 per month |

## 3. Timeline

| Date | Step | Outcome |
|---|---|---|
| 2026-11-22 | First architecture drawn in draw.io, two pages | Network and runtime, then governance and DevOps |
| 2026-11-24 | Design reviewed against free-account limits and Azure behaviour | Added Jobs for the scheduler and migrations, the MySQL private DNS zone, a device simulator, lock toggle, and RBAC Administrator role |
| 2026-11-24 | Design compared with the reference Terraform project | Split the storage accounts, three roots, soft-delete purge, preflight script, audit-mode Policy, `rg-hive-lab`, $100 budget |
| 2026-11-24 | Documentation written | This repository |
| 2026-11-24 | Dockerfiles, compose file and `.dockerignore` written in the app repository | Found while doing it: the `ML_URL` name was wrong in Terraform, `VITE_PUSHER_*` must be build arguments, `TRUSTED_PROXIES` was needed, and uploads use local disk |
| 2026-11-24 | Both images built and run with Docker Compose in WSL2 | Whole stack works end to end. The migrate step failed on a trigger until `log_bin_trust_function_creators` was set. See [Docker images](docker.md) for sizes and the Alpine comparison |
| 2026-11-24 | Terraform scaffolded: `bootstrap`, `foundation`, `lab`, `scripts/preflight.sh`, CI workflow | `terraform fmt` and `validate` pass. Not planned or applied. |
| | Root 1: bootstrap, first apply | Not started |
| | Root 2: foundation, first apply | Not started |
| | Root 3: lab, first apply | Not started |
| | Azure ML training run | Not started |

## 4. Open questions

- Does MySQL B1ms have capacity in Southeast Asia for this subscription?
- Is the Azure ML compute quota for the chosen VM family above zero?
- Can the tenant create Entra groups and app registrations with Terraform?
- Is the Function better placed in the VNet (Flex Consumption) so it can call an internal ingress?

## 5. Lessons

None yet. Add each lesson here with the problem that taught it, once something has been built and has broken.

Symptom-to-fix reference for expected problems: [Troubleshooting](troubleshooting.md).
