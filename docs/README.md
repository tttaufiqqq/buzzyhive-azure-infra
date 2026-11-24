# Docs index

Read these in order.

1. [Architecture](architecture.md): what this project deploys, how data flows, and why each design decision was made. Read this first to understand the system before touching anything.
2. [Docker images](docker.md): why the two images are built the way they are, with measured sizes. Read this to understand the images before changing them.
3. [Deploy, redeploy, and destroy](deploy.md): the planned steps to stand it up, change it, and tear it down. Read this before running Terraform.
4. [Implementation log](implementation-log.md): the decisions made, the timeline, the problems found before deployment and the lessons so far. Read this for the story behind the decisions.
5. [Troubleshooting](troubleshooting.md): symptom-to-fix reference for problems expected from the design. Not meant to be read start to finish.
6. [Cost and teardown](cost-and-teardown.md): estimated cost, how to check your own, and how to leave nothing running. Read this before you leave anything running.

The two diagrams and their editable source are in [`architecture/`](architecture/).

> [!NOTE]
> Nothing has been deployed yet. Where these documents give numbers or problems, they are estimates and expectations, and they say so.

Start at the [repository README](../README.md) if you haven't already.
