<#
.SYNOPSIS
  Builds the whole BuzzyHive environment from an empty subscription with one command:
  bootstrap, foundation, the lab (via up.ps1), the Function code, and a "No changes" proof.

.DESCRIPTION
  UNTESTED: written 25/11/2026 and never run against Azure. Run it with -DryRun first.
  Run it in Windows PowerShell. It stops and asks before every apply unless you pass -AutoApprove.

  Steps:
    1. bootstrap   terraform apply (local state): the state storage account. Its name has a random suffix.
    2. Backends    writes foundation\backend.hcl and lab\backend.hcl from the bootstrap output, and updates
                   state_storage_account_name in foundation\terraform.tfvars to the new name.
    3. foundation  terraform apply: resource group, policy, budget, identity, Entra groups, RBAC.
    4. Reserved names  recovers and purges a soft-deleted log-hive-lab workspace if one is left over
                   (troubleshooting 45).
    5. lab         scripts\up.ps1 (images, two applies, migrate, optional seed and device).
    6. Function    scripts\deploy-function.ps1 (uploads functions\forwarder).
    7. Proof       terraform plan -detailed-exitcode in all three roots: exit 0 means No changes.

  It needs foundation\terraform.tfvars and lab\terraform.tfvars (git-ignored; copies are in
  Documents\buzzyhive-backup). It never needs bootstrap\terraform.tfvars.

.PARAMETER AppRepo         Path of the application repository. Default: appRepo in scripts\local.settings.json.
.PARAMETER PusherKey       Pusher app key for the build. Default: pusher-app-key in lab\terraform.tfvars.
.PARAMETER Seed            Seed the database (throwaway admin password, printed once).
.PARAMETER RegisterDevice  IoT Hub device to register. Default: device in scripts\local.settings.json.
.PARAMETER AutoApprove     Do not ask before applying.
.PARAMETER SkipFunction    Do not upload the Function code.
.PARAMETER DryRun          Print what would happen. Runs no az, terraform, docker or WSL command and
                           writes no file.

.EXAMPLE
  .\scripts\up-all.ps1 -DryRun
  .\scripts\up-all.ps1 -Seed
