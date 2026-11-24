<#
.SYNOPSIS
  Uploads the IoT Hub forwarder code (functions/forwarder) to the Function app that lab/iot.tf creates.

.DESCRIPTION
  UNTESTED against Azure: written 25/11/2026. Run it with -DryRun first. Run it in Windows PowerShell.

  Terraform creates the Function app (set enable_function = true and function_api_key in
  lab/terraform.tfvars, then apply lab). This script then zips the code and uploads it with a remote
  build, so Azure installs requirements.txt itself. It uses Python to make the zip, because Windows
  PowerShell 5.1 Compress-Archive writes backslashes into entry names, which a Linux host can mishandle.

.PARAMETER ResourceGroup  Resource group of the lab. Default rg-hive-lab.
.PARAMETER FunctionName   Name of the Function app. Default: the function_name output of the lab root.
.PARAMETER DryRun         Print what would happen. Runs no az command and uploads nothing.

.EXAMPLE
  .\scripts\deploy-function.ps1 -DryRun
  .\scripts\deploy-function.ps1
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-hive-lab",
  [string]$FunctionName,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$lab = Join-Path $root "lab"
$source = Join-Path $root "functions\forwarder"
$zip = Join-Path ([IO.Path]::GetTempPath()) "buzzyhive-forwarder.zip"
$files = @("function_app.py", "forward.py", "host.json", "requirements.txt")

function Say([string]$Message) { Write-Host ""; Write-Host "== $Message" -ForegroundColor Cyan }
function Note([string]$Message) { Write-Host "   $Message" }

Say "0. Checks"
foreach ($tool in @("az", "python")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not on PATH." }
}
foreach ($f in $files) {
  if (-not (Test-Path (Join-Path $source $f))) { throw "Missing $f in $source" }
}
if (-not $DryRun) {
  & az account show --query id -o none 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Not signed in. Run: az login" }
}
Note "source: $source ($($files -join ', '))"

Say "1. Find the Function app"
if (-not $FunctionName) {
  if ($DryRun) {
    $FunctionName = "<function_name output of the lab root>"
    Note "[dry run] terraform -chdir=lab output -json function_name"
  } else {
    $json = & terraform "-chdir=$lab" output -json function_name 2>$null
    $FunctionName = if ($json) { $json | ConvertFrom-Json } else { $null }
    if (-not $FunctionName) {
      throw "No function_name output. Set enable_function = true and function_api_key in lab/terraform.tfvars, apply lab, then run this again (or pass -FunctionName)."
    }
  }
}
Note "Function app: $FunctionName in $ResourceGroup"

Say "2. Build the zip"
if ($DryRun) {
  Note "[dry run] python -m zipfile -c $zip $($files -join ' ')   (run inside $source)"
} else {
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Push-Location $source
  try {
    & python -m zipfile -c $zip @files
    if ($LASTEXITCODE -ne 0) { throw "python -m zipfile failed." }
  } finally { Pop-Location }
  & python -m zipfile -l $zip
}

Say "3. Upload with a remote build"
if ($DryRun) {
  Note "[dry run] az functionapp deployment source config-zip -g $ResourceGroup -n $FunctionName --src $zip --build-remote true"
} else {
  & az functionapp deployment source config-zip -g $ResourceGroup -n $FunctionName --src $zip --build-remote true --only-show-errors -o none
  if ($LASTEXITCODE -ne 0) { throw "The upload failed. See troubleshooting, and read the deployment log in the portal (Deployment Center)." }
}

Say "4. Check the function is registered"
if ($DryRun) {
  Note "[dry run] az functionapp function list -g $ResourceGroup -n $FunctionName (up to 3 minutes, looking for forward_reading)"
} else {
  $found = $false
  for ($i = 1; $i -le 12 -and -not $found; $i++) {
    $names = (& az functionapp function list -g $ResourceGroup -n $FunctionName --query "[].name" -o tsv 2>$null | Out-String)
    if ($names -match "forward_reading") { $found = $true } else { Start-Sleep -Seconds 15 }
  }
  if (-not $found) { Write-Warning "forward_reading is not listed after 3 minutes. Check the app's logs and Deployment Center in the portal." }
  else { Note "forward_reading is registered." }
}

Say "Done"
Note "Next: send a reading through IoT Hub with scripts/simulate_device.py, then check that it reached Laravel."
