# Troubleshooting

This article lists problems expected from this design and how to resolve them.

> [!NOTE]
> Nothing has been deployed yet, so every entry here is an expected problem taken from Azure's documented behaviour, not one that has been hit. Mark each entry as confirmed, and add the real error text, when it happens.

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

1. Confirm the `privatelink.mysql.database.azure.com` zone exists and is linked to `vnet-hive`.
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

**Fix:** register it with `az provider register --namespace <name>` and wait until `az provider show -n <name> --query registrationState` returns `Registered`. The planned preflight script does this up front.

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
