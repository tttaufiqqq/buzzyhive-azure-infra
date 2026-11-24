# Deploy, redeploy, and destroy

This article shows the planned steps to deploy the infrastructure, change it, and delete it.

> [!NOTE]
> The Terraform is scaffolded and passes `terraform validate` in all three roots, but it has not been applied to Azure. Expect provider, quota and naming errors on the first apply, and update this article with what actually happens.

## 1. Before you begin

- Sign in with `az login`, and select your subscription with `az account set --subscription "<name>"`.
- Run the preflight script (planned: `scripts/preflight.sh`). It should do three things:
  - Register the resource providers a new subscription often lacks: `Microsoft.App`, `Microsoft.Devices`, `Microsoft.DBforMySQL`, `Microsoft.MachineLearningServices`, `Microsoft.OperationalInsights` and `Microsoft.Cdn`.
  - Check quota with `az vm list-usage --location southeastasia -o table`.
  - Confirm MySQL B1ms is offered with `az mysql flexible-server list-skus --location southeastasia -o table`.
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

Apply the roots in order. `foundation` and `lab` read the outputs of the one before.

```bash
cd bootstrap  && terraform init && terraform apply
cd ../foundation && terraform init && terraform apply
cd ../lab     && terraform init && terraform apply
```

1. **bootstrap:** the `rg-hive-iac` resource group and the state storage account. Copy its backend settings into the other two roots.
2. **foundation:** subscription-scope Policy (audit mode), tags, a $100 budget and Defender, then Entra groups, the managed identity and the GitHub OIDC credential. Leave `enable_locks = false` in the lab. Save the client ID and tenant ID as GitHub repository variables.
3. **lab:** VNet, MySQL, Key Vault, both storage accounts, ACR and the three private DNS zones first. Push the images to ACR, then the Container Apps, Jobs, IoT Hub, Function and Azure ML workspace.

Use `enable_*` variables to apply in phases and skip parts you do not need that session, such as Azure ML or Front Door.

After the first deploy, the GitHub Actions pipeline runs `terraform fmt -check`, `validate` and `plan` on every pull request, and applies from a protected environment. It also builds images, pushes to ACR and updates the Container Apps. It runs the `migrate` Job before the new revision takes traffic.

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
