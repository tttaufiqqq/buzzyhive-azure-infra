<#
.SYNOPSIS
  Removes the whole BuzzyHive environment with one command: the lab (via down.ps1), then foundation,
  then bootstrap, then checks that nothing of the project is left, including soft-deleted names.

.DESCRIPTION
  UNTESTED as a whole: written 25/11/2026. The three destroys it wraps were each run by hand on
  25/11/2026. Run it with -DryRun first. Run it in Windows PowerShell.

  You confirm once, up front, by typing DESTROY ALL. After that nothing else asks.
  It keeps the git-ignored tfvars files, so up-all.ps1 can build everything again. Copy them to
  Documents\buzzyhive-backup before you tear down (they are the only copy of the secrets).

  It refuses to destroy foundation if rg-hive-lab still holds anything except the managed identity,
  and it refuses to destroy bootstrap if foundation failed.

.PARAMETER DryRun   Print what would happen. Runs no az or terraform command.
.EXAMPLE
  .\scripts\down-all.ps1 -DryRun
  .\scripts\down-all.ps1
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib.ps1"
$root = Split-Path $PSScriptRoot -Parent
$bootstrap = Join-Path $root "bootstrap"
$foundation = Join-Path $root "foundation"
$rg = "rg-hive-lab"
$identityType = "Microsoft.ManagedIdentity/userAssignedIdentities"
$started = Get-Date

function Say([string]$Message) { Write-Host ""; Write-Host "== $Message" -ForegroundColor Cyan }
function Note([string]$Message) { Write-Host "   $Message" }
function Invoke-Tool([string]$Exe, [string[]]$ToolArgs) {
  & $Exe @ToolArgs
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($ToolArgs -join ' ') failed with exit code $LASTEXITCODE" }
}

# plan -destroy to a file, then apply exactly that.
function Invoke-RootDestroy([string]$Dir, [string]$Name, [bool]$UseBackend) {
  Say "Destroy $Name"
  if ($DryRun) { Note "[dry run] terraform init, plan -destroy -out=$Name-destroy.tfplan, apply (in $Name)"; return }
  Push-Location $Dir
  try {
    if ($UseBackend) { Invoke-Tool terraform @("init", "-reconfigure", "-input=false", "-backend-config=backend.hcl") }
    else { Invoke-Tool terraform @("init", "-input=false") }
    Invoke-Tool terraform @("plan", "-destroy", "-input=false", "-no-color", "-out=$Name-destroy.tfplan")
    Invoke-Tool terraform @("apply", "-input=false", "-no-color", "$Name-destroy.tfplan")
  } finally {
    Remove-Item "$Name-destroy.tfplan" -Force -ErrorAction SilentlyContinue
    Pop-Location
  }
}

# ---------- 0. checks and the one confirmation ----------
Say "0. Checks"
if ($DryRun) {
  Note "[dry run] would check: az and terraform on PATH, az login, foundation\backend.hcl, and ask you to type DESTROY ALL"
} else {
  foreach ($c in "az", "terraform") { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c is not on PATH." } }
  $null = az account show --query id -o tsv 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Not signed in. Run: az login" }
  if (-not (Test-Path (Join-Path $foundation "backend.hcl"))) { throw "foundation\backend.hcl is missing, so foundation's state cannot be reached." }
  Write-Host ""
  Write-Host "   This DESTROYS everything: the apps, MySQL and its data, the registry, Key Vault, IoT Hub," -ForegroundColor Yellow
  Write-Host "   then the policies, budget, identity and Entra groups, then the Terraform state storage." -ForegroundColor Yellow
  Write-Host "   Your tfvars files stay, so up-all.ps1 can rebuild. Are they backed up in Documents\buzzyhive-backup?" -ForegroundColor Yellow
  if ((Read-Host "   Type DESTROY ALL to continue") -cne "DESTROY ALL") { throw "Stopped: you did not type DESTROY ALL." }
}

# ---------- 1. lab ----------
Say "1. lab (scripts\down.ps1)"
$downArgs = @{}
if ($DryRun) { $downArgs["DryRun"] = $true } else { $downArgs["Force"] = $true }
& (Join-Path $PSScriptRoot "down.ps1") @downArgs

# ---------- 2. guard ----------
Say "2. Guard: is anything except the managed identity left in $rg ?"
if ($DryRun) {
  Note "[dry run] az resource list -g $rg, refuse to go on if anything but the identity is there"
} else {
  $lines = @(& az resource list -g $rg --query "[].[name,type]" -o tsv 2>$null)
  $foreign = @(Get-NonIdentityResources $lines $identityType)
  if ($foreign.Count -gt 0) {
    $foreign | ForEach-Object { Write-Host ("   left: {0}   {1}" -f $_.Name, $_.Type) -ForegroundColor Yellow }
    throw "Stopping before foundation. Delete or explain these first, then run this script again."
  }
  Note "Only the identity (or nothing) is left. Foundation owns the identity."
}

# ---------- 3. foundation, 4. bootstrap ----------
Invoke-RootDestroy $foundation "foundation" $true
Invoke-RootDestroy $bootstrap "bootstrap" $false

# ---------- 5. what is left ----------
Say "5. What is left"
if ($DryRun) {
  Note "[dry run] az group list, az resource list --tag project=buzzyhive, soft-deleted Key Vaults and workspaces with our names"
} else {
  Note "Resource groups (only NetworkWatcherRG should remain, Azure makes it itself):"
  & az group list --query "[].name" -o tsv | ForEach-Object { Note "  $_" }
  Note "Resources tagged project=buzzyhive:"
  $tagged = @(& az resource list --tag project=buzzyhive --query "[].name" -o tsv 2>$null)
  if ($tagged.Count -eq 0) { Note "  none" } else { $tagged | ForEach-Object { Write-Warning "  still there: $_" } }
  $kv = @(Select-ByPrefix @(& az keyvault list-deleted --query "[].name" -o tsv 2>$null) @("kv-hive", "kvml-hive"))
  $ws = @(Select-ByPrefix @(& az monitor log-analytics workspace list-deleted-workspaces --query "[].name" -o tsv 2>$null) @("log-hive"))
  if ($kv.Count -eq 0 -and $ws.Count -eq 0) { Note "No soft-deleted Key Vault or workspace of ours." }
  foreach ($n in $kv) { Write-Warning "Soft-deleted Key Vault $n (purge: az keyvault purge -n $n)" }
  foreach ($n in $ws) { Write-Warning "Soft-deleted workspace $n (up-all.ps1 step 4 handles it)" }
}

Say "Done"
Note ("Took {0} minutes. Cost data lags by 8 to 24 hours: check Cost analysis tomorrow." -f [math]::Round(((Get-Date) - $started).TotalMinutes, 1))
Note "Rebuild with .\scripts\up-all.ps1"
