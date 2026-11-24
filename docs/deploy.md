# Deploy, redeploy, and destroy

This article shows the planned steps to deploy the infrastructure, change it, and delete it.

> [!NOTE]
> The Terraform is scaffolded and passes `terraform validate` in all three roots, but it has not been applied to Azure. Expect provider, quota and naming errors on the first apply, and update this article with what actually happens.

## 1. Before you begin

- Sign in with `az login`, and select your subscription with `az account set --subscription "<name>"`.
- Run the preflight script (planned: `scripts/preflight.sh`). It should do three things:
  - Register the resource providers a new subscription often lacks: `Microsoft.App`, `Microsoft.Devices`, `Microsoft.DBforMySQL`, `Microsoft.MachineLearningServices`, `Microsoft.OperationalInsights` and `Microsoft.Cdn`.
  - Check quota with `az vm list-usage --location malaysiawest -o table`.
  - Confirm MySQL B1ms is offered with `az mysql flexible-server list-skus --location malaysiawest -o table`.
- Check that you can create Entra groups and app registrations in your tenant. A university tenant may block this.
- Check your remaining credit and its expiry date in Cost Management, then Credits ($135.68 when this was written).
- Build the app images locally first (see [Build the images](#3-build-the-images)).

## 2. Planned layout

```
buzzyhive-azure-infra/
├── docs/
├── bootstrap/          # state storage account (rg-hive-iac), local state
├── foundation/         # governance (Policy, tags, budget, Defender, locks toggle) + identity (Entra, managed identity, GitHub OIDC)
├── lab/                # network, MySQL, Key Vault, Storage, ACR, Container Apps, Jobs, IoT Hub, Function, Azure ML
├── scripts/            # preflight.sh (device simulator and smoke test still to write)
└── .github/workflows/  # terraform.yml: fmt, validate and tflint on every root
```

Each root is a flat set of `.tf` files. Pull a block into `modules/` only when something is reused. Three roots, not four stacks: only `lab` is destroyed after each session, so governance and identity share one root and one state file.

- **`bootstrap`** keeps its state locally, because it creates the storage account the other roots use for remote state.
- **`foundation` and `lab`** use the `azurerm` backend in `rg-hive-iac`, authenticated with OIDC.
- **Provider settings for the lab:** purge soft-deleted Key Vaults and ML workspaces on destroy, and add a random suffix to globally unique names (ACR, Key Vault, storage, Function). Otherwise recreating the same name the next day fails.
- **Private data planes:** the lab writes Key Vault secrets and file shares through ARM with `azapi`, because a laptop or runner outside the VNet gets 403 from a private data plane.

## 3. Build the images

The Docker files live in the application repository, because they build the app, and its `docs/docker/docker.md` lists what the app needs from its host. Why each image is built the way it is: [Docker images](docker.md).

| Image | Build | Role |
|---|---|---|
| `laravel` | `docker build -t buzzyhive/laravel:local .` | Web (default), worker, scheduler and migrate. Only the command changes |
| `flask-ml` | `docker build -t buzzyhive/flask-ml:local ml` | The KNN API, served by gunicorn |

Run the whole stack locally first, from WSL or any Docker host:

```bash
cp .env.docker.example .env.docker      # set APP_KEY: docker compose run --rm --no-deps app php artisan key:generate --show
docker compose up --build               # app on http://localhost:8080
```

The Pusher key and cluster are compiled into the JavaScript, so they are build arguments (`VITE_PUSHER_APP_KEY`, `VITE_PUSHER_APP_CLUSTER`), not runtime settings. Push to ACR with `az acr build` (no local Docker needed) or `docker push`.

## 4. Deploy

Run these in order. Each step says what to check before moving on, and what usually goes wrong.

### 4.1 Preflight

```bash
az login
az account set --subscription "<name>"
scripts/preflight.sh malaysiawest southeastasia
```

Run it again until every resource provider says `ok` (registration takes a few minutes). A quota or SKU line showing `0` or no result means that feature will fail. Switch it off with an `enable_*` variable, or request quota.

### 4.2 bootstrap (state storage)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars      # set subscription_id
terraform init && terraform plan
terraform apply
terraform output -raw backend_hcl
```

It also gives your signed-in user `Storage Blob Data Contributor` on the state account. The other roots read state with Azure AD auth, and Owner or Contributor alone cannot. The assignment can take several minutes to take effect, so `terraform init` in the next step may fail with a 403 at first. Wait and retry.

### 4.3 foundation (resource group, governance, identity)

```bash
cd ../foundation
cp terraform.tfvars.example terraform.tfvars      # set alert_emails, budget_start_date, github_owner, github_repo
cp backend.hcl.example backend.hcl                # paste the bootstrap output, keep key = "foundation.tfstate"
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

- `budget_start_date` must be the first day of a month, for example `2026-11-01T00:00:00Z`. If the apply says budgets are not supported on your subscription type, set `enable_budget = false` ([troubleshooting](troubleshooting.md#22-the-budget-cannot-be-created)).
- Entra groups and the app registration need directory rights. If the plan fails on `azuread`, see [troubleshooting](troubleshooting.md#5-entra-groups-or-app-registration-cannot-be-created).
- Save the three outputs as GitHub repository variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`). Nothing uses them until a plan or apply job is added to the workflow.

### 4.4 lab, first apply (placeholder images)

```bash
cd ../lab
cp terraform.tfvars.example terraform.tfvars      # set subscription_id, alert_email
cp backend.hcl.example backend.hcl                # key = "lab.tfstate"
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

With `images` unset, the apps run Microsoft's quickstart image, so the platform can be checked before the real images exist. The scheduler and migrate Jobs are not created yet, because the placeholder never exits.

Expected duration: MySQL and the Container Apps environment are the slow parts. I have no measurement; record yours in the [implementation log](implementation-log.md).

Things that commonly fail here, and the fix:

- **A Container App cannot read a Key Vault secret** right after the role assignment. Role assignments take minutes to propagate. Re-run `terraform apply`.
- **IoT Hub free tier already exists.** Only one `F1` hub is allowed per subscription. Set `enable_iot = false` or delete the other hub.
- **A SKU or quota error** on MySQL. Check the preflight output, change region or request quota.

### 4.5 lab, second apply (real images)

Build and push the images (see section 3), set `images`, `app_secrets` and `function_api_key` in `terraform.tfvars`, then:

```bash
terraform apply
```

This switches the apps to the real images and creates the scheduler and migrate Jobs. Start the migrate Job once before opening the site:

```bash
az containerapp job start --name laravel-migrate --resource-group rg-hive-lab
```

### 4.6 Not built yet

- **Function code.** `enable_function` creates the Function app, but this repository does not contain the function that forwards IoT Hub messages to Laravel. It is off by default. Until it exists, readings reach Laravel only through the app's own HTTP endpoint, so the simulator should post there.
- **Front Door, the load test and the plan and apply jobs in CI.**

After the first deploy, the GitHub Actions workflow runs `terraform fmt -check`, `validate` and `tflint`. Plan and apply jobs are not added yet.

Use `enable_*` variables to apply in phases and skip parts you do not need that session.

Record the duration of each apply, and the real errors you hit, in the [implementation log](implementation-log.md) and [troubleshooting](troubleshooting.md).

## 5. Test

```bash
python scripts/device_simulator.py --hub <iot-hub-name> --device NODE-001
```

Check each step of the [data flow](architecture.md#2-data-flow):

- The Function logs show one invocation per message.
- A new row appears in `sensor_logs` and `predictions`.
- The dashboard updates live through Pusher.
- A Ready prediction sends a Telegram alert from the worker.

## 6. Destroy

Destroy only the `lab` root after each session. Keep `foundation` and `bootstrap` unless you are finished with the project.

```bash
cd lab && terraform destroy
```

If locks were ever enabled, set `enable_locks = false` and apply `foundation` first, or the destroy fails. When you are completely done, destroy `foundation`, then delete `rg-hive-iac` by hand. See [Cost and teardown](cost-and-teardown.md).
