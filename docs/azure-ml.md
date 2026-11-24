# Train the model in Azure ML

This article explains how the readiness model is meant to be retrained in Azure Machine Learning, what was checked locally, and what has not been run.

> [!NOTE]
> **Nothing here has run on Azure yet.** The job files and scripts were written on 24/11/2026 and checked only by parsing them and by running the training command on a laptop. The workspace has never been created (`enable_ml = false`), so Azure ML in Malaysia West, the workspace with its own Key Vault, and the compute cluster are all unverified.

## 1. What is in place

| Piece | Where | State |
|---|---|---|
| Workspace, its own Key Vault, a compute cluster that scales to zero | `lab/ml.tf` | Written, never applied. Off by default |
| Training code | App repo, `ml/train_model.py` and `ml/training_pipeline.py` | Exists. Takes `--dataset`, `--candidate` and `--output-dir` |
| Conda environment | `azureml/environment.yml` | Written. Pins `scikit-learn==1.8.0` to match the serving image |
| Command job | `azureml/train-job.yml` | Written, parses. Not submitted |
| Submit script | `azureml/submit-training.ps1` | Written, `-DryRun` works. Not run against Azure |
| Register, download and build script | `azureml/register-and-package.ps1` | Written, `-DryRun` works. Not run against Azure |

The workspace gets its own Key Vault because the main one has public access disabled, which a workspace cannot use. Models are served by `flask-ml` in Container Apps, not by a managed online endpoint, because an endpoint bills all the time.

## 2. What the local check found

The job's command was run on a laptop with the same scikit-learn version (1.8.0):

```
python train_model.py --dataset synthetic_flat --candidate knn_k7_distance --output-dir <dir>
```

It trained a KNN with `k = 7` and distance weights on 1600 rows. Its scaler ranges equal the `feature_bounds` in the app's `ml/model_metadata.json`. So the metadata describes this model.

**The `model.pkl` and `scaler.pkl` committed next to that metadata are not this model.** Loading them shows:

| | Committed pickles | `model_metadata.json` and the retrain |
|---|---|---|
| Algorithm | KNN, `k = 1`, uniform weights | KNN, `k = 7`, distance weights |
| Training rows | 140 | 1600 |
| `mq2_value` scaler range | 37 to 164 | 44 to 245 |

The two files are byte-different, and 943 of the 1600 training rows get a different prediction. The version string in the metadata is identical in both, so nothing in the app would have flagged this. The flask-ml image copies the committed pickles, so the deployed model is the older one.

What this means:

- **Retraining is not a no-op.** It changes the model in service. That could be a fix, since the retrained model matches its own documentation, but it needs a deliberate check before it replaces anything.
- **Compare before deploying.** Run the app's `verify_prediction_guardrails.py` against both models and look at a few known readings.
- **The "ready" readings for the Telegram test depend on the model.** Find them with the model that will be in service. See `progress.md` for the order of work.
- **This is a finding about the app repository**, not only about Azure. Committing freshly trained pickles there, or removing the stale ones, is the app owner's call.

## 3. The plan

1. In `lab/terraform.tfvars`, set `enable_ml = true` and `ml_vm_size = "Standard_DS2_v2"`. The default `Standard_DS3_v2` has 4 vCPUs and would use the whole quota. A small KNN needs far less. Apply `lab` yourself.
2. `az extension add -n ml`, set `$env:BUZZYHIVE_APP_REPO` to the path of the application repository, then run `.\azureml\submit-training.ps1 -Workspace <name from terraform output>`. The cluster scales up from zero, so expect a few minutes with no log output.
3. Run `.\azureml\register-and-package.ps1 -Workspace <name> -Job <job name> -Registry <acr name> -Build`. It registers the model as `buzzyhive-knn`, downloads it, builds a flask-ml image around it in WSL and pushes `flask-ml:azureml-<job>`. It does not deploy.
4. Compare with the model currently in service (section 2). If it passes, set `images.flask` to the new tag, apply, and check `az containerapp revision list -n flask-ml` as well as `/health`.
5. Take screenshots (workspace, compute cluster, the job and its log, the registered model, the new image tag and revision) and add them to `evidence/`.
6. `terraform destroy` removes the workspace, its vault and the registered model. Keep the log, the metrics and the screenshots in the repo.

## 4. Risks and unknowns

- **Region.** Azure ML in Malaysia West has not been checked. The provider is registered, but that does not prove the workspace and compute are offered there.
- **Workspace with its own public Key Vault**, and the purge settings on destroy, are described in `lab/ml.tf` as "VERIFY". Expect first-apply errors and record them in [troubleshooting](troubleshooting.md).
- **Quota.** The subscription has 4 vCPUs in the DSv2 family. One 2 vCPU node fits.
- **The conda file and base image are unverified.** The environment uses the `openmpi4.1.2-ubuntu20.04` base image with Python 3.12 from conda-forge. If the build fails, change the base image first.
- **The data is synthetic.** This is a pipeline exercise, not a modelling one, as the README says.
- **The scripts were never run against Azure.** Treat any `az ml` flag that fails as a bug in the script, and fix it here.
- **Cost** should be small. The workspace is free, the cluster bills only while a job runs, and storage and the vault are cents. This is an estimate, not a measurement. Check Cost analysis after the destroy.
