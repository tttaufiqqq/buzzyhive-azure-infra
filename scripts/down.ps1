<#
.SYNOPSIS
  Takes the BuzzyHive lab down with one command: shows what will be destroyed, asks you to type
  the resource group name, destroys the lab root, and checks nothing is left.

.DESCRIPTION
  UNTESTED: written 24/11/2026 and never run against Azure. Run it with -DryRun first.
  Run it in Windows PowerShell.

  It destroys the lab root only. It keeps bootstrap (state storage) and foundation (resource group,
  policy, budget, identity). It never touches those. Everything made by hand inside the lab (the
  registry admin user, the AcrPush role, IoT devices, seeded data) goes with the lab.

  If the destroy fails with ScopeLocked, set enable_locks = false in foundation and apply it first
  (troubleshooting 3). Locks are off in the lab by default.

.PARAMETER Force    Skip typing the resource group name. Not recommended.
.PARAMETER DryRun   Print what would happen. Runs no az or terraform command.

.EXAMPLE
  .\scripts\down.ps1 -DryRun
  .\scripts\down.ps1
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-hive-lab",
  [switch]$Force,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$lab = Join-Path $root "lab"
$autoVars = Join-Path $lab "zz-images.auto.tfvars"

function Say([string]$Message) { Write-Host ""; Write-Host "== $Message" -ForegroundColor Cyan }
function Note([string]$Message) { Write-Host "   $Message" }
function Run([string]$What, [scriptblock]$Block) {
  if ($DryRun) { Note "[dry run] $What"; return }
  & $Block
}
function Invoke-Tool([string]$Exe, [string[]]$ToolArgs) {
  & $Exe @ToolArgs
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($ToolArgs -join ' ') failed with exit code $LASTEXITCODE" }
}

Say "0. Checks"
if ($DryRun) {
  Note "[dry run] would check: az and terraform on PATH, az login, lab\backend.hcl"
} else {
  foreach ($c in "az", "terraform") {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c is not on PATH." }
  }
  $null = az account show --query id -o tsv 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Not signed in. Run: az login" }
  if (-not (Test-Path (Join-Path $lab "backend.hcl"))) { throw "lab\backend.hcl is missing." }
}

Say "1. What is in $ResourceGroup now"
Run "az resource list -g $ResourceGroup -o table" {
  & az resource list -g $ResourceGroup --query "[].{name:name, type:type}" -o table
}

Say "2. terraform init, take the Key Vault secrets out of state, and a destroy plan (lab)"
Run "terraform init -reconfigure; terraform state rm azapi_resource.secret (only if present); terraform plan -destroy -out=destroy.tfplan" {
  Push-Location $lab
  try {
    Invoke-Tool terraform @("init", "-reconfigure", "-input=false", "-backend-config=backend.hcl")
    # The Key Vault secrets are azapi resources, written through Azure's management API. That API can
    # create a secret but not delete one: DELETE answers 405 DeleteNotSupported (found on 25/11/2026,
    # the first time this script ran), and the vault cannot be deleted until the secrets are. A
    # secret goes away with its vault, so remove them from the state only. Nothing in Azure changes.
    $secrets = @(& terraform state list 2>$null | Where-Object { $_ -like "azapi_resource.secret*" })
    if ($secrets.Count -gt 0) {
      Note "Removing $($secrets.Count) Key Vault secrets from the state. They are deleted with the vault."
      Invoke-Tool terraform @("state", "rm", "azapi_resource.secret")
    }
    Invoke-Tool terraform @("plan", "-destroy", "-input=false", "-no-color", "-out=destroy.tfplan")
  } finally { Pop-Location }
}

Say "3. Confirm"
if ($DryRun) {
  Note "[dry run] would ask you to type the resource group name: $ResourceGroup"
} elseif (-not $Force) {
  Write-Host "   This DESTROYS the lab: the apps, MySQL (and its data), the registry, the Key Vault secrets and the IoT Hub." -ForegroundColor Yellow
  Write-Host "   bootstrap and foundation are kept." -ForegroundColor Yellow
  $typed = Read-Host "   Type the resource group name to continue"
  if ($typed -ne $ResourceGroup) { throw "Stopped: that was not '$ResourceGroup'." }
}

Say "4. Destroy (lab)"
Run "terraform apply destroy.tfplan" {
  Push-Location $lab
  try {
    Invoke-Tool terraform @("apply", "-input=false", "-no-color", "destroy.tfplan")
  } catch {
    Write-Warning "The destroy failed. If the message says ScopeLocked, set enable_locks = false in foundation, apply it, and run this again."
    throw
  } finally {
    Remove-Item "destroy.tfplan" -Force -ErrorAction SilentlyContinue
    Pop-Location
  }
}

Say "5. Clean up the session file and check nothing is left"
Run "delete lab\zz-images.auto.tfvars" { Remove-Item $autoVars -Force -ErrorAction SilentlyContinue }
if ($DryRun) {
  Note "[dry run] az resource list --tag project=buzzyhive -o table, and az group list for ME_* groups"
  Note "[dry run] az resource list -g $ResourceGroup (anything left there was not created by Terraform)"
} else {
  # Azure ML creates its own, untagged Container Registry on the first job (24/11/2026). It is not in
  # Terraform state, so destroy leaves it behind, and it keeps billing. The resource group is kept,
  # so anything still inside it now is a leftover.
  # The managed identity id-hive-lab-apps lives in this group but belongs to the foundation root, so
  # it is expected to remain until foundation is destroyed. Everything else is a leftover.
  $all = & az resource list -g $ResourceGroup --query "[].{name:name, type:type}" -o json | ConvertFrom-Json
  $mine = @($all | Where-Object { $_.type -ne "Microsoft.ManagedIdentity/userAssignedIdentities" })
  $owned = @($all | Where-Object { $_.type -eq "Microsoft.ManagedIdentity/userAssignedIdentities" })
  if ($owned.Count -gt 0) { Note "Expected to remain (owned by foundation): $(($owned | ForEach-Object { $_.name }) -join ', ')" }
  if ($mine.Count -gt 0) {
    Write-Warning "Still inside $ResourceGroup after the destroy. Terraform did not create these, so check each and delete it yourself:"
    $mine | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "   A leftover registry: az acr delete -n <name> -g $ResourceGroup --yes" -ForegroundColor Yellow
    Write-Host "   Azure also creates some resources itself for Application Insights (a Smart Detection action group, a Failure Anomalies rule)." -ForegroundColor Yellow
  } else {
    Note "Nothing else is left in $ResourceGroup."
  }
  Write-Host "   Resources still tagged project=buzzyhive (the foundation identity is expected):"
  & az resource list --tag project=buzzyhive --query "[].{name:name, group:resourceGroup, type:type}" -o table
  # Filter in PowerShell, not in the az query: the quoting of a JMESPath filter breaks in some shells.
  $managed = ((& az group list --query "[].name" -o tsv) | Where-Object { $_ -like "ME_*" }) -join ", "
  if ($managed) { Write-Warning "A managed resource group is still there: $managed. Container Apps normally removes it a few minutes after the environment goes." }
}

Say "Done"
Note "The lab is gone. Cost data lags by 8 to 24 hours: check Cost analysis tomorrow."
