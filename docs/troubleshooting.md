# Troubleshooting

This article lists problems expected from this design and problems hit while deploying it, and how to resolve them.

> [!NOTE]
> Entries 1 to 22 were written before the first apply, from Azure's documented behaviour. An entry says **Hit** or **Confirmed** only where it happened on 24/11/2026. Entries 23 to 32 were hit during the first real deployment and carry the real error text and screenshots. The screenshots are in [`evidence/`](evidence/).

## 1. Read the deployment error

```bash
terraform state list
terraform state show <address>
az monitor activity-log list --resource-group rg-hive-lab --offset 1h -o table
```

`terraform state show` prints a resource's last-known attributes. The Activity Log shows what Azure rejected and why.

## 2. SkuNotAvailable or quota errors

**Symptom:** apply fails creating MySQL, an Azure ML compute cluster, or a VM with `SkuNotAvailable`, `QuotaExceeded` or a capacity message.

**Fix:** capacity and quota are per region and per SKU, and new subscriptions often start with zero vCPUs for some ML families.

1. Check MySQL: `az mysql flexible-server list-skus --location <region> -o table`.
2. Check compute: `az vm list-usage --location <region> -o table`.
3. Request a quota increase, pick another SKU, or change `location`. A region change is a full redeploy, because resources cannot move between regions.

## 3. terraform destroy fails on a lock

**Symptom:** destroy fails with `ScopeLocked` on MySQL or Key Vault.

**Fix:** set `enable_locks = false` in the `foundation` root and apply it, then destroy again. Keep locks in the `foundation` root so they never block the `lab` root.

## 4. Role assignment is forbidden

**Symptom:** apply fails with `AuthorizationFailed` on `Microsoft.Authorization/roleAssignments/write`.

**Fix:** `Contributor` cannot create role assignments. Give the pipeline identity `Role Based Access Control Administrator` on the resource group, then apply again.

## 5. Entra groups or app registration cannot be created

**Symptom:** the `azuread` provider returns `Insufficient privileges to complete the operation`.

**Fix:** your account needs directory rights, such as Application Administrator, in the tenant. A university tenant may block this. Use the tenant that came with your own Azure account.

## 6. Laravel cannot reach MySQL

**Symptom:** the app returns connection errors, or `getaddrinfo` fails for the server name.

**Fix:**

1. Confirm the `privatelink.mysql.database.azure.com` zone exists and is linked to `vnet-hive-lab`.
2. Confirm the Container Apps environment is in `snet-aca`, and the server is in the delegated `snet-mysql`.
3. Check the connection uses TLS and the full server hostname, not an IP.

## 7. Container App cannot pull the image or read a secret

**Symptom:** the revision fails with `ImagePullBackOff`, or a secret reference resolves to nothing.

**Fix:**

1. Confirm the managed identity has `AcrPull` on the registry and `Key Vault Secrets User` on the vault.
2. Confirm the private DNS zones for `vaultcore` and `blob` are linked to the VNet.
3. Role assignments can take several minutes to take effect. Wait, then restart the revision.

## 8. IoT Hub works, but nothing reaches Laravel

**Symptom:** the simulator connects, but no row appears in `sensor_logs`.

**Fix:**

1. Check the Function logs for one invocation per message.
2. Confirm the Function's API key setting matches the one Laravel expects.
3. Confirm `laravel-web` has external ingress and the Function posts to its public URL.
4. On the free tier, check you have not passed 8,000 messages per day.

## 9. Sessions or uploads disappear

**Symptom:** users are logged out at random, or an uploaded file is missing on the next request.

**Fix:** with more than one replica, file sessions and local storage are per replica. Set `SESSION_DRIVER=database` and `CACHE_STORE=database`, and set `TRUSTED_PROXIES=*` so Laravel sees HTTPS. Uploaded files are a separate problem: see entry 18.

## 10. Migrations run twice or not at all

**Symptom:** a deploy fails on a duplicate migration, or the new revision starts before the schema changes.

**Fix:** run `migrate` only as a Container Apps Job, and make the pipeline wait for it to finish before it shifts traffic to the new revision.

## 11. 403 from Key Vault or Storage during apply

**Symptom:** Terraform fails creating a Key Vault secret or a storage share with `403 Forbidden`, though the vault or account exists.

**Fix:** with public network access disabled, only the control plane is reachable from outside the VNet. Create secrets and shares through ARM with `azapi` (for example `Microsoft.KeyVault/vaults/secrets`), or allow your own IP on the firewall for the apply and remove it after.

## 12. Recreating a destroyed resource fails on the name

**Symptom:** the next day's apply fails because a Key Vault or Azure ML workspace name is already in use, though you destroyed it.

**Fix:** both are soft-deleted and keep the name reserved. Set the provider options to purge them on destroy, add a random suffix to the name, or purge by hand with `az keyvault purge --name <name>`.

## 13. Resource provider not registered

**Symptom:** apply fails with `MissingSubscriptionRegistration` for `Microsoft.App`, `Microsoft.Devices` or a similar namespace.

**Fix:** register it with `az provider register --namespace <name>` and wait until `az provider show -n <name> --query registrationState` returns `Registered`. The preflight script does this up front.

