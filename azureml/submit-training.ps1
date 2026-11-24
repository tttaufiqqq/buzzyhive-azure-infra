<#
.SYNOPSIS
  Submits the BuzzyHive training job to Azure ML and streams its log.

.DESCRIPTION
  NOT RUN YET (written 24/11/2026). Run it in Windows PowerShell after lab has been applied with
  enable_ml = true. It copies the training code from the app repo into azureml\.stage\code
  (git-ignored), points the job's `code` at that folder, and submits it.

  The workspace name comes from:  terraform -chdir=lab output -raw ml_workspace_name
  Use -DryRun to print the az command without submitting anything.

.EXAMPLE
  .\azureml\submit-training.ps1 -Workspace mlw-hive-xxxxx -DryRun
#>
param(
  [Parameter(Mandatory)][string]$Workspace,
  [string]$ResourceGroup = "rg-hive-lab",
  [string]$AppRepo = $env:BUZZYHIVE_APP_REPO,   # path of the BuzzyHive application repository
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if (-not $AppRepo) { throw "Set -AppRepo or the BUZZYHIVE_APP_REPO environment variable to the application repository path." }
$mlSrc = Join-Path $AppRepo "ml"
$stage = Join-Path $PSScriptRoot ".stage\code"

foreach ($f in "train_model.py", "training_pipeline.py", "runtime.py") {
  if (-not (Test-Path (Join-Path $mlSrc $f))) { throw "Missing $f in $mlSrc. Is -AppRepo right?" }
}
if (-not (Test-Path (Join-Path $mlSrc "datasets\synthetic_readiness_training_flat_v1.csv"))) {
  throw "Missing ml\datasets\synthetic_readiness_training_flat_v1.csv in $AppRepo"
}

# Stage only what train_model.py needs: the three modules and the datasets folder.
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($f in "train_model.py", "training_pipeline.py", "runtime.py") { Copy-Item (Join-Path $mlSrc $f) $stage }
Copy-Item (Join-Path $mlSrc "datasets") (Join-Path $stage "datasets") -Recurse
Write-Host "Staged code in $stage"

az extension add --name ml --only-show-errors 2>$null | Out-Null

$create = @(
  "ml", "job", "create",
  "--file", (Join-Path $PSScriptRoot "train-job.yml"),
  "--set", "code=$stage",
  "--resource-group", $ResourceGroup,
  "--workspace-name", $Workspace,
  "--query", "name", "-o", "tsv"
)

if ($DryRun) {
  Write-Host "DRY RUN. Would run:"
  Write-Host ("az " + ($create -join " "))
  return
}

$job = az @create
if (-not $job) { throw "The job was not created." }
Write-Host "Submitted job: $job"
Write-Host "The cluster scales up from zero, so the first minutes show no output."
az ml job stream --name $job --resource-group $ResourceGroup --workspace-name $Workspace

$status = az ml job show --name $job --resource-group $ResourceGroup --workspace-name $Workspace --query status -o tsv
Write-Host "Final status: $status"
Write-Host "Next: .\azureml\register-and-package.ps1 -Workspace $Workspace -Job $job -Registry <acr name>"
