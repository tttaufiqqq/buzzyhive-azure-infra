# Cost and teardown

This article shows what the environment is expected to cost, how to check your own cost, and where to find the teardown steps.

> [!NOTE]
> These are estimates from published price lists, not measurements. Nothing has been deployed yet. Replace them with measured figures from Cost Management after the first run, in the same format as a measured cost table. Prices vary by region and change over time; the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/) gives current rates.

## 1. Estimated cost

The free account gives a $200 credit that lasts 30 days. **$135.68 remained** when this was written (check the expiry date under Cost Management, then Credits). The plan is to run the environment for about one day, so the real spend is a small fraction of the monthly figures below.

### 1.1 By service

| Service | Monthly estimate | Notes |
|---|---|---|
| MySQL Flexible Server B1ms with 20 GB storage | about $15 | Bills while the server exists, even stopped storage |
| Container Apps (consumption) | about $5 to 15 | The worker has `min_replicas = 1`; web and ML scale to zero |
| Container Registry Basic | about $5 | Flat daily rate |
| Two private endpoints | about $15 | About $7 each, plus data processed |
| Log Analytics | $0 to a few dollars | The first 5 GB per month is free |
| IoT Hub free tier, Functions consumption | $0 | Within the free quotas |
| Key Vault, Storage | under $1 | Light use |
| Azure ML compute | only while training | Cluster has `min_nodes = 0` |

**Total: about $50 to 70 per month** if left running, or under $5 for a one-day run.

### 1.2 What can break the budget

- **Front Door Premium** is about $330 per month. Managed WAF rules need Premium, so the plan uses Standard or none.
- **A dedicated Container Apps workload profile** is about $140 per month. The plan uses consumption only.
- **An Azure ML compute cluster left with `min_nodes > 0`** bills every hour.
- **A resource that survives the destroy,** such as a stuck resource group, keeps billing after the rest is gone.

The budget in the `foundation` root alerts at 75% and 90% of $100, which sits below the remaining credit. A budget only sends a notification and does not stop spending.

## 2. How to check your own cost

1. In the Azure Portal, open **Cost Management**, then **Cost analysis**.
2. Set the scope to your subscription and a date range that covers your deployment.
3. Group by **Resource group**, then by **Service name** and **Location**.
4. Filter on the tag `project = hive` to show only this project.
5. Data lags by 8 to 24 hours, so a deployment you just destroyed may not show its full cost yet.

## 3. Teardown

MySQL, the registry and private endpoints bill hourly, so delete the environment as soon as you finish testing. The steps are in [Deploy, redeploy, and destroy](deploy.md#6-destroy).

After the destroy, confirm nothing is left:

```bash
az resource list --tag project=hive -o table
az group list -o table
```

Both should show no `rg-hive-lab` resources. If the free account is about to expire, also delete `rg-hive-iac` so the state storage stops billing.
