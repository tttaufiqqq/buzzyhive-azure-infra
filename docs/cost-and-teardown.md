# Cost and teardown

<!-- docs-nav:start -->
**[← Previous: Troubleshooting](troubleshooting.md) | [Docs index](README.md) | [Next: Train the model in Azure ML →](azure-ml.md)**
<!-- docs-nav:end -->

This article shows what the environment is expected to cost, how to check your own cost, and where to find the teardown steps.

> [!NOTE]
> The service prices in section 1.1 are still estimates from published price lists. The first measured figures are in [section 1.5](#15-what-cost-analysis-showed-on-26112026-measured-for-24-and-25112026): **US$1.53 for 24 and 25/11/2026**, which is far below the estimates, mostly because MySQL billed nothing. Later days were not in Cost Management yet. The credit balance and expiry date in section 1 are read from the portal. Prices vary by region and change over time; the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/) gives current rates.

## 1. Estimated cost

The free account gives a $200 credit that lasts 30 days. **$135.68 remained** on 24/11/2026, and it **expires on 02/12/2026**, 8 days later. The portal says services are paused when the credit runs out or expires. The plan is to run the environment for about one day, so the real spend is a small fraction of the monthly figures below.

<img src="evidence/01-portal-credit-balance.png" alt="Azure Portal home page: 135.68 dollars in credits remaining, expires 02/12/2026, 8 days left, 64.32 dollars of costs incurred this month" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.1. The portal home page on 24/11/2026, before anything in this repository had been applied: $135.68 of credit left, expiring 02/12/2026, with $64.32 already incurred this month.*

That $64.32 was spent before the first `bootstrap` apply, so it did not come from this project. See section 1.3.

The same Cost Management overview later that day, with the lab running. It warns that the free trial **expires in 7 days**. Costs incurred and available credit still read $64.32 and $135.68, because cost data lags by hours, so the lab's own spend had not appeared yet.

<img src="evidence/75-cost-management-overview.png" alt="Cost Management overview for the Free Trial subscription: your free trial expires in 7 days, costs incurred 64.32 dollars, available credits 135.68 dollars" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.1b. Cost Management on 24/11/2026, with the free trial expiring in 7 days. The spend had not caught up with the lab yet.*

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

**Total: about $50 to 70 per month** if left running, or under $5 for a one-day run. The measured figure for the first two days was lower than that ([section 1.5](#15-what-cost-analysis-showed-on-26112026-measured-for-24-and-25112026)).

### 1.2 What can break the budget

- **Front Door Premium** is about $330 per month. Managed WAF rules need Premium, so the plan uses Standard or none.
- **A dedicated Container Apps workload profile** is about $140 per month. The plan uses consumption only.
- **An Azure ML compute cluster left with `min_nodes > 0`** bills every hour.
- **A resource that survives the destroy,** such as a stuck resource group, keeps billing after the rest is gone.

The budget in the `foundation` root alerts at 75% and 90% of $100, which sits below the remaining credit. A budget only sends a notification and does not stop spending.

Two budgets exist on the subscription. `budget-hive-lab` ($100 a month, from 01/11/2026 to 01/11/2036) is this project's and stood at 64.32%. `budget-lab-monthly` ($5 a month, forecast $66.81) is not defined anywhere in this repository (the only budget here is named `budget-${project}-${env}`), so it was most likely created for the sibling project, and it sat at 100%. Both read the same $64.32 evaluated spend, which confirms that figure is subscription-wide and not this project's.

<img src="evidence/76-budgets.png" alt="Cost Management budgets: budget-lab-monthly with a 5 dollar budget at 100 percent, and budget-hive-lab with a 100 dollar budget at 64.32 percent, both with 64.32 dollars evaluated spend" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.1c. The two budgets. `budget-hive-lab` is this project's.*

MySQL 8.0 loses standard Azure support on 31/12/2026, and extended-support charges begin on 01/01/2027 (see [architecture, figure 8.7](architecture.md#82-network)). That is after the planned one-day run, so it adds no cost here, but a long-lived copy of this lab should use a newer MySQL version.

### 1.3 What else is in the subscription

The Resource Manager list shows more than this project. The rows named `pldns` (for example `afw-pldns-dev-sa3`, an Azure Firewall in `rg-pldns-dev-sa3-hub`, plus a Log Analytics workspace and application security groups) belong to the sibling reference project, `azure-private-link-dns`. They are in the same subscription and draw on the same credit.

<img src="evidence/27-portal-all-resources-37.png" alt="Resource Manager list of 37 resources in the subscription, including this project's acae-hive-lab, acrhiveci1yu and flask-ml, and the sibling project's afw-pldns-dev-sa3 firewall" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.2. All 37 resources in the subscription after the second `lab` apply. Rows with `hive` or `ci1yu` are this project; rows with `pldns` are the sibling project.*

<img src="evidence/57-portal-all-resources-39.png" alt="Resource Manager list of 39 resources in the subscription after the Jobs were added, including acae-hive-lab, flask-ml and the sibling project's afw-pldns-dev-sa3 firewall" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.3. The same list later, with 39 resources after the two Jobs (`laravel-migrate` and `laravel-schedule`) were added. The `pldns` rows are unchanged.*

- **Check before blaming this project for the spend.** Group Cost analysis by resource group. `rg-hive-lab` and `rg-hive-iac` are this project, and `rg-pldns-*` is the other one.
- **An Azure Firewall bills for every hour it exists.** I have not checked whether that one is running or what it costs. If that project is finished, deleting it is likely the largest saving available, but it is not mine to delete from here.

### 1.4 What Cost analysis showed on 25/11/2026 (partial)

A first look at Cost analysis, scoped to the subscription, dated 24/11/2026 to 25/11/2026 and filtered on the tag `project = buzzyhive`.

**This is not the cost of the lab.** Cost data lags by 8 to 24 hours, and the services that should cost the most still showed `$0.00` (the MySQL server, among others) when these screenshots were taken. Read the figures as what had been billed so far.

| View | Figure |
|---|---|
| Actual cost so far | **US$0.46** |
| Azure's forecast for the chart | US$5.85 (an extrapolation from partial data, not a measurement) |
| By service | Virtual Network $0.32, Container Registry $0.09, Azure DNS $0.02, Storage $0.02, Key Vault under $0.01 |
| By location | Malaysia West $0.43, global $0.02 |
| By resource group | `rg-hive-lab` about $0.40, the Container Apps infrastructure group about $0.06, `rg-hive-iac` under $0.01 |

*Table 1.4. The partial figures. The measured total has to come from Cost analysis after the destroy, with the data caught up.*

<img src="evidence/151-cost-analysis-landing.png" alt="Cost Management Cost analysis landing page for the Free Trial subscription" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.4. Cost analysis for the Free Trial subscription, before a view was chosen.*

<img src="evidence/152-cost-analysis-project-tag-0-46-usd.png" alt="Cost analysis 24 to 25 November 2026 filtered on project buzzyhive: actual cost 0.46 US dollars, forecast 5.85" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.5. Cost analysis for 24 and 25/11/2026, filtered on the tag `project = buzzyhive`: US$0.46 actual and a chart forecast of US$5.85. The account name is covered.*

<img src="evidence/153-cost-analysis-by-service-vnet-registry.png" alt="Cost analysis breakdown by service, location and resource group" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.6. The same view broken down by service, location and resource group. The account name is covered.*

### 1.5 What Cost analysis showed on 26/11/2026 (measured for 24 and 25/11/2026)

The same view as section 1.4, a day later: the subscription scope, dated 24/11/2026 to 26/11/2026 and filtered on the tag `project = buzzyhive`. The daily rows were also exported as a CSV, kept as [cost-analysis-2026-11-24-to-25.csv](evidence/cost-analysis-2026-11-24-to-25.csv).

<img src="evidence/182-cost-analysis-project-tag-1-53-usd.png" alt="Cost analysis 24 to 26 November 2026 filtered on project buzzyhive: actual cost 1.53 US dollars, Virtual Network 1.03, Container Registry 0.26, Virtual Machines 0.13, Azure DNS 0.08, MySQL 0" style="border: 1px solid #d0d7de; border-radius: 6px;">
*Figure 1.7. Cost analysis for the tag `project = buzzyhive`: US$1.53 actual, with Virtual Network the largest line. The account name is covered.*

| Service | 24/11 | 25/11 | Total |
|---|---|---|---|
| Virtual Network | $0.50 | $0.54 | **$1.03** |
| Container Registry | $0.14 | $0.12 | **$0.27** |
| Virtual Machines | $0.13 | none | **$0.13** |
| Azure DNS | $0.04 | $0.04 | **$0.08** |
| Storage | $0.02 | under $0.01 | **$0.02** |
| Key Vault | $0.01 | under $0.01 | **$0.01** |
| MySQL, App Service, Monitor, Functions, IoT Hub, Log Analytics, Load Balancer, Bandwidth | $0 | $0 | **$0** |
| **Day total** | **$0.83** | **$0.70** | **$1.53** |

*Table 1.5. The CSV, summed by service and day (US dollars, rounded).*

What it says:

- **The measured cost of 24 and 25/11/2026 is US$1.53,** against an estimate of $50 to 70 a month. That is about $0.70 to 0.83 a day. It is not a clean daily rate: the lab was built, destroyed and rebuilt during those two days, so it ran for part of each. The order of magnitude is the useful result.
- **The largest line is Virtual Network, $1.03.** That is what the two private endpoints bill as, which is consistent with the estimate of about $15 a month for them (about $0.50 a day). I did not break the line down by resource to prove it.
- **Container Registry, $0.27,** matches the flat Basic rate of about $5 a month (about $0.17 a day) over the one and a half days it existed.
- **MySQL shows $0.** The estimate had it as the largest item. I have not confirmed why. It is likely covered by the hours the free account includes for this server size, but the portal data I have does not say so, so treat it as unverified. A paid subscription would bill it, and the monthly estimate would then be closer to the one in section 1.1.
- **The resource-group view** put `rg-hive-lab` at $1.33, the Container Apps managed group at $0.20 and `rg-hive-iac` under $0.01. I did not map the Virtual Machines line to a resource.

What it does **not** cover:

- **26/11/2026** (the third rebuild and the third teardown) was not in Cost Management yet. The chart ends on 25/11, so $1.53 is a lower bound for the project so far.
- **Resources without the tag** `project = buzzyhive` are not in this figure. The three resource groups above are the project's, and the sibling project's resources are in other groups.
- **The credit balance** after these days was not read, so I do not state a remaining figure.

## 2. How to check your own cost

1. In the Azure Portal, open **Cost Management**, then **Cost analysis**.
2. Set the scope to your subscription and a date range that covers your deployment.
3. Group by **Resource group**, then by **Service name** and **Location**.
4. Filter on the tag `project = buzzyhive` to show only this project.
5. Data lags by 8 to 24 hours, so a deployment you just destroyed may not show its full cost yet.

## 3. Teardown

MySQL, the registry and private endpoints bill hourly, so delete the environment as soon as you finish testing. The steps are in [Deploy, redeploy, and destroy](deploy.md#6-destroy).

After the destroy, confirm nothing is left:

```bash
az resource list --tag project=buzzyhive -o table
az group list -o table
```

Both should show no `rg-hive-lab` resources. If the free account is about to expire, also delete `rg-hive-iac` so the state storage stops billing.

Things changed by hand during the first run, outside Terraform:

- **Registry admin user and the `AcrPush` role assignment.** Both live on the registry, so `terraform destroy` removes them with it. Turn the admin user off sooner if the lab stays up (`az acr update -n <registry> --admin-enabled false`). See [troubleshooting](troubleshooting.md#26-docker-login-to-the-registry-returns-unauthorized).
- **Seeded database rows.** They live in MySQL and are deleted with it, so a new lab needs the migration and the seeder again (see [Deploy](deploy.md#46-seed-the-database)).
- **State storage and the managed identity** are kept on purpose, because `bootstrap` and `foundation` are not destroyed after a session.

---

<!-- docs-nav:start -->
**[← Previous: Troubleshooting](troubleshooting.md) | [Docs index](README.md) | [Next: Train the model in Azure ML →](azure-ml.md)**
<!-- docs-nav:end -->
