# Architecture

This article explains the resources this project plans to deploy and why each one exists. It hosts [BuzzyHive 2.0](https://github.com/tttaufiqqq/Kelulut-Hive-Harvest-Readiness-Prediction), which today runs on Exabytes shared hosting.

## 1. From shared hosting to containers

BuzzyHive is a Laravel 13 + React app backed by MySQL, plus a Flask KNN API that returns a harvest readiness prediction. Live updates go through Pusher and alerts go to Telegram.

The current setup has limits that motivate the move:

- `composer install` is not automated on shared hosting, so a changed `composer.lock` blocks the deploy.
- The Flask API runs under Passenger on the same host, with no isolation or scaling.
- Sensors post HTTP directly to the app, with no managed device ingestion.

Containers fix the first two, and IoT Hub adds a managed ingestion path for the third.

## 2. Data flow

<img src="architecture/network-and-runtime.png" alt="Azure architecture page 1: network and runtime, with numbered steps 1 to 13" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Page 1. The numbered circles match the steps below.*

| Step | What happens |
|---|---|
| 1 | The ESP32 (or a Python simulator) publishes a reading to IoT Hub over MQTT with TLS, using its own device key |
| 2 | An Azure Function fires on every IoT Hub message |
| 3 | The Function POSTs the reading to `/api/sensor-data` on `laravel-web`, with the API key |
| 4 | The browser reaches `laravel-web` over HTTPS, optionally through Front Door Standard |
| 5 | Laravel calls `flask-ml` on its internal ingress and gets the KNN prediction |
| 6 | Laravel reads and writes MySQL inside the VNet |
| 7 | `laravel-worker` polls the queue table and runs alert jobs |
| 8 | Laravel broadcasts live events to Pusher, which pushes them to the browser |
| 9 | The worker sends Ready and Nearly Ready alerts to Telegram |
| 10 | Apps reach Key Vault and Storage only through private endpoints |
| 11 | Diagnostic settings send logs, metrics and traces to Log Analytics and Application Insights |
| 12 | GitHub Actions builds images, pushes to ACR and deploys using OIDC |
| 13 | Azure ML retrains the KNN model and registers it, and the pipeline rebuilds the `flask-ml` image |

## 3. Resources

| Resource | Notes |
|---|---|
| Azure IoT Hub | Free tier allows 8,000 messages per day and one hub per subscription; S1 if needed |
| Azure Function | IoT Hub trigger on the built-in Event Hub-compatible endpoint; sits outside the VNet and calls the public `laravel-web` ingress with the API key |
| Virtual network `vnet-hive` (10.0.0.0/16) | Three subnets, listed in [Network](#4-network) |
| Container Apps environment | Consumption plan only, in `snet-aca` |
| `laravel-web` | External ingress, scales on HTTP |
| `laravel-worker` | Queue worker, `min_replicas = 1` so alerts are not delayed by a cold start |
| `flask-ml` | Internal ingress only, model and scaler baked into the image |
| Container Apps Jobs | `schedule:run` on a cron trigger, `migrate` on each deploy |
| MySQL Flexible Server, Burstable B1ms | Delegated subnet, private access, TLS |
| Key Vault | Secrets, read through a private endpoint with a managed identity |
| Storage account (private) | Laravel files, reached through a private endpoint |
| Storage account (public) | Function state and the ML workspace. A Functions Consumption plan generally cannot use storage behind a private endpoint, so this one has no private endpoint |
| Container Registry, Basic | Three images, pulled with the managed identity (`AcrPull`) |
| Azure Machine Learning workspace | Training only; the compute cluster has `min_nodes = 0` |
| Log Analytics and Application Insights | Shared workspace for all diagnostics |
| Front Door Standard (optional) | Edge routing; managed WAF rules need Premium |

## 4. Network

| Subnet | Range | Purpose |
|---|---|---|
| `snet-aca` | 10.0.0.0/23 | Container Apps environment |
| `snet-pe` | 10.0.2.0/24 | Private endpoints for Key Vault and Storage |
| `snet-mysql` | 10.0.4.0/28 | MySQL Flexible Server, delegated to `Microsoft.DBforMySQL/flexibleServers` |

Each subnet has an NSG. Three private DNS zones are linked to the VNet:

- `privatelink.vaultcore.azure.net` for Key Vault
- `privatelink.blob.core.windows.net` for Storage
- `privatelink.mysql.database.azure.com` for MySQL, which the delegated subnet needs in place of a private endpoint

IoT Hub, the Function and Azure ML are managed PaaS outside the VNet. The Function reaches Laravel over its public ingress, protected by the API key.

## 5. Governance, identity and operations

<img src="architecture/governance-and-devops.png" alt="Azure architecture page 2: governance, identity, DevOps and operations" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Page 2. Governance applies to the subscription, identity grants access to the resource group, and the pipeline deploys into it.*

| Area | What it contains |
|---|---|
| Governance | Azure Policy (allowed regions, required tags, in audit mode so it never blocks an apply), resource locks, tags `env=lab` and `project=buzzyhive`, a budget with alerts at 75% and 90% of $100 (below the $135.68 credit left), and Defender for Cloud on the free tier |
| Identity | Entra groups `grp-hive-admins` and `grp-hive-readers`, a user-assigned managed identity for the apps, and an app registration with a GitHub OIDC federated credential |
| DevOps | GitHub repository, GitHub Actions, Terraform with plan before apply, and a storage account holding state in `rg-hive-iac` |
| Operations | Log Analytics, Application Insights, alert rules (no data for 15 minutes, 5xx responses, database CPU), Activity Log, MySQL automated backups, and optional Azure Load Testing |

Role assignments:

- **Pipeline identity:** `Contributor` plus `Role Based Access Control Administrator`, because `Contributor` cannot create role assignments and Terraform needs to create them.
- **Managed identity:** `AcrPull` on the registry and `Key Vault Secrets User` on the vault.
- **Readers group:** `Reader` on the resource group.

## 6. Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Compute | Container Apps, consumption plan | Scales to zero, no cluster to manage, no fixed cost. A dedicated workload profile costs about $140 per month. |
| Scheduler and migrations | Container Apps Jobs, not inside the worker | A worker replica should only process the queue. Running `schedule:run` or `migrate` in every replica would repeat them. |
| Laravel state | `SESSION_DRIVER=database`, `CACHE_STORE=database`, `TRUSTED_PROXIES=*`, `LOG_CHANNEL=stderr` | Any replica can serve any request, URLs are https behind ingress, and logs reach Log Analytics |
| Uploads | Container disk in the lab, one web replica | The app saves hive images and the thesis PDF to `storage/app/public`. They are lost on restart. The durable fix is an Azure Files mount or a Blob disk. |
| Images | One Laravel image for every role, one ML image. See [Docker images](docker.md) | One build, one registry entry, and one thing to scan |
| Device | Python simulator for the lab | The real ESP32 firmware posts HTTP with an API key. IoT Hub needs a device identity (SAS or X.509) and an SDK. |
| Database access | Delegated subnet with private DNS | MySQL Flexible Server in private access cannot also be public |
| Secrets | Key Vault through a private endpoint and a managed identity | No secrets in images or pipeline variables |
| IaC | Terraform with `azurerm`, plus `azapi` where needed | `azurerm` covers Container Apps, Jobs and ML. `azapi` is for control-plane-only writes such as Key Vault secrets and file shares. |
| Private data planes | Write secrets and shares through ARM with `azapi` | With public access off, a laptop or GitHub runner outside the VNet gets 403 on the data plane |
| Storage accounts | One private, one public | The Function and ML workspace need a reachable account |
| Soft delete | Purge Key Vault and ML workspace on destroy, add random name suffixes | Soft-deleted names block recreating the same name the next day |
| Terraform roots | `bootstrap` (state, local), `foundation` (governance, identity), `lab` (network, data, workloads) | Only `lab` is destroyed after each session. Fewer state files than four separate stacks. |
| Locks | Behind a variable, off in the lab | A `CanNotDelete` lock makes `terraform destroy` fail, so keep locks in the `foundation` root |
| ML serving | Keep `flask-ml` in Container Apps, use Azure ML for training | A managed online endpoint bills all the time and a KNN on small data does not need it |
| Region | Malaysia West, with the IoT Hub in Southeast Asia | The provider list for `Microsoft.Devices` has no Malaysia West, so the IoT Hub goes to the nearest region that has it. It sits outside the VNet and devices reach it over the internet, so the split costs only a little cross-region traffic. The other services were listed for Malaysia West. Check MySQL and ML vCPU quota first. Malaysia West is also where the reference project ran, while Southeast Asia had VM capacity limits on the same account. |

## 7. What stays outside Azure

- **Pusher** delivers live events over WebSocket. Replacing it with Azure Web PubSub is possible but needs changes to Laravel Echo, so it is out of scope.
- **Telegram** receives alert calls over outbound HTTPS. A NAT Gateway would give a fixed egress IP but is optional.
- **GitHub** hosts the code and runs the pipeline, reaching Azure through OIDC.

Edit the diagrams in [`architecture/architecture.drawio`](architecture/architecture.drawio) and export the PNGs again after any change.
