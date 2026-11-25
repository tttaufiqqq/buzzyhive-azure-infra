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

.PARAMETER Force         Skip typing the resource group name and the y/N question. Not recommended.
.PARAMETER DryRun        Print what would happen. Runs no az or terraform command.
.PARAMETER CleanupOnly   Skip the terraform steps and only delete the leftovers (step 5). Use it when
                         the lab is already destroyed, or after a run that stopped half way.

  Step 5 also deletes what Terraform never owned, from a short allowlist: the registry that Azure ML
  creates, and the Smart Detection action group and Failure Anomalies rule that Azure creates for
  Application Insights. Anything else left in the group is only reported, never deleted. The managed
  identity is left alone: the foundation root owns it.

.EXAMPLE
  .\scripts\down.ps1 -DryRun
  .\scripts\down.ps1
  .\scripts\down.ps1 -CleanupOnly
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-hive-lab",
  [switch]$Force,
  [switch]$DryRun,
  [switch]$CleanupOnly
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

if ($CleanupOnly) {
  Say "2 to 4. Skipped (-CleanupOnly)"
  Note "The terraform steps were not run. Only the leftovers are handled."
} else {
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
}

Say "5. Clean up the session file and check nothing is left"
Run "delete lab\zz-images.auto.tfvars" { Remove-Item $autoVars -Force -ErrorAction SilentlyContinue }
if ($DryRun) {
  Note "[dry run] az resource list --tag project=buzzyhive -o table, and az group list for ME_* groups"
  Note "[dry run] az resource list -g $ResourceGroup, then delete the allowlisted leftovers (the Azure ML registry, the Smart Detection action group, the Failure Anomalies rule) after a y/N question"
} else {
  # What Terraform never owned. The managed identity id-hive-lab-apps lives in this group but belongs
  # to the foundation root, so it stays until foundation is destroyed. Everything else here after the
  # destroy is a leftover, and only an allowlist of known ones is deleted: an unexpected resource is
  # reported and left alone.
  #  - the registry Azure ML creates on its first job (untagged, admin user on, not in the state)
  #  - the Smart Detection action group and the Failure Anomalies rule Azure creates for Application Insights
  $idType = "Microsoft.ManagedIdentity/userAssignedIdentities"
  # Windows PowerShell 5.1 returns a JSON array from ConvertFrom-Json as ONE object, so every filter below
  # would match the whole array and the delete loop would remove everything in it (this deleted the
  # foundation identity on 25/11/2026). Parse the text, then flatten to one object per resource.
  $json = (& az resource list -g $ResourceGroup --query "[].{name:name, type:type, id:id}" -o json) -join "`n"
  $all = @(ConvertFrom-Json $json | ForEach-Object { $_ })
  $bad = @($all | Where-Object { $_.name -isnot [string] -or $_.type -isnot [string] -or $_.id -isnot [string] })
  if ($bad.Count -gt 0) { throw "Unexpected data from az (an item is not a plain resource). Refusing to delete anything." }
  $owned = @($all | Where-Object { $_.type -eq $idType })
  if ($owned.Count -gt 0) { Note "Expected to remain (owned by foundation): $(($owned | ForEach-Object { $_.name }) -join ', ')" }

  $known = @($all | Where-Object {
      ($_.type -eq "Microsoft.ContainerRegistry/registries") -or
      ($_.type -eq "microsoft.alertsmanagement/smartDetectorAlertRules" -and $_.name -like "Failure Anomalies*") -or
      ($_.type -eq "microsoft.insights/actiongroups" -and $_.name -like "Application Insights Smart Detection*")
    })
  $unknown = @($all | Where-Object { $_.type -ne $idType -and (@($known | ForEach-Object { $_.id }) -notcontains $_.id) })

  if (@($known | Where-Object { $_.type -eq $idType }).Count -gt 0) { throw "The managed identity is in the delete list. Refusing to delete anything." }
  if ($known.Count -gt 0) {
    Write-Host "   Leftovers Terraform never owned, safe to delete:"
    $known | ForEach-Object { Write-Host ("     {0}  [{1}]" -f $_.name, $_.type) }
    $go = $Force
    if (-not $go) { $go = ((Read-Host "   Delete these $($known.Count) now? (y/N)") -match "^[yY]") }
    if ($go) {
      # The rule uses the action group, so it goes first; the registry is independent.
      $rank = @{ "microsoft.alertsmanagement/smartdetectoralertrules" = 1; "microsoft.insights/actiongroups" = 2 }
      foreach ($r in ($known | Sort-Object { if ($rank.ContainsKey($_.type.ToLower())) { $rank[$_.type.ToLower()] } else { 3 } })) {
        Note "deleting $($r.name)"
        & az resource delete --ids $r.id --only-show-errors
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not delete $($r.name). Delete it by hand: az resource delete --ids <id>" }
      }
    } else {
      Note "Left in place. Delete them by hand: az resource delete --ids <id>"
    }
  }
  if ($unknown.Count -gt 0) {
    Write-Warning "Not on the allowlist, so left alone. Check each one and delete it yourself if it is yours:"
    $unknown | ForEach-Object { Write-Host ("     {0}  [{1}]" -f $_.name, $_.type) }
  }
  $left = @(& az resource list -g $ResourceGroup --query "[].name" -o tsv)
  Note "Now in ${ResourceGroup}: $(($left) -join ', ')"
  Write-Host "   Resources still tagged project=buzzyhive (the foundation identity is expected):"
  & az resource list --tag project=buzzyhive --query "[].{name:name, group:resourceGroup, type:type}" -o table
  # Filter in PowerShell, not in the az query: the quoting of a JMESPath filter breaks in some shells.
  $managed = ((& az group list --query "[].name" -o tsv) | Where-Object { $_ -like "ME_*" }) -join ", "
  if ($managed) { Write-Warning "A managed resource group is still there: $managed. Container Apps normally removes it a few minutes after the environment goes." }
}

Say "Done"
Note "The lab is gone. Cost data lags by 8 to 24 hours: check Cost analysis tomorrow."
