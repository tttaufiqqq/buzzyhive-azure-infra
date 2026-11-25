# Tests for scripts\lib.ps1. No Azure access. Run in Windows PowerShell 5.1, the shell the project uses:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\lib.tests.ps1
. "$PSScriptRoot\..\lib.ps1"

$failed = 0
function Check([string]$Name, $Actual, $Expected) {
  if ($Actual -eq $Expected) { Write-Host ("  ok    " + $Name) }
  else { Write-Host ("  FAIL  " + $Name + "  expected [" + $Expected + "] got [" + $Actual + "]") -ForegroundColor Red; $script:failed++ }
}
"PowerShell $($PSVersionTable.PSVersion)"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("libtest-" + [guid]::NewGuid().ToString("N") + ".tfvars")
$crlf = "`r`n"
$sample = 'subscription_id = "00000000-0000-0000-0000-000000000000"' + $crlf +
          'state_resource_group_name  = "rg-hive-iac"   # keeps this comment' + $crlf +
          'state_storage_account_name = "sthivetfOLD01"' + $crlf +
          'enable_function = true # on' + $crlf +
          'enable_ml       = false' + $crlf +
          'app_secrets = {' + $crlf +
          '  pusher-app-key     = "KEY123"' + $crlf +
          '  iot-api-key        = "SECRET"' + $crlf +
          '}' + $crlf
[IO.File]::WriteAllText($tmp, $sample, (New-Object System.Text.UTF8Encoding $false))

"Get-TfvarsString / Test-TfvarsTrue"
Check "reads a simple string"            (Get-TfvarsString $tmp "state_storage_account_name") "sthivetfOLD01"
Check "reads a hyphenated key in a map"  (Get-TfvarsString $tmp "pusher-app-key") "KEY123"
Check "missing key gives null"           ($null -eq (Get-TfvarsString $tmp "nope")) $true
Check "true with a trailing comment"     (Test-TfvarsTrue $tmp "enable_function") $true
Check "false is not true"                (Test-TfvarsTrue $tmp "enable_ml") $false
Check "missing is not true"              (Test-TfvarsTrue $tmp "enable_nothing") $false

"Set-TfvarsString"
Set-TfvarsString $tmp "state_storage_account_name" "sthivetfNEW99"
$after = [IO.File]::ReadAllText($tmp)
Check "value replaced"                   (Get-TfvarsString $tmp "state_storage_account_name") "sthivetfNEW99"
Check "other lines untouched"            ($after.Contains('state_resource_group_name  = "rg-hive-iac"   # keeps this comment')) $true
Check "line endings kept (CRLF)"         ($after.Contains("sthivetfNEW99`"" + $crlf + "enable_function")) $true
Check "secret map untouched"             (Get-TfvarsString $tmp "iot-api-key") "SECRET"
Check "no byte order mark added"         ($after[0] -ne [char]0xFEFF) $true
$threw = $false; try { Set-TfvarsString $tmp "not_there" "x" } catch { $threw = $true }
Check "missing key throws"               $threw $true
Remove-Item $tmp -Force

"New-BackendHcl"
$bootstrapOut = "resource_group_name  = `"rg-hive-iac`"`nstorage_account_name = `"sthivetfabc12`"`ncontainer_name       = `"tfstate`"`nuse_azuread_auth     = true`n"
$hcl = New-BackendHcl $bootstrapOut "lab.tfstate"
Check "contains the account name"        ($hcl -match 'sthivetfabc12') $true
Check "exactly one key line"             ((([regex]::Matches($hcl, '(?m)^key\s*=')).Count)) 1
Check "key value is right"               ($hcl -match 'key\s+= "lab.tfstate"') $true
$threw = $false; try { New-BackendHcl ($bootstrapOut + 'key = "x"') "lab.tfstate" } catch { $threw = $true }
Check "a second key line is refused"     $threw $true
$threw = $false; try { New-BackendHcl "garbage" "lab.tfstate" } catch { $threw = $true }
Check "garbage is refused"               $threw $true

"Get-NonIdentityResources (the check before foundation is destroyed)"
$idType = "Microsoft.ManagedIdentity/userAssignedIdentities"
$onlyId = @("id-hive-lab-apps`t$idType")
Check "only the identity: nothing foreign"   ((Get-NonIdentityResources $onlyId $idType).Count) 0
$withLeft = @("id-hive-lab-apps`t$idType", "7248ea5f`tMicrosoft.ContainerRegistry/registries", "", "ag`tmicrosoft.insights/actiongroups")
$left = @(Get-NonIdentityResources $withLeft $idType)
Check "two foreign resources found"          $left.Count 2
Check "the identity is not in the list"      (@($left | Where-Object { $_.Type -eq $idType }).Count) 0
Check "an empty group has none"              ((Get-NonIdentityResources @() $idType).Count) 0

"Select-ByPrefix (soft-deleted names that are ours)"
$deleted = @("log-pldns-dev-sea", "log-hive-lab", "cacheaside-xrckov-law", "kv-lab-03", "kv-hive-ci1yu")
Check "finds ours by prefix"                 ((Select-ByPrefix $deleted @("log-hive", "kv-hive", "kvml-hive")) -join ",") "log-hive-lab,kv-hive-ci1yu"
Check "other projects are not matched"       ((Select-ByPrefix @("log-pldns-dev-sea", "kv-lab-03") @("log-hive", "kv-hive")).Count) 0

""
if ($failed -eq 0) { Write-Host "All tests passed." -ForegroundColor Green; exit 0 }
else { Write-Host "$failed test(s) failed." -ForegroundColor Red; exit 1 }
