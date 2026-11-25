# Docs index

Read these in order.

1. [Architecture](architecture.md): what this project deploys, how data flows, and why each design decision was made. Read this first to understand the system before touching anything.
2. [Docker images](docker.md): why the two images are built the way they are, with measured sizes. Read this to understand the images before changing them.
3. [Deploy, redeploy, and destroy](deploy.md): the steps to stand it up, change it, and tear it down, with what happened on the first run. Read this before running Terraform.
4. [Implementation log](implementation-log.md): the decisions made, the timeline, the problems found before and during the first apply, and the lessons. Read this for the story behind the decisions.
5. [Troubleshooting](troubleshooting.md): symptom-to-fix reference. Entries 1 to 22 are expected problems; entries 23 to 42 were hit during the first apply. Not meant to be read start to finish.
6. [Cost and teardown](cost-and-teardown.md): estimated cost, the credit balance and expiry, how to check your own cost, and how to leave nothing running. Read this before you leave anything running.
7. [Train the model in Azure ML](azure-ml.md): the retraining run of 24/11/2026, the job that failed first, the retrained model compared with the one in service, and its deployment.
8. [Load test with k6](load-test.md): the ingest test run against the lab, four runs compared, what the logs showed (a probe restart and a MySQL deadlock), what was changed, and what is still unknown.
9. [Teardown and redeploy](teardown-and-redeploy.md): the runbook for removing everything, proving nothing is left, and building it again from empty. Not run yet.

The two diagrams and their editable source are in [`architecture/`](architecture/). Screenshots are in [`evidence/`](evidence/): `01` to `91` from the first deployment, and `92` to `135` from the load test, the Telegram check and the Azure ML session. They are used in the deploy, troubleshooting, Docker, architecture, cost, implementation log, load test and Azure ML articles.

> [!NOTE]
> The environment was applied once, on 24/11/2026. Results from that run are labelled as measured or observed, and the screenshots back them. Service prices and the cost of the run itself are still estimates, because the lab had not been destroyed and measured when this was written.

Start at the [repository README](../README.md) if you haven't already.
