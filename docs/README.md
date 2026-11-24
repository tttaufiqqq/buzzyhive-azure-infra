# Docs index

Read these in order.

1. [Architecture](architecture.md): what this project deploys, how data flows, and why each design decision was made. Read this first to understand the system before touching anything.
2. [Docker images](docker.md): why the two images are built the way they are, with measured sizes. Read this to understand the images before changing them.
3. [Deploy, redeploy, and destroy](deploy.md): the steps to stand it up, change it, and tear it down, with what happened on the first run. Read this before running Terraform.
4. [Implementation log](implementation-log.md): the decisions made, the timeline, the problems found before and during the first apply, and the lessons. Read this for the story behind the decisions.
5. [Troubleshooting](troubleshooting.md): symptom-to-fix reference. Entries 1 to 22 are expected problems; entries 23 to 32 were hit during the first apply. Not meant to be read start to finish.
6. [Cost and teardown](cost-and-teardown.md): estimated cost, the credit balance and expiry, how to check your own cost, and how to leave nothing running. Read this before you leave anything running.

The two diagrams and their editable source are in [`architecture/`](architecture/). Screenshots from the first deployment are in [`evidence/`](evidence/) and are used in the deploy, troubleshooting, Docker, architecture, cost and implementation log articles.

> [!NOTE]
> The environment was applied once, on 2026-11-24. Results from that run are labelled as measured or observed, and the screenshots back them. Service prices and the cost of the run itself are still estimates, because the lab had not been destroyed and measured when this was written.

Start at the [repository README](../README.md) if you haven't already.
