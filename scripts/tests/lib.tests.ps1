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

"Get-RetryPolicy (which wait for which error)"
$cap = Get-RetryPolicy "Error: creating MySQL Flexible Server: Code=`"InsufficientCapacityForPlacement`""
Check "capacity: kind"                        $cap.Kind "capacity"
Check "capacity: 6 retries, 300 seconds"      ("$($cap.MaxRetries)/$($cap.WaitSeconds)") "6/300"
$net1 = Get-RetryPolicy "retrieving the keys: connection may have been reset"
$net2 = Get-RetryPolicy "dial tcp: lookup registry.terraform.io: no such host"
$net3 = Get-RetryPolicy "received unexpected EOF while pushing; net/http: timeout awaiting response headers"
$net4 = Get-RetryPolicy "ERROR: Could not connect to the registry login server 'x.azurecr.io'"
Check "connection reset is a network error"   $net1.Kind "network"
Check "no such host is a network error"       $net2.Kind "network"
Check "a push timeout is a network error"     $net3.Kind "network"
Check "an unreachable registry is a network error" $net4.Kind "network"
Check "network: 5 retries, 30 seconds"        ("$($net1.MaxRetries)/$($net1.WaitSeconds)") "5/30"
$oth = Get-RetryPolicy "Error: 412 Precondition Failed"
Check "anything else: one retry, 30 seconds"  ("$($oth.Kind)/$($oth.MaxRetries)/$($oth.WaitSeconds)") "other/1/30"
Check "capacity wins over network wording"    (Get-RetryPolicy "InsufficientCapacityForPlacement ... connection reset").Kind "capacity"

"Invoke-WithRetryPolicy (no sleeping: the wait is recorded)"
function New-RetryableError([string]$Text) {
  $e = New-Object System.Exception "failed"; $e.Data["Output"] = $Text; return $e
}
$script:waits = @(); $script:calls = 0; $script:asks = @()
$recordWait = { param($s) $script:waits += $s }
# capacity twice, then success: two waits of 300 s, and nobody is asked again
Invoke-WithRetryPolicy -What "t" -Wait $recordWait -Attempt {
  param([bool]$AskAgain)
  $script:calls++; $script:asks += $AskAgain
  if ($script:calls -le 2) { throw (New-RetryableError "InsufficientCapacityForPlacement") }
} 3>$null
Check "capacity x2 then success: 3 calls"     $script:calls 3
Check "waits were 300 and 300"                ($script:waits -join ",") "300,300"
Check "asked first, then not after capacity"  ($script:asks -join ",") "True,False,False"
# another kind of error twice: one retry, then it gives up with the error
$script:waits = @(); $script:calls = 0; $script:asks = @()
$threw = $false
try { Invoke-WithRetryPolicy -What "t" -Wait $recordWait -Attempt { param([bool]$AskAgain) $script:calls++; $script:asks += $AskAgain; throw (New-RetryableError "412 Precondition Failed") } 3>$null } catch { $threw = $true }
Check "other: threw after the second call"    ($threw -and $script:calls -eq 2) $true
Check "other: one wait of 30 s"               ($script:waits -join ",") "30"
Check "other: asked again on the retry"       ($script:asks -join ",") "True,True"
# network: five retries, so six calls, then it gives up
$script:waits = @(); $script:calls = 0
$threw = $false
try { Invoke-WithRetryPolicy -What "t" -Wait $recordWait -Attempt { param([bool]$AskAgain) $script:calls++; throw (New-RetryableError "connection may have been reset") } 3>$null } catch { $threw = $true }
Check "network: 6 calls then gives up"        ($threw -and $script:calls -eq 6) $true
# capacity never clears: 6 retries (7 calls) of 300 s, about 30 minutes
$script:waits = @(); $script:calls = 0
$threw = $false
try { Invoke-WithRetryPolicy -What "t" -Wait $recordWait -Attempt { param([bool]$AskAgain) $script:calls++; throw (New-RetryableError "InsufficientCapacityForPlacement") } 3>$null } catch { $threw = $true }
Check "capacity: 7 calls then gives up"       ($threw -and $script:calls -eq 7) $true
Check "capacity: waited 30 minutes in all"    (($script:waits | Measure-Object -Sum).Sum) 1800
# the person said no: never retried
$script:waits = @(); $script:calls = 0
$threw = $false
try { Invoke-WithRetryPolicy -What "t" -Wait $recordWait -Attempt { param([bool]$AskAgain) $script:calls++; throw "Stopped: you did not type yes." } 3>$null } catch { $threw = $true }
Check "Stopped: is not retried"               ($threw -and $script:calls -eq 1 -and $script:waits.Count -eq 0) $true
# an error from the script itself has no captured output: its message is used
$script:calls = 0; $script:waits = @()
Invoke-WithRetryPolicy -What "t" -Wait $recordWait -Attempt { param([bool]$AskAgain) $script:calls++; if ($script:calls -eq 1) { throw "lookup x: no such host" } } 3>$null
Check "plain message is classified too"       ($script:calls -eq 2 -and ($script:waits -join ",") -eq "30") $true

"Invoke-ToolCaptured / Invoke-ToolRetryable (real output, kept and classified)"
$probe2 = Join-Path ([IO.Path]::GetTempPath()) ("outprobe-" + [guid]::NewGuid().ToString("N") + ".py")
Set-Content -Path $probe2 -Encoding ASCII -Value @(
  "import sys",
  "sys.stdout.buffer.write((chr(0x2502) + ' Error: InsufficientCapacityForPlacement\n').encode('utf-8'))",
  "sys.stderr.write('written on stderr\n')",
  "sys.exit(int(sys.argv[1]))")
$r1 = Invoke-ToolCaptured $py @($probe2, "1") -Quiet
Check "exit code is kept"                     $r1.ExitCode 1
Check "stdout text is kept"                   ($r1.Text -like "*InsufficientCapacityForPlacement*") $true
Check "stderr text is kept"                   ($r1.Text -like "*written on stderr*") $true
Check "the box character survives (UTF-8)"    $r1.Text.Contains([string][char]0x2502) $true
$r0 = Invoke-ToolCaptured $py @($probe2, "0") -Quiet
Check "exit code 0 is kept"                   $r0.ExitCode 0
$msg = ""; $carried = ""
try { Invoke-ToolRetryable $py @($probe2, "3") -Quiet | Out-Null } catch { $msg = $_.Exception.Message; $carried = $_.Exception.Data["Output"] }
Check "a failure throws with the exit code"   ($msg -like "*failed with exit code 3") $true
Check "the exception carries the output"      ($carried -like "*InsufficientCapacityForPlacement*") $true
Check "and the policy reads it as capacity"   (Get-RetryPolicy $carried).Kind "capacity"
Remove-Item $probe2 -Force

"Get-UnresolvedNames"
Check "localhost resolves"                    (@(Get-UnresolvedNames @("localhost")).Count) 0
Check "a name that cannot exist is reported"  ((@(Get-UnresolvedNames @("localhost", "no-such-name.invalid"))) -join ",") "no-such-name.invalid"

""
if ($failed -eq 0) { Write-Host "All tests passed." -ForegroundColor Green; exit 0 }
else { Write-Host "$failed test(s) failed." -ForegroundColor Red; exit 1 }