**Hit, and handled by the preflight.** `Microsoft.App` was `NotRegistered` on the new subscription. The script registered it during its first run, and the second run said `ok` for every provider (see the [implementation log](implementation-log.md#4-problems-found-before-deployment)).

## 14. Azure Policy blocks the apply

**Symptom:** a create fails with `RequestDisallowedByPolicy`, often on a resource Azure creates itself, such as the Container Apps managed resource group.

**Fix:** set the required-tags assignment to `audit` or `modify`, not `deny`. Check which assignment fired in the error message.

## 15. Function cannot reach its storage account

**Symptom:** the Function fails to start with a storage error after the account was put behind a private endpoint.

**Fix:** a Functions Consumption plan generally cannot use storage behind a private endpoint. Keep the Function and ML workspace on the separate public storage account, and use the private account for Laravel files only.

> Entries 16 to 21 come from running the images. The app-side cause of each is documented in the application repository, `docs/docker/docker.md`; the fixes here are the Azure side.

## 16. Live updates never arrive in the browser

**Symptom:** the dashboard loads but predictions and sensor readings only appear after a refresh. The browser console shows Pusher or Echo configuration errors.

**Fix:** `VITE_PUSHER_*` values are compiled into the JavaScript at build time (`resources/js/app.tsx`). Setting them as runtime environment variables does nothing. Rebuild the image with the build arguments `VITE_PUSHER_APP_KEY` and `VITE_PUSHER_APP_CLUSTER`.

## 17. Redirect loops, http links or "mixed content" behind the ingress

**Symptom:** after login the browser is sent to an `http://` URL, assets are blocked as mixed content, or sessions do not stick.

**Fix:** the ingress terminates TLS and forwards plain HTTP. Set `TRUSTED_PROXIES=*` on the Laravel container apps (the lab Terraform does), so Laravel honours `X-Forwarded-Proto`. The app only reads this variable when it is set, so shared hosting is unaffected.

## 18. Hive images and the thesis PDF disappear

**Symptom:** an uploaded hive image returns 404 after a restart or a deploy.

**Fix:** the app writes uploads to `storage/app/public`, which is the container's own disk. It is lost when the container restarts and is not shared between replicas, which is why the lab runs one web replica. For durability, mount an Azure Files share at `/app/storage/app/public` or move the `public` disk to Blob storage.

## 19. The ML image build fails at "model and scaler load ok"

**Symptom:** `docker build ml` fails on the pickle check with an unpickling or version error.

**Fix:** `model.pkl` was written by scikit-learn 1.8.0 (see `model_version` in `model_metadata.json`), and `requirements-serve.txt` pins that version. After retraining in Azure ML, pin the same scikit-learn in the training environment, or update both pins together. The build check exists so a mismatch fails the build, not the first prediction.

## 20. Database connection fails with a TLS error

**Symptom:** Laravel cannot connect to MySQL Flexible Server, with an SSL or "secure transport" message.

**Fix:** Azure MySQL requires TLS. The lab sets `MYSQL_ATTR_SSL_CA=/etc/ssl/certs/ca-certificates.crt`, which `config/database.php` already reads, and the Debian-based image ships that bundle.

## 21. The migrate Job fails with error 1419

**Symptom:** `php artisan migrate` stops on the `HRI_Summary` trigger with `SQLSTATE[HY000]: General error: 1419 You do not have the SUPER privilege and binary logging is enabled`.

**Fix:** this was hit locally (it is why the compose file starts MySQL with `--log-bin-trust-function-creators=1`) and would hit Azure the same way. Flexible Server keeps binary logging on and its admin has no SUPER privilege. `lab/data.tf` sets the server parameter `log_bin_trust_function_creators` to `ON`.

**Confirmed on Azure.** With the parameter set, the `laravel-migrate` Job ran to `Succeeded` on its first start (see [Deploy](deploy.md#45-lab-second-apply-real-images)).

## 22. The budget cannot be created

**Symptom:** the `foundation` apply fails on `azurerm_consumption_budget_subscription`, for example with a message that the subscription type is not supported.

**Fix:** set `enable_budget = false` in `foundation/terraform.tfvars` and apply again. The budget only sends emails, so check your credit by hand under Cost Management, then Credits.

**Not hit.** The `foundation` apply created the budget on the Free Trial subscription with `enable_budget` left at its default of `true`, so this fallback was not needed there.

> Entries 23 to 32 were hit on 24/11/2026, during the first apply of `lab` and the steps after it.

## 23. The Container Apps environment is rejected: the subnet is not delegated

**Symptom:** the first `lab` apply fails creating `azurerm_container_app_environment.this` with a 400:

```
ManagedEnvironmentSubnetDelegationError: The subnet of the environment must be delegated to the service 'Microsoft.App/environments'.
```

**Fix:** the `snet-aca` subnet had no delegation. Add a `delegation` block for `Microsoft.App/environments` with the action `Microsoft.Network/virtualNetworks/subnets/join/action` to `azurerm_subnet.aca` in `lab/network.tf`, as the MySQL subnet already does for its own service. The plan then showed 1 change (the subnet, in place) and the environment to add.

<img src="evidence/24-lab-first-apply-two-errors.png" alt="Terminal output of the first lab apply with two errors: ManagedEnvironmentSubnetDelegationError for the Container Apps environment, and an IoT Hub error about partition count 4" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 23.1. The first `lab` apply ends with two errors, this one and entry 24. The rest of the apply had already succeeded.*

<img src="evidence/25-lab-plan-after-delegation-fix.png" alt="Terraform plan after the fix: 5 to add, 1 to change, with a new delegation block on the snet-aca subnet" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 23.2. The plan after the fix: 5 to add, 1 to change, 0 to destroy. The change is the delegation block added to `snet-aca`.*

## 24. IoT Hub creation fails on the partition count (IH400016)

**Symptom:** the same apply fails creating `azurerm_iothub.this[0]`:

```
Invalid PartitionCount 4 - value must be between 2 and 2 ... errorcode: IH400016
```

The message also contains `json: cannot unmarshal number into Go struct field serviceErrorInternal.code of type string`. That is the provider failing to parse Azure's error, not a second problem.

**Fix:** the provider defaults `event_hub_partition_count` to 4, and the F1 free tier allows exactly 2. Set `event_hub_partition_count = 2` on the hub in `lab/iot.tf`. After the fix the hub took 4 minutes 9 seconds to create. See figure 23.1 for the error.

## 25. `az acr build` fails in Malaysia West

**Symptom:** `az acr build -r <registry> ...` packs and uploads the source, then fails:

```
Failed to get a SAS URL to upload context. Error: (NoRegisteredProviderFound) No registered resource provider found for location 'malaysiawest' ... for type 'registries/listBuildSourceUploadUrl'.
```

The list of supported locations in the message includes `southeastasia` and `eastasia`, and not `malaysiawest`.

**Fix:** ACR Tasks, which `az acr build` uses, is not offered in Malaysia West. Build with Docker in WSL and push instead (see [Docker images](docker.md#7-push-the-images-to-the-registry)). Earlier versions of this repository's docs said to use `az acr build` with no local Docker; that was wrong for this region.

## 26. `docker login` to the registry returns unauthorized

**Symptom:** `docker login` from WSL fails with `unauthorized: authentication required`. It failed with a token from `az acr login --expose-token` (1162 characters, so not empty), and again after the `AcrPush` role was assigned, and again with the registry's admin credentials.

**What was tried:**

1. Token login with the all-zero username. Unauthorized.
2. Assign `AcrPush` to the signed-in user, wait, fetch a new token, try again. Unauthorized.
3. Enable the admin user and pipe its password into `docker login --password-stdin` through `wsl`. Unauthorized.
4. `curl.exe -u <admin user>:<password> https://<registry>/v2/` from Windows returned **200**, so the credentials were valid.
5. Pass the password to WSL in an environment variable (`$env:WSLENV = "ACR_PW"`) and use `docker login -p "$ACR_PW"`. **Login Succeeded.**

**Fix:** step 5. The only difference between 3 and 5 was how the password reached `docker login`, which points at the PowerShell-to-`wsl` pipe corrupting it. I did not find the exact cause. I also did not test whether the token login would have worked after the role assignment, if the pipe had not been the problem.

**Afterwards:** the admin user was enabled by hand, outside Terraform. Turn it off with `az acr update -n <registry> --admin-enabled false`. The apps pull with their managed identity, so this does not affect them.

<img src="evidence/28-acr-token-login-unauthorized.png" alt="PowerShell: token from az acr login piped into docker login in WSL returns unauthorized" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 26.1. Step 1: the token login fails.*

<img src="evidence/29-acrpush-role-assignment.png" alt="az role assignment create assigning AcrPush to the signed-in user on the registry" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 26.2. Step 2: `AcrPush` assigned to the signed-in user on the registry.*

<img src="evidence/30-acr-token-length-unauthorized.png" alt="Token length is 1162 and docker login still returns unauthorized" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 26.3. A new token, 1162 characters long, still unauthorized.*

<img src="evidence/31-acr-role-listed-still-unauthorized.png" alt="az role assignment list shows AcrPush, and docker login is still unauthorized" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 26.4. The role assignment list shows `AcrPush`, and the login is still unauthorized.*

<img src="evidence/32-acr-admin-login-workaround.png" alt="Admin credentials piped into docker login fail, curl with the same credentials returns 200, and login through an environment variable succeeds" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 26.5. Steps 3 to 5: the piped admin password fails, `curl` with the same credentials returns 200, and the environment-variable login succeeds.*

## 27. `docker build` fails in WSL: the daemon is stopped, or "requires 1 argument"

**Symptom 1:** `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`.

**Fix 1:** the engine inside WSL had stopped. Start it as root, which needs no sudo password: `wsl -u root -e bash -lc "service docker start"`. Calling `service` directly (`wsl -u root -e service docker start`) fails with `execvpe(service) failed: No such file or directory`, because `wsl -e` does not search the sbin folders.

**Symptom 2:** `ERROR: docker: 'docker buildx build' requires 1 argument`.

**Fix 2:** the command has no build context. End it with a space and a dot, on the same line. A command pasted over two lines breaks the same way, because the second line runs as a separate command.

<img src="evidence/33-docker-build-missing-context.png" alt="wsl docker build ends at the Pusher cluster argument without a context and fails with requires 1 argument" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 27.1. A `docker build` with the final `.` missing.*

## 28. Terraform cannot take the state lock after a dropped connection

**Symptom:** the first `terraform plan` fails with:

```
Error acquiring the state lock ... Put "https://<state account>.blob.core.windows.net/tfstate/lab.tfstate?comp=metadata": HTTP response was nil; connection may have been reset
```

Running it again fails differently:

```
Error acquiring the state lock ... state blob is already locked
blob metadata "terraformlockid" was empty
```

**Fix:** the interrupted request left a lease on the state blob but never wrote the lock metadata. That leaves `terraform force-unlock` with no lock ID to use. Check that no other Terraform run is active (`Get-Process terraform`), then break the lease and plan again:

```powershell
az storage blob lease break --blob-name lab.tfstate --container-name tfstate --account-name <state account> --auth-mode login
terraform plan
```

The break returned `0` and the plan ran normally. This changes only the lock, not the state data. Do not do it while a real apply is running. `-lock=false` is not the fix.

<img src="evidence/40-state-lease-break-and-plan.png" alt="Get-Process terraform returns nothing, the lease break returns 0, and terraform plan acquires the lock and starts refreshing" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 28.1. No Terraform process running, the lease broken, and the next plan acquiring the lock.*

## 29. Readings return 201 with `ml_unavailable`: a typo in the image tag

**Symptom:** the simulator gets `201` for every reading, but the response carries a warning:

```
{"status":"ok","warnings":[{"code":"ml_unavailable","message":"Live readiness prediction is temporarily unavailable."}], ...}
```

The first two calls took 10.27 s and 5.08 s. `laravel-web` logged `cURL error 28: Operation timed out after 10001 milliseconds` for the first and then `ML API unavailable ... "status":404` for the rest.

**Cause:** `images.flask` in `lab/terraform.tfvars` ended in `:lates` (the final `t` missing). That tag does not exist, so Azure could not pull it, and the new revision `flask-ml--0000001` stayed in `ActivationFailed`. The older revision, `flask-ml--foqw6k4`, still ran Microsoft's quickstart placeholder and stayed `Running` and `Healthy`. Flask itself never returns 404 on `POST /predict` (see `ml/app.py` in the app repository), so the 404 most likely came from that placeholder, which has no `/predict` route. I did not capture its response, so this is an inference. Either way, the failure looked like an application error and not an image-pull failure.

**How it was found:**

1. `az containerapp replica list` for `flask-ml` was empty, and `az containerapp logs show --type console` said `Could not find a replica for this app` (figure 29.4).
2. `az containerapp revision show` on each revision gave the image and state of both (figure 29.5).

**Fix:** correct the tag, then `terraform apply`. The new revision `flask-ml--0000002` came up `Running` and `Healthy`, and the placeholder revision went to `Deprovisioning`. The next five readings returned `201` in 0.17 to 0.29 s with no warning.

**Check first next time:** `az containerapp revision list -n <app> -g <rg> -o table`. With `revision_mode = "Single"`, a failed new revision does not remove the old one, so a leftover placeholder can serve traffic and hide the real error.

<img src="evidence/39-tfvars-flask-tag-typo.png" alt="lab terraform.tfvars with the flask image set to flask-ml:lates, missing the final t" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 29.1. The typo in `terraform.tfvars`: `flask-ml:lates`.*

<img src="evidence/50-simulator-ml-unavailable.png" alt="Simulator output: five 201 responses, each with an ml_unavailable warning, the first two slow" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 29.2. The symptom: `201` with `ml_unavailable` on every reading, and 10.27 s and 5.08 s on the first two.*

<img src="evidence/52-laravel-web-log-ml-errors.png" alt="laravel-web console log: cURL error 28 timed out after 10001 ms, then ML API unavailable warnings with status 404" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 29.3. The `laravel-web` log: a 10-second timeout, then 404 from the ML URL.*

<img src="evidence/51-flask-ml-no-replica.png" alt="az containerapp replica list for flask-ml returns nothing and the console log says Could not find a replica for this app" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 29.4. `flask-ml` had no replica.*

<img src="evidence/53-flask-ml-revisions-lates-failed.png" alt="Traffic goes 100 percent to the latest revision; revision 0000001 has the lates image and is ActivationFailed; revision foqw6k4 runs the quickstart image" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 29.5. The two revisions. `flask-ml--0000001` points at `flask-ml:lates` and failed. `flask-ml--foqw6k4` runs the quickstart placeholder.*

<img src="evidence/54-lab-apply-fix-complete.png" alt="terraform apply complete: 0 added, 6 changed, 0 destroyed, listing the environment, flask-ml, both jobs, web and worker" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 29.6. The fix applied: 0 added, 6 changed, 0 destroyed. The six changes were the environment, `flask-ml`, both Jobs, `laravel-web` and `laravel-worker`. This apply also put the migrate Job back after entry 30.*

<img src="evidence/55-flask-ml-revisions-after-fix.png" alt="Revision list: flask-ml foqw6k4 quickstart image Deprovisioning, flask-ml 0000002 with the real image Running and Healthy" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 29.7. After the fix: the real image runs in `flask-ml--0000002`, and the placeholder revision is being removed.*

## 30. The simulator gets 422, and seeding the database through the migrate Job

**Symptom:** after the migration, every reading from the simulator fails with `422`:

```
{"message":"The selected hive id is invalid.","errors":{"hive_id":["The selected hive id is invalid."]}}
```

**Cause:** the `migrate` Job only creates the empty tables. The API checks that the hive exists, and then that an active device with a matching `node_identifier` is on it, so it needs data.

**Fix:** run the app's `DatabaseSeeder` as a one-off through the migrate Job. Starting a job with overrides replaces the whole container definition, so change the Job's own args and start it with no overrides. Two things went wrong on the way:

- `az containerapp job start --args ...` fails with `(ContainerAppImageRequired) Container with name 'laravel-migrate' must have an 'Image' property specified`. Overrides need the image, and would also drop the Job's environment.
- `az containerapp job update --args "php artisan db:seed --class=DatabaseSeeder --force"` passes the quoted string as a single argument, and the execution fails with `exec: line 11: php artisan db:seed --class=DatabaseSeeder --force: not found`. `az` reads separate tokens that start with `--` as its own options, so they cannot be passed one by one.

What worked was to remove the dashes: `--args php artisan db:seed`, which runs `DatabaseSeeder` by default. The usual `--force` is only there to skip the production confirmation, so the same update sets `APP_ENV=staging` for that run. It also sets `ADMIN_SEED_PASSWORD` and `BEEKEEPER_SEED_PASSWORD`, because the seeder otherwise falls back to default passwords that are in the app repository, and this app is on the internet. Then start the Job. Afterwards, `terraform apply` puts the Job's args and environment back.

The seeded hives get random node identifiers, so find a hive id and its node by querying from inside the app (see [Deploy](deploy.md#46-seed-the-database)).

<img src="evidence/44-seed-job-image-required-error.png" alt="PowerShell: the generated seed password, then az containerapp job start with --args fails with ContainerAppImageRequired, then job update" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 30.1. The `ContainerAppImageRequired` error, then switching to `job update`.*

<img src="evidence/45-seed-job-failed-not-found.png" alt="The migrate job execution fails and its log says php artisan db:seed --class=DatabaseSeeder --force: not found" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 30.2. The execution fails because the whole string was treated as one command. The working run is in [Deploy](deploy.md#46-seed-the-database).*

## 31. The first page load is slow

**Symptom:** the first visit shows the BuzzyHive loading screen for a long time before the page appears.

**What was measured:** `curl` on `/up`, which is a bare health check that does not touch the database, took 0.77 s on the first call and 0.06 s on the second. So the container itself answers fast once it is running.

**Status: not resolved.** I did not isolate the cause. The likely contributors are the scale-to-zero cold start (`laravel-web` has `min_replicas = 0`, so the first request after idle waits for a container to start), the image pull, and heavy pages on a small database. To check, time `/up`, then `/login`, then a signed-in page, and compare the replica list (`az containerapp replica list`) before and after. Setting `min_replicas = 1` on `laravel-web` would remove the cold start at a small cost.

<img src="evidence/47-first-load-spinner.png" alt="Browser tab loading laravel-web with the BuzzyHive 2.0 landing page blurred behind a loading spinner" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 31.1. The landing page behind its loading spinner on the first visit.*

<img src="evidence/48-up-endpoint-timings.png" alt="curl timings for the /up endpoint: 0.77 seconds first, 0.06 seconds second, both HTTP 200" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 31.2. `/up` took 0.77 s the first time and 0.06 s the second.*

## 32. Application Insights shows no data

**Symptom:** after the lab had served traffic, Application Insights `appi-hive-lab` showed nothing. The Application map said **No data available**, and Live metrics said **Not available: couldn't connect to your application**. The charts behind the Live metrics message are Microsoft's demo picture, not this app's data.

**What is known:**

- Terraform sets `APPLICATIONINSIGHTS_CONNECTION_STRING` on the Container Apps (`lab/containerapps.tf`, line 36) and on the Function (`lab/iot.tf`).
- A connection string in an environment variable only tells an agent where to send data. Something in the app has to send it.
- I did not verify this, but the Laravel and Flask images most likely contain no Application Insights SDK or agent, so nothing reads the variable.
- The `Failure Anomalies - appi-hive-lab` alert rule cannot fire while the resource receives no data.

**Status: not fixed.** The architecture says logs and traces reach Application Insights ([architecture step 11](architecture.md#2-data-flow)), and that is not what the portal showed. Two ways forward, neither done: add an OpenTelemetry exporter to each image (the Azure Monitor distro for Python on `flask-ml`, and a Laravel exporter), or drop the Application Insights claim and rely on the Container Apps console logs that `az containerapp logs show` already reads.

<img src="evidence/69-appinsights-application-map-empty.png" alt="Application Insights appi-hive-lab Application map for the last hour: No data available" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 32.1. The Application map has no data.*

<img src="evidence/70-appinsights-live-metrics-unavailable.png" alt="Application Insights Live metrics: Not available, couldn't connect to your application, over a grey Demo chart" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 32.2. Live metrics cannot connect to an application.*

**Update, 25/11/2026:** after the forwarder Function was deployed, Application Insights received its telemetry: in the three hours after the first upload, 312 traces, 4 requests and 1 exception, all from the Function. The Laravel and Flask images still send nothing, so the diagram's claim that the apps report there is still not true, and the choice between adding an exporter to each image and dropping the claim stays open.

<img src="evidence/148-appinsights-application-map-function.png" alt="Application Insights Application map showing one instance, func-hive-lab-ci1yu, with 4 calls" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 32.3. After the Function was deployed, the Application map has data for the first time: one instance, `func-hive-lab-ci1yu`, with 4 calls in the last hour.*

## 33. Every `terraform plan` proposes to remove the `Consumption` workload profile

**Symptom:** after a clean apply, `terraform plan` was not empty. Adding one variable (`min_replicas` on two apps) showed `6 to change` instead of 2. The extra four were the environment, `laravel-worker` and the two Jobs.

**What the plan showed:**

- `workload_profile_name = "Consumption" -> null` on each of the three apps and the two Jobs.
- A `workload_profile` block (`name = "Consumption"`, `minimum_count = 0`, `maximum_count = 0`) removed from `azurerm_container_app_environment.this`.

**Cause:** Azure adds a `Consumption` workload profile to every consumption-only environment and stamps its name on the apps and Jobs that run in it. The configuration does not declare it, so the provider plans to remove it. This is not drift caused by a manual change, and nothing was edited in the portal.

**Fix:** `ignore_changes = [workload_profile]` on the environment and `ignore_changes = [workload_profile_name]` on the three apps and two Jobs (`lab/containerapps.tf`). The next plan showed only the two intended `min_replicas` changes (`Plan: 0 to add, 2 to change, 0 to destroy`).

**Why it matters:** an empty plan after an apply is the idempotence check (see `docs/implementation-log.md`). Without this fix that check never passes, and a reviewer would learn to ignore a noisy plan. Removing a workload profile from a live environment is also not something to apply by accident.

**Related:** `min_replicas` on `laravel-web` and `flask-ml` is now the variable `keep_web_and_ml_warm` (default `false`), the switch suggested in entry 31. It was set to `true` on 24/11/2026 before the load test, and both new revisions came up `Healthy` with one replica.

<img src="evidence/92-terraform-fmt-validate-lab.png" alt="terraform fmt check listing only terraform.tfvars, then terraform validate succeeding" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 33.1. `terraform fmt -check` lists only the git-ignored `terraform.tfvars`, and `terraform validate` succeeds (after a typo on the first try).*

<img src="evidence/93-plan-six-changes-consumption-drift.png" alt="terraform plan listing six resources to update in place" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 33.2. The plan after adding one variable listed six in-place changes instead of two.*

<img src="evidence/94-plan-diff-workload-profile-noise.png" alt="terraform plan diff showing the Consumption workload profile being removed from apps, jobs and the environment" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 33.3. The diff: `workload_profile_name = "Consumption" -> null` on every app and job, and the workload profile removed from the environment, next to the intended `min_replicas` change.*


## 34. A short stall restarts `laravel-web`: the default 1-second liveness probe

**Symptom:** during the first k6 ramp, about 50 requests timed out after 15 seconds, and `laravel-web` restarted in the middle of the test.

**What the system log showed (UTC):** `Probe of Liveness failed with timeout in 1 seconds` at 12:58:09, 12:58:18 and 12:58:28, then `Container laravel-web failed liveness probe, will be restarted` and `ProbeFailure` at 12:58:28. The Terraform set only the probe path, so Azure's defaults applied: a 1-second timeout and 3 failures.

**Cause:** the single web replica was briefly slow, because `flask-ml` was unreachable and requests waited on it. A 1-second `/up` check then failed three times in about 20 seconds and the platform killed a container that was only busy.

**Fix:** `timeout = 5`, `interval_seconds = 10`, `failure_count_threshold = 5` and `initial_delay = 10` on the liveness probes of `laravel-web` and `flask-ml` (`lab/containerapps.tf`).

**Status:** the change alone did not stop the failures: the next run restarted the web container again (entry 35). The run after the app fix had probe timeouts but no restart. Why the probes time out while requests are fast is not explained. Details in [load-test.md](load-test.md).

## 35. Under load, predictions fail to save: a MySQL deadlock in the predictions trigger

**Symptom:** during the second ramp, 149 requests timed out and p95 rose to 6.89 s. The app log showed `production.ERROR: Application error recorded` with `error_code: prediction_persist_failed`, 81 times.

**What the log said:** `SQLSTATE[40001]: Serialization failure: 1213 Deadlock found when trying to get lock; try restarting transaction` on `insert into predictions`. The count rose each minute (20, 28, 33) once the rate reached 10 requests per second.

**Cause:** the trigger `trg_predictions_after_insert` re-aggregates the whole day of `sensor_logs` for the hive on every prediction insert, then upserts `hri_summary`. Concurrent readings for the same hive take overlapping locks and MySQL aborts one. This is read from the trigger code. It was not reproduced in isolation.

**Fix:** in the app repo, `persistPrediction` in `MlPredictionService.php` now calls `DB::transaction(..., 3)`, so Laravel retries a transaction that MySQL aborts with a deadlock. The deadlock is raised by the insert, before the event is broadcast and before the Telegram alert is queued, so a retry cannot send either twice.

**Result:** the next ramp passed all thresholds (3,299 requests, 0 failed, p95 154 ms), and the log showed no `1213` lines.

**Caveat:** the retry is silent, so this shows no deadlock survived three attempts, not that none happened. The trigger still scans the whole day for every insert. An incremental summary update would remove the cause; it was not done. Details in [load-test.md](load-test.md).

## 36. Telegram alerts do not arrive: the saved chat ID had a leading space

**Symptom:** three `ready` readings returned `201` and were classified `ready`, but no Telegram message arrived.

**What the worker log showed:** `App\Jobs\SendTelegramAlert` ran and then failed with `telegram_delivery_failed` and **status 400**, four seconds after the first attempt. The job's own log line shows the chat ID it used, and that value had a space in front of the number. The queue then retried (`tries = 3`, delays of 60 and 300 seconds) and failed the same way each time.

**What this ruled out:** the queue and the worker (the jobs ran), the model and the guardrails (the predictions were `ready`), and the bot token (Telegram answered with a 400, not a 401). The chat with the bot already held older alerts, so the bot had been started.

**Cause:** `users.telegram_id` was saved as `" 123456789"` (with a leading space), most likely pasted that way into the profile field. Telegram rejects the request. Note that the app logs only "Unable to deliver the Telegram alert right now" and the status code, so Telegram's own explanation is not in the log. A bot that was never started can also return a 400 ("chat not found"), so the status alone does not tell the two apart.

**Fix:** trim the stored value, in `php artisan tinker`:

```php
$u = App\Models\Hive::find(1)->user;
$u->update(['telegram_id' => trim($u->telegram_id)]);
```

**Result:** the three queued alerts delivered on their last retry, about 6 minutes after the readings. A fresh `ready` reading and a fresh `nearly_ready` reading each produced one message, and each alert job took 0.7 to 0.8 seconds. One alert per reading, with no duplicates.

**Not done (app repo):** trim or validate `telegram_id` where it is saved (`ProfileUpdateRequest` and `AcceptInviteController` accept it unchecked), and add Telegram's `description` field to the failure log so the cause shows up directly.

<img src="evidence/116-tinker-telegram-id-fix.png" alt="Portal console showing the owner's telegram_id null, then set by hand with the value covered" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 36.1. The hive owner's `telegram_id` was `null`, then saved by hand (the value is covered). This is the save that introduced the leading space.*

<img src="evidence/117-simulate-ready-three-readings.png" alt="Simulator sending three ready readings to hive 1, all returning 201" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 36.2. Three `ready` readings sent to hive 1, all `201`.*

<img src="evidence/118-telegram-ready-alerts.png" alt="Telegram chat with the BuzzyHive bot showing ready-to-harvest alerts" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 36.3. Telegram: the first alert (predicted 22:26, delivered at 22:32 by a queue retry) and three more from a second run of `--profile ready --count 3` at 22:34. The chat list on the left is covered.*

<img src="evidence/119-simulate-nearly-ready-readings.png" alt="Simulator sending nearly_ready readings, both returning 201" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 36.4. The `nearly_ready` profile was sent twice, one reading each time, both `201`.*

<img src="evidence/120-telegram-nearly-ready-alerts.png" alt="Telegram chat showing two nearly-ready alerts" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 36.5. Two `nearly_ready` alerts, one per reading. The logs showed two separate readings 13 seconds apart, so this is one alert per reading, not a duplicate.*


## 37. Azure ML creates its own registry, and the next plan wants to replace the workspace

**Symptom:** after the first Azure ML job, `terraform plan` (changing only an image tag) showed `Plan: 2 to add, 1 to change, 2 to destroy`. Two resources said `must be replaced`: `azurerm_machine_learning_workspace.this[0]` and `azurerm_machine_learning_compute_cluster.train[0]`.

**What the plan said:** on the workspace, `container_registry_id = ".../registries/<name>" -> null # forces replacement`. On the cluster, `machine_learning_workspace_id ... -> (known after apply) # forces replacement`, because it depends on the workspace.

**Cause:** when the job built its first environment image, Azure ML created a Container Registry of its own in `rg-hive-lab` and attached it to the workspace. The Terraform does not declare that attribute, so the provider planned to remove it, and removing it forces a new workspace. Applying would have deleted the workspace, the registered model, the job history and the cluster.

The same event created a second problem. The new registry is a Basic registry with the **admin user enabled**, no tags, and **no entry in Terraform state**. `terraform destroy` will not remove it, so it would keep billing after the lab is gone.

**How it was found:** `az acr list -g rg-hive-lab` showed a second registry, created when the job started building, and the plan listed the replacement. The `--only` filter on the first plan hid it, because it matched "will be" and not "must be": use `(will|must) be|forces replacement`.

**Fix:** `lifecycle { ignore_changes = [container_registry_id] }` on the workspace in `lab/ml.tf`. The next plan showed only the intended single in-place change. At teardown, delete the registry by hand: `az acr delete -n <name> -g rg-hive-lab --yes`. `scripts/down.ps1` now lists anything still inside the resource group after the destroy.

**Status:** fixed in the Terraform. The registry itself is still there until the teardown. Do not delete it while a job is using it.

<img src="evidence/124-acr-list-azureml-created-registry.png" alt="az acr list showing a second registry created by Azure ML with admin enabled" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 37.1. `az acr list`: the second registry, created at 14:50:55 UTC with the admin user enabled, next to `acrhiveci1yu`.*


## 38. The first Azure ML job fails with `Unable to get image details`

**Symptom:** the job was submitted and failed within about a minute. The error was `Unable to get image details : Image mcr.microsoft.com/azureml/openmpi4.1.2-ubuntu20.04:latest for environment CliV2AnonymousEnvironment does not exist in registry`, status 400, target `GetImageDetails`.

**Cause:** `azureml/train-job.yml` pinned a base image tag that no longer exists. This was an error in the job file, written without checking the tag against the registry. It was not a default of the CLI.

**Fix:** list the tags at `mcr.microsoft.com/v2/azureml/<image>/tags/list` before pinning. `openmpi4.1.0-ubuntu22.04` had 118 tags, the newest dated 22/11/2026, so the job now uses `mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu22.04:latest`. The second submit completed.

**Note:** the environment image was built by a `prepare_image` job running on the cluster in about 6 minutes, not by ACR Tasks, which is not offered in Malaysia West.

<img src="evidence/123-azureml-jobs-failed-and-preparing.png" alt="Azure ML Studio job list with the first job failed and the second preparing" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 38.1. The two jobs: the first `Failed` at 10:48 PM, the second `Preparing` at 10:51 PM. The account name and the subscription are covered.*


## 39. The Azure ML CLI cannot stream the image-build log

**Symptom:** `submit-training.ps1` printed `Streaming azureml-logs/20_image_build_log.txt` and then an XML error from the storage account: `AuthenticationFailed`, `Server failed to authenticate the request ... Signature did not match`.

**What it did not affect:** the job itself. Its status moved on to `Preparing`, then to `Completed`, and the model downloaded without trouble.

**Workaround:** read the job in Azure ML Studio (**Outputs + logs**), or poll `az ml job show -n <job> -w <workspace> -g rg-hive-lab --query status -o tsv`. `az ml job download` also works for the logs.

**Status: cause not found.** Downloaded logs contain Studio links that include the subscription ID, so keep them outside the repository.

<img src="evidence/127-azureml-submit-completed-stream-error.png" alt="submit script output showing an XML AuthenticationFailed error followed by Final status Completed" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 39.1. The submit script's output: the XML `AuthenticationFailed` error from the storage account while streaming, then `Final status: Completed`. The subscription ID in the link is covered.*

## 40. The Function's App Service plan cannot be created: only Flex Consumption worked

**Symptom:** with `enable_function = true`, `terraform apply` created the IoT Hub shared access policy and then failed on the App Service plan, five times in a row with different plan types and regions. The sixth attempt, Flex Consumption, worked.

| # | Attempt | Result |
|---|---|---|
| 1 | `Y1` (Consumption), Malaysia West | `400`, `Requested features are not supported in region` (extended code 59911) |
| 2 | `B1`, Malaysia West | `409`, `No available instances to satisfy this request` (03029): a temporary capacity shortage, so the quota there is unknown |
| 3 | `B1`, Southeast Asia | `401`, `Current Limit (B1 App Service instances): 0` (70007) |
| 4 | `Y1`, Southeast Asia | `401`, `Current Limit (Y1 App Service instances): 0` |
| 5 | `Y1`, East US | `401`, `Current Limit (Y1 App Service instances): 0` |
| 6 | Flex Consumption (`FC1`), East US | **Created in 55 seconds.** Code uploaded and a device message forwarded |

**What was checked:**

- `az functionapp list-consumption-locations` **does** list `malaysiawest`, so that list did not predict attempt 1. East US is listed for Consumption, Flex and `B1`, and the first of those still failed on quota.
- `az functionapp list-flexconsumption-locations` lists `malaysiawest`, `southeastasia` and `eastus`.
- `az appservice list-locations --sku B1 --linux-workers-enabled` lists Malaysia West, Southeast Asia and East US.

**Cause:** the Free Trial subscription has a quota of 0 for classic App Service plan instances (`B1` and `Y1`), shown in two regions for `Y1` and one for `B1`. Why attempt 1 was refused for region support was not determined. Flex Consumption has its own regional memory quota, which was not 0.

**Fix:** a `function_hosting` variable chooses how the Function is hosted. The default is now `flex`, which creates an `FC1` plan, a blob container `function-deploy` in the existing storage account, and `azurerm_function_app_flex_consumption` with 512 MB instances (at most 10). It leaves out the app settings that Flex does not take (`SCM_DO_BUILD_DURING_DEPLOYMENT`, `ENABLE_ORYX_BUILD`, `FUNCTIONS_WORKER_RUNTIME`). The classic route stays available as `function_hosting = "plan"` for a subscription that has the quota. `function_location = "eastus"` in the git-ignored `lab/terraform.tfvars` put the app in East US while the storage account stays in Malaysia West. Microsoft calls same-region storage a performance recommendation, not a rule, outside the portal, and it worked.

**Verified on 25/11/2026:**

- `scripts/deploy-function.ps1` uploaded the zip with `az functionapp deployment source config-zip --build-remote true` and `forward_reading` was registered.
- `scripts/simulate_device.py` sent three readings through IoT Hub. Laravel stored three predictions at the matching times (07:39:47, 07:39:52 and 07:39:56 local time), with the values that were sent, and no Telegram alert ran.
- Application Insights recorded four invocations of `forward_reading`, all successful. The three single readings took 1.3 to 1.4 seconds each, against about 0.13 seconds for a direct post to Laravel, because the app is in East US and calls Malaysia West. The host stopped about four minutes after the last message, so the app scales to zero as designed.

**Not known:** the cost (Flex is pay per use and scales to zero, an estimate, not measured), the cold start time, and whether the classic route works on a subscription that has quota.

**Lessons:**

- A list of regions that offer a service does not guarantee that every SKU of it can be created there. Read the create error, not only the list.
- Quotas are per plan family. The classic App Service quota was 0 while the Flex quota was not, so when one family is refused, try the other before giving up.
- Azure's error suggested "try a different region". Taking that literally and widening the search cost five attempts, so check the quota family first.

## 41. The Function replayed the IoT Hub's backlog when it first started

**Symptom:** right after the first upload, Laravel's log showed 20 `ML prediction stored` entries within a few seconds (about 07:36 local time), about one per second, with temperatures that had not been sent that day. They came before the three readings sent for the test.

**Cause:** the Event Hubs trigger starts at the beginning of the retained stream when it has no checkpoint. The hub still held the device messages from the 24/11/2026 test, because the free tier retains them for a day, so the Function forwarded all of them. Laravel stamps a reading with its arrival time, so the old readings were stored as new ones: 20 extra rows for hive 1, all `approaching`, and no Telegram alert.

**What the telemetry showed:** the first invocation handled the 20 replayed messages in 20.5 seconds, about one second each. One warning was logged at that first start, `Encountered an exception while getting checkpoints for Event Hub ... used for scaling`, before any checkpoint existed. It did not appear again, and its cause was not investigated.

<img src="evidence/149-iothub-metrics-messages-23.png" alt="IoT Hub metrics: 23 messages used and 2 successful connects" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 41.1. The IoT Hub's own counters: 23 messages used for the day and 2 successful connects. That fits the 20 older messages the Function replayed plus the 3 sent for the test. The account name is covered.*

**Impact:** harmless in this lab, but it is duplicated data.

**Fix:** `functions/forwarder/host.json` now sets `extensions.eventHubs.initialOffsetOptions.type` to `fromEnd`, so a fresh Function starts at the end of the stream. It only matters for the first start, because checkpoints exist afterwards. The running app was not redeployed with it, and it already has its checkpoint, so it will not replay again. The trade-off: messages sent before the first start are skipped.

**Status:** the setting is written but has not run. The 20 replayed rows were not removed.

## 42. The plan shows a change right after the Function was deployed

**Symptom:** the drift check before the teardown (`terraform plan -detailed-exitcode` in each root) gave `No changes` for `bootstrap` and `foundation`, but `lab` returned exit code 2: `Plan: 0 to add, 1 to change, 0 to destroy`, on `azurerm_function_app_flex_consumption.forwarder`.

**What the plan showed** (values hidden with a filter, because the app settings hold the API key and a connection string):

- `tags`: `- "hidden-link: /app-insights-resource-id"` removed.
- `app_settings`: `+ "AzureWebJobsStorage"` added.

**Cause:** two read-back differences, not changes that anyone made.

- Azure adds the `hidden-link` tag itself when a Function app is linked to Application Insights, and the configuration does not declare it.
- The provider does not read `AzureWebJobsStorage` back, so it always plans to add it. The setting exists on the app: `az functionapp config appsettings list --query "[].name"` listed it (names only), together with `DEPLOYMENT_STORAGE_CONNECTION_STRING`, which Azure adds itself.

**Fix:** `ignore_changes` for `tags["hidden-link: /app-insights-resource-id"]` and `app_settings["AzureWebJobsStorage"]` on the Flex Function app, and for the tag on the classic one (`lab/iot.tf`). The consequence is written in a comment: a rotated storage key will not reach the app by itself.

**Result:** `terraform plan -detailed-exitcode` then returned `No changes` and exit code 0 in all three roots on 25/11/2026.

**Lesson:** the same as entry 33. Azure adds things to a resource after it is created, so run the drift check after every new resource type, and list setting names, never values, when you check what is on an app.

<img src="evidence/154-drift-bootstrap-no-changes.png" alt="terraform plan detailed-exitcode in bootstrap: No changes, exit 0" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 42.1. The drift check in `bootstrap`: `No changes`, exit code 0. `foundation` returned the same, and `lab` did after the fix.*

## 43. The first teardown stops on the Key Vault secrets: `DeleteNotSupported`

**Symptom:** `scripts/down.ps1`, the first time it ran against Azure on 25/11/2026, destroyed most of the lab and then failed with six identical errors, one per secret: `Failed to delete resource ... Microsoft.KeyVault/vaults/kv-hive-ci1yu/secrets/<name>`, `RESPONSE 405: 405 Method Not Allowed`, `ERROR CODE: DeleteNotSupported`, `The resource type does not support delete operation.` The script reported `The destroy failed`, and Terraform released the state lock.

**What had already worked:** the network, the apps and nearly everything else were destroyed before the error, so a rerun only had a handful of resources left.

**Cause:** the secrets are `azapi_resource.secret` (one per name), because the vault has public access off and Terraform cannot reach its data plane from outside the VNet, so they are written through the Azure management API. That API creates and updates a secret but does not delete one. The vault cannot be deleted until Terraform has deleted its children, so the destroy stopped there. The create path had worked on 24/11/2026, and the destroy path had never run.

**Fix:** a secret goes away with its vault, so `down.ps1` now removes `azapi_resource.secret` from the state (`terraform state rm azapi_resource.secret`, only if it is present) just before it plans the destroy. Nothing in Azure changes. The provider is configured to purge soft-deleted vaults on destroy, so the vault's name is not left reserved.

**Result:** the rerun destroyed the remaining 3 resources (the vault in 16 seconds, plus two random values). The script then listed what Terraform never owned, exactly as the runbook predicted: the registry that Azure ML created, the `Application Insights Smart Detection` action group and the `Failure Anomalies - appi-hive-lab` rule that Azure creates for Application Insights, plus the managed identity that `foundation` owns and removes later. No `ME_` group was left.

**Not verified here:** that the vault was purged (`az keyvault list-deleted`), which is a separate check in the runbook.

**Lessons:**

- A resource type that can be created through an API is not necessarily one that can be deleted through it. Test the destroy path as early as the apply path.
- Removing something from the state is the right tool when its parent deletes it anyway. It is only bookkeeping, so say so out loud before doing it.
