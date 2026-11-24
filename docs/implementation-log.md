# Implementation log

This log records how the infrastructure was planned, deployed, and fixed. It lists what happened, what failed, and why each decision was made.

> [!NOTE]
> The design, the Terraform scaffold and the Docker images are done and checked locally and in CI. A read-only preflight has been run against the real subscription. Nothing has been applied to Azure yet, so the apply entries below are left to fill in.

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
| Region | Malaysia West, IoT Hub in Southeast Asia | `az provider show -n Microsoft.Devices` lists no Malaysia West for IoT Hubs. An earlier draft chose Southeast Asia on an unchecked assumption that Malaysia West had fewer services |
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
| 2026-11-24 | Region changed after checking the `Microsoft.Devices` provider list | Malaysia West for everything except the IoT Hub, which has no Malaysia West and goes to Southeast Asia |
| 2026-11-24 | Terraform scaffolded: `bootstrap`, `foundation`, `lab`, `scripts/preflight.sh`, CI workflow | `terraform fmt` and `validate` pass. Not planned or applied. |
| 2026-11-24 | First push to GitHub triggered CI | `terraform fmt -check`, `validate` and `tflint` passed for all three roots (4 jobs, 17 seconds) |
| 2026-11-24 | App test suite run in a throwaway container against the changed app code | 168 tests, 842 assertions, all pass |
| 2026-11-24 | `scripts/preflight.sh` run against the real Free Trial subscription | Providers registered, MySQL B1ms offered in Malaysia West, quota 4 vCPUs (4 for DSv2), IoT Hub listed for Southeast Asia. Two checks had bugs of their own (see section 4), fixed and re-run clean |
| | Root 1: bootstrap, first apply | Not started |
| | Root 2: foundation, first apply | Not started |
| | Root 3: lab, first apply | Not started |
| | Azure ML training run | Not started |

## 4. Problems found before deployment

Found before any resource existed in Azure, mostly by building and running the images. "Running" means reproduced. "Code read" means found by reading the app, then confirmed or fixed in a build. "Review" means reasoned from documented behaviour and not yet confirmed. Entries with a troubleshooting number have a symptom-to-fix write-up.

| Problem | Found by | Effect if missed | Fix |
|---|---|---|---|
| The migrations create a MySQL trigger. MySQL refuses it for a non-SUPER user when binary logging is on (error 1419) | Running (Compose) | The migrate Job fails on Azure the same way, because Flexible Server keeps binary logging on | Compose flag, and `log_bin_trust_function_creators` in `lab/data.tf` (troubleshooting 21) |
| `VITE_PUSHER_*` is compiled into the JavaScript at build time | Code read, confirmed in the build | Live updates silently stop in the browser | Docker build arguments (troubleshooting 16) |
| The app reads `ML_URL`, but the Terraform and four lines of the app docs said `ML_API_URL` | Code read | Laravel would never reach the ML API | Fixed in both repos |
| The app does not trust proxies | Running, before and after | Behind the ingress a redirect went to `http://localhost:8080/login`. With the fix it went to `https://...` | Env-gated `TRUSTED_PROXIES` in `bootstrap/app.php` (troubleshooting 17) |
| Hive images and the thesis PDF are written to local disk | Code read | Uploads are lost on restart and not shared between replicas | One web replica in the lab. Durable storage not built (troubleshooting 18) |
| The Vite build needs PHP, not only Node | Running | A Node-only build stage fails | The asset stage has both |
| The region was chosen on an unchecked assumption that Malaysia West has fewer services | Running a provider query, plus the reference project's history | Wrong region for a reason that was never tested | Malaysia West, with only the IoT Hub, which is not offered there, in Southeast Asia |
| The Alpine base fails for the ML image | Running | pip tries to compile numpy and scipy and fails | `python:3.12-slim` |
| The preflight said "IoT Hub not listed" for a region that does list it, and its MySQL check errored | Running it on the real subscription | A false blocker and a check that told nothing | Names compared without spaces or case, and a plain text search for the SKU |
| Private Key Vault and Storage return 403 to Terraform from outside the VNet | Review | Secrets and shares fail to create | `azapi` writes through ARM (troubleshooting 11) |
| Terraform state with Azure AD auth needs a data-plane role that Owner does not include | Review | The first `init` in the next root fails with 403 | `bootstrap` assigns the role |
| A placeholder image never exits, so a per-minute Job would pile up runs | Review | Runaway executions and cost | Jobs are created only once real images are set |
| A Functions Consumption plan generally cannot use storage behind a private endpoint | Review, from memory | The Function fails to start | A separate public storage account (troubleshooting 15) |

## 5. Open questions

- Does MySQL B1ms have free capacity in Malaysia West right now? The preflight shows it is offered, which does not prove capacity.
- Is 4 vCPUs of DSv2 enough? One `Standard_DS3_v2` training node uses all of it.
- Do budgets work on a Free Trial subscription? (`enable_budget` is the fallback.)
- Can the tenant create Entra groups and app registrations with Terraform?
- Is the Function better placed in the VNet (Flex Consumption) so it can call an internal ingress?

## 6. Lessons

- **Run it before reasoning about it.** Building and running the images exposed several problems that a design review had missed, such as the MySQL trigger, the build-time Pusher values and the missing proxy trust.
- **Check an assumption before writing it into a diagram.** The region claim sat in the diagram and the docs until a one-line provider query disproved it.
- **Test the checking tools too.** Both preflight checks had bugs that only showed against the real subscription, and one produced a false blocker.
- **Measure what can be measured.** The Alpine choice rests on a size and throughput comparison. The ML base choice rests on a failed build, not on a guess.
- **Document an app's needs in the app.** The findings above are properties of the code, so they live in the app repository and this one links to them.

More lessons go here once something has been applied and has broken.

Symptom-to-fix reference for expected problems: [Troubleshooting](troubleshooting.md).
