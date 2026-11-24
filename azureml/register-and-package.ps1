<#
.SYNOPSIS
  Registers the trained model, downloads it, and builds a flask-ml image around it.

.DESCRIPTION
  NOT RUN YET (written 24/11/2026). Run it after submit-training.ps1 finished with status Completed.

  1. Registers the job's model output as the model "buzzyhive-knn" (version auto-increments).
  2. Downloads it into azureml\out (git-ignored).
  3. Copies the app repo's ml\ folder to azureml\.stage\image and replaces model.pkl, scaler.pkl and
     model_metadata.json with the downloaded ones.
  4. With -Build: builds the image in WSL and pushes it to the registry as flask-ml:azureml-<job>.
     Docker runs only in WSL on this machine, and the registry login must already work
     (see docs/troubleshooting.md entry 26).

  It never deploys. To deploy, set images.flask in lab\terraform.tfvars to the printed tag and run
  terraform apply yourself, then check `az containerapp revision list -n flask-ml`.

  Use -DryRun to print what would happen without touching Azure.
#>
param(
  [Parameter(Mandatory)][string]$Workspace,
  [Parameter(Mandatory)][string]$Job,
  [Parameter(Mandatory)][string]$Registry,          # ACR name, e.g. acrhiveci1yu
  [string]$ResourceGroup = "rg-hive-lab",
  [string]$ModelName = "buzzyhive-knn",
  [string]$AppRepo = $env:BUZZYHIVE_APP_REPO,   # path of the BuzzyHive application repository
  [switch]$Build,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if (-not $AppRepo) { throw "Set -AppRepo or the BUZZYHIVE_APP_REPO environment variable to the application repository path." }
$out = Join-Path $PSScriptRoot "out"
$stage = Join-Path $PSScriptRoot ".stage\image"
$tag = "azureml-" + ($Job -replace "[^a-zA-Z0-9_.-]", "-").ToLower()
$image = "$Registry.azurecr.io/flask-ml:$tag"
$common = @("--resource-group", $ResourceGroup, "--workspace-name", $Workspace)

if ($DryRun) {
  Write-Host "DRY RUN. Would:"
  Write-Host "  az ml model create --name $ModelName --path azureml://jobs/$Job/outputs/model --type custom_model ..."
  Write-Host "  az ml model download --name $ModelName --version <new version> --download-path $out ..."
  Write-Host "  copy $AppRepo\ml to $stage and replace model.pkl, scaler.pkl, model_metadata.json"
  Write-Host "  wsl --cd $stage -e docker build -t $image ."
  Write-Host "  wsl -e docker push $image"
  return
}

az extension add --name ml --only-show-errors 2>$null | Out-Null

$version = az ml model create --name $ModelName --path "azureml://jobs/$Job/outputs/model" --type custom_model @common --query version -o tsv
if (-not $version) { throw "Model registration failed." }
Write-Host "Registered $ModelName version $version"

Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $out | Out-Null
az ml model download --name $ModelName --version $version --download-path $out @common | Out-Null

# The download nests the files under a folder named after the model, so search for them.
$found = @{}
foreach ($f in "model.pkl", "scaler.pkl", "model_metadata.json") {
  $hit = Get-ChildItem $out -Recurse -Filter $f | Select-Object -First 1
  if (-not $hit) { throw "$f was not in the downloaded model. Look in $out." }
  $found[$f] = $hit.FullName
}
Write-Host "Downloaded model files to $out"
Write-Host ("model_version in the new metadata: " + ((Get-Content $found["model_metadata.json"] -Raw | ConvertFrom-Json).model_version))

# Build context: the app's ml folder with the three model files replaced.
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $AppRepo "ml\*") $stage -Recurse -Force
foreach ($f in $found.Keys) { Copy-Item $found[$f] (Join-Path $stage $f) -Force }
Write-Host "Build context ready in $stage"

if ($Build) {
  wsl --cd $stage -e docker build -t $image .
  if ($LASTEXITCODE -ne 0) { throw "docker build failed." }
  wsl -e docker push $image
  if ($LASTEXITCODE -ne 0) { throw "docker push failed. Is the registry login still valid?" }
  Write-Host "Pushed $image"
} else {
  Write-Host "Not built. Re-run with -Build, or build it yourself:"
  Write-Host "  wsl --cd `"$stage`" -e docker build -t $image ."
}

Write-Host ""
Write-Host "To deploy, set this in lab\terraform.tfvars and apply:"
Write-Host "  flask = `"$image`""
Write-Host "Then check the revision, call /health, and run the app's verify_prediction_guardrails.py before relying on it."
