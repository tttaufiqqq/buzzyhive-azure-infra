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

"New-PhpRunnerArgs / Get-RenameNodePhp (the device-name step)"
$phpArgs = New-PhpRunnerArgs (Get-RenameNodePhp "NODE-28ZRUR")
Check "three arguments"                       $phpArgs.Count 3
Check "php, then -r and the code as ONE argument" ($phpArgs[0] + "|" + $phpArgs[1]) 'php|-r eval(base64_decode($argv[1]));'
Check "that argument holds a space (so the CLI parser takes it as a value)" ($phpArgs[1] -match ' ') $true
Check "no argument is a bare option like -r"   (@($phpArgs | Where-Object { $_ -match '^-\S*$' }).Count) 0
Check "the payload is plain base64"           ($phpArgs[2] -match '^[A-Za-z0-9+/=]+$') $true
$decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($phpArgs[2]))
Check "decoded code names the device"         ($decoded.Contains('$id = "NODE-28ZRUR"')) $true
Check "decoded code boots Laravel"            ($decoded.Contains("bootstrap/app.php")) $true
foreach ($bad in @('NODE"; drop', 'a b', 'x', "NODE-1'")) {
  $threw = $false; try { Get-RenameNodePhp $bad | Out-Null } catch { $threw = $true }
  Check ("refused device name [" + $bad + "]") $threw $true
}

"Get-AzInvocation / Invoke-AzDirect (arguments that az.cmd cannot carry)"
$inv = Get-AzInvocation
Check "an az executable was found"            (Test-Path $inv.Exe) $true
if ($inv.Exe -like "*python.exe") {
  Check "the batch file is bypassed"          ($inv.Exe -like "*.cmd") $false
  Check "the module is started like az.cmd does" ($inv.Prefix -join " ") "-IBm azure.cli"
} else { Write-Host "  (az is not the Windows batch install here, so the direct-python path is not exercised)" }
# The real round trip, through the Azure CLI's own Python: the arguments must arrive unchanged, and the CLI's
# argument parser (argparse, the one that rejected a separate -r) must keep all of them as values of --args.
$probe = Join-Path ([IO.Path]::GetTempPath()) ("argprobe-" + [guid]::NewGuid().ToString("N") + ".py")
Set-Content -Path $probe -Encoding ASCII -Value @(
  "import argparse, sys",
  "p = argparse.ArgumentParser()",
  "p.add_argument('-n'); p.add_argument('-o'); p.add_argument('--container-name')",
  "p.add_argument('--args', nargs='+')",
  "a, unknown = p.parse_known_args(sys.argv[1:])",
  "print(len(a.args)); print(len(unknown))",
  "[print(x) for x in a.args]")
$py = if ($inv.Exe -like "*python.exe") { $inv.Exe } else { "python" }
$sent = New-PhpRunnerArgs (Get-RenameNodePhp "NODE-28ZRUR")
$got = @(& $py $probe -n job --container-name migrate --args @sent -o none)
Check "the parser keeps all three as --args"  $got[0] "3"
Check "the parser leaves nothing unrecognized" $got[1] "0"
Check "the code argument arrives unchanged"   $got[3] $sent[1]
Check "the payload arrives unchanged"         $got[4] $sent[2]
Remove-Item $probe -Force

""
if ($failed -eq 0) { Write-Host "All tests passed." -ForegroundColor Green; exit 0 }
else { Write-Host "$failed test(s) failed." -ForegroundColor Red; exit 1 }