#>
[CmdletBinding()]
param(
  [string]$AppRepo = $env:BUZZYHIVE_APP_REPO,
  [string]$PusherKey = $env:BUZZYHIVE_PUSHER_KEY,
  [switch]$Seed,
  [string]$RegisterDevice,
  [switch]$AutoApprove,
  [switch]$SkipFunction,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib.ps1"
$root = Split-Path $PSScriptRoot -Parent
$localSettings = Get-LocalSettings $PSScriptRoot
if (-not $RegisterDevice -and $localSettings.device) { $RegisterDevice = $localSettings.device }
$bootstrap = Join-Path $root "bootstrap"
$foundation = Join-Path $root "foundation"
$lab = Join-Path $root "lab"
$started = Get-Date

function Say([string]$Message) { Write-Host ""; Write-Host "== $Message" -ForegroundColor Cyan }
function Note([string]$Message) { Write-Host "   $Message" }
function Invoke-Tool([string]$Exe, [string[]]$ToolArgs) {
  & $Exe @ToolArgs
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($ToolArgs -join ' ') failed with exit code $LASTEXITCODE" }
}
function Get-ToolOutput([string]$Exe, [string[]]$ToolArgs) {
  $out = & $Exe @ToolArgs
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($ToolArgs -join ' ') failed with exit code $LASTEXITCODE" }
  return ($out | Out-String).Trim()
}
function Confirm-Step([string]$Question) {
  if ($AutoApprove -or $DryRun) { return }
  if ((Read-Host "$Question (type yes)") -ne "yes") { throw "Stopped: you did not type yes." }
}

# init (optionally with a backend file), plan to a file, ask, apply that exact plan.
function Invoke-RootApply([string]$Dir, [string]$Name, [bool]$UseBackend) {
  Say "terraform apply ($Name)"
  if ($DryRun) { Note "[dry run] terraform init, plan -out=$Name.tfplan, ask, apply (in $Name)"; return }
  Push-Location $Dir
  try {
    # Same retry policy as lab\up.ps1 (lib.ps1, Get-RetryPolicy): capacity, network and other errors are told apart.
    $initArgs = if ($UseBackend) { @("init", "-reconfigure", "-input=false", "-backend-config=backend.hcl") } else { @("init", "-input=false") }
    Invoke-WithRetryPolicy -What "terraform init ($Name)" -Attempt { param([bool]$AskAgain) Invoke-ToolRetryable terraform $initArgs | Out-Null }
    Invoke-WithRetryPolicy -What "The $Name apply" -Attempt {
      param([bool]$AskAgain)
      Invoke-ToolRetryable terraform @("plan", "-input=false", "-no-color", "-out=$Name.tfplan") | Out-Null
      if ($AskAgain) { Confirm-Step "Apply the $Name plan to Azure now?" }
      Invoke-ToolRetryable terraform @("apply", "-input=false", "-no-color", "$Name.tfplan") | Out-Null
    }
  } finally {
    Remove-Item "$Name.tfplan" -Force -ErrorAction SilentlyContinue   # a plan file can hold secret values
    Pop-Location
  }
}

# ---------- 0. checks ----------
Say "0. Checks"
if ($DryRun) {
  Note "[dry run] would check: az and terraform on PATH, az login, foundation\terraform.tfvars, lab\terraform.tfvars, DNS for management.azure.com, login.microsoftonline.com and registry.terraform.io"
} else {
  foreach ($c in "az", "terraform") { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c is not on PATH." } }
  $null = az account show --query id -o tsv 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Not signed in. Run: az login" }
  foreach ($f in @((Join-Path $foundation "terraform.tfvars"), (Join-Path $lab "terraform.tfvars"))) {
    if (-not (Test-Path $f)) { throw "$f is missing. Copy it back from Documents\buzzyhive-backup." }
  }
  # The third rebuild lost time to DNS failures on a campus network, so stop early, with a clear message, if names do not resolve.
  $unresolved = @(Get-UnresolvedNames @("management.azure.com", "login.microsoftonline.com", "registry.terraform.io"))
  if ($unresolved.Count -gt 0) { throw "DNS does not resolve: $($unresolved -join ', '). Fix the connection (try a phone hotspot or a public DNS server such as 1.1.1.1) and run this again. Nothing has been changed." }
  if (-not (Test-TfvarsTrue (Join-Path $lab "terraform.tfvars") "enable_function")) { Write-Warning "enable_function is not true in lab\terraform.tfvars, so the Function will not be created." }
}

# ---------- 1. bootstrap ----------
Say "1. bootstrap (state storage)"
Invoke-RootApply $bootstrap "bootstrap" $false

# ---------- 2. backends ----------
Say "2. Point foundation and lab at the new state storage"
if ($DryRun) {
  Note "[dry run] terraform output -raw backend_hcl (bootstrap), write foundation\backend.hcl (key foundation.tfstate) and lab\backend.hcl (key lab.tfstate)"
  Note "[dry run] set state_storage_account_name in foundation\terraform.tfvars to the new account name"
} else {
  $hclText = Get-ToolOutput terraform @("-chdir=$bootstrap", "output", "-raw", "backend_hcl")
  $account = Get-ToolOutput terraform @("-chdir=$bootstrap", "output", "-raw", "storage_account_name")
  [IO.File]::WriteAllText((Join-Path $foundation "backend.hcl"), (New-BackendHcl $hclText "foundation.tfstate"), $script:Utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $lab "backend.hcl"), (New-BackendHcl $hclText "lab.tfstate"), $script:Utf8NoBom)
  Set-TfvarsString (Join-Path $foundation "terraform.tfvars") "state_storage_account_name" $account
  Note "State storage account: $account"
}

# ---------- 3. foundation ----------
Invoke-RootApply $foundation "foundation" $true

# ---------- 4. reserved names ----------
Say "4. Check for a soft-deleted Log Analytics workspace (troubleshooting 45)"
if ($DryRun) {
  Note "[dry run] az monitor log-analytics workspace list-deleted-workspaces, then recover and delete --force log-hive-lab if present"
} else {
  $deleted = @(& az monitor log-analytics workspace list-deleted-workspaces --query "[].name" -o tsv 2>$null)
  $ours = @(Select-ByPrefix $deleted @("log-hive"))
  if ($ours.Count -eq 0) { Note "None of ours is soft-deleted." }
  foreach ($ws in $ours) {
    Note "Found soft-deleted $ws. Recovering it into rg-hive-lab and deleting it for good."
    Confirm-Step "Recover and permanently delete ${ws}?"
    Invoke-Tool az @("monitor", "log-analytics", "workspace", "recover", "-g", "rg-hive-lab", "-n", $ws, "-o", "none")
    Invoke-Tool az @("monitor", "log-analytics", "workspace", "delete", "-g", "rg-hive-lab", "-n", $ws, "--force", "true", "--yes")
  }
}

# ---------- 5. lab ----------
Say "5. lab (scripts\up.ps1)"
$upArgs = @{}
if ($AppRepo) { $upArgs["AppRepo"] = $AppRepo }
if ($PusherKey) { $upArgs["PusherKey"] = $PusherKey }
if ($Seed) { $upArgs["Seed"] = $true }
if ($RegisterDevice) { $upArgs["RegisterDevice"] = $RegisterDevice }
if ($AutoApprove) { $upArgs["AutoApprove"] = $true }
if ($DryRun) { $upArgs["DryRun"] = $true }
& (Join-Path $PSScriptRoot "up.ps1") @upArgs

# ---------- 6. Function code ----------
if (-not $SkipFunction) {
  Say "6. Function code (scripts\deploy-function.ps1)"
  $fnArgs = @{}
  if ($DryRun) { $fnArgs["DryRun"] = $true }
  & (Join-Path $PSScriptRoot "deploy-function.ps1") @fnArgs
}

# ---------- 7. proof ----------
Say "7. Proof: terraform plan -detailed-exitcode in all three roots (0 = No changes)"
if ($DryRun) {
  Note "[dry run] terraform plan -detailed-exitcode in bootstrap, foundation and lab"
} else {
  $results = @()
  foreach ($r in @(@("bootstrap", $bootstrap), @("foundation", $foundation), @("lab", $lab))) {
    Push-Location $r[1]
    try {
      & terraform plan -detailed-exitcode -input=false -no-color -lock=false *> $null
      $code = $LASTEXITCODE
    } finally { Pop-Location }
    $verdict = switch ($code) { 0 { "No changes" } 2 { "CHANGES PENDING" } default { "ERROR" } }
    $results += ("   {0,-11} {1}" -f $r[0], $verdict)
  }
  $results | ForEach-Object { Write-Host $_ }
  if ($results -match "CHANGES PENDING|ERROR") { Write-Warning "Not clean. Run terraform plan in that root and read the diff." }
}

Say "Done"
Note ("Took {0} minutes." -f [math]::Round(((Get-Date) - $started).TotalMinutes, 1))
Note "Everything is BILLING until you run .\scripts\down-all.ps1."
