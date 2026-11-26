# Helpers shared by up-all.ps1 and down-all.ps1. Dot-source it: . "$PSScriptRoot\lib.ps1"
#
# Written for Windows PowerShell 5.1, which is the shell this project is run in. Two habits from the
# troubleshooting log (entry 44): never pipe a JSON array through ConvertFrom-Json and trust the
# result, and never put a JMESPath filter in an az query. These helpers read plain tsv lines instead.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# The value of a simple  name = "value"  line in a .tfvars file, or $null if the line is not there.
# Names may contain hyphens (the secrets map uses pusher-app-key).
function Get-TfvarsString([string]$Path, [string]$Name) {
  $text = [System.IO.File]::ReadAllText($Path)
  $m = [regex]::Match($text, '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

# True when the file has  name = true  (a trailing comment is fine).
function Test-TfvarsTrue([string]$Path, [string]$Name) {
  $text = [System.IO.File]::ReadAllText($Path)
  return [regex]::IsMatch($text, '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*true\b')
}

# Replace the value of  name = "old"  with the new value, keeping everything else (alignment, comments,
# line endings). Throws if the line is missing, so a typo cannot silently do nothing.
function Set-TfvarsString([string]$Path, [string]$Name, [string]$Value) {
  $text = [System.IO.File]::ReadAllText($Path)
  $pattern = '(?m)^(\s*' + [regex]::Escape($Name) + '\s*=\s*)"[^"]*"'
  if (-not [regex]::IsMatch($text, $pattern)) { throw "$Name is not set in $Path, so it cannot be updated." }
  $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + '"' + $Value + '"' }
  $updated = [regex]::Replace($text, $pattern, $evaluator)
  [System.IO.File]::WriteAllText($Path, $updated, $script:Utf8NoBom)
}

# The backend settings from bootstrap's backend_hcl output, plus exactly one key line.
function New-BackendHcl([string]$BootstrapOutput, [string]$Key) {
  $body = $BootstrapOutput.Trim()
  if ($body -match '(?m)^\s*key\s*=') { throw "The bootstrap output already has a key line. Expected none." }
  if ($body -notmatch 'storage_account_name') { throw "The bootstrap output does not look like backend settings." }
  return $body + "`r`n" + 'key                  = "' + $Key + '"' + "`r`n"
}

# From the tsv lines of  az resource list --query "[].[name,type]" -o tsv , the resources that are NOT
# the managed identity (which belongs to the foundation root and goes with it). Returns objects.
function Get-NonIdentityResources([string[]]$TsvLines, [string]$IdentityType) {
  $out = @()
  foreach ($line in $TsvLines) {
    if (-not $line -or -not $line.Trim()) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -lt 2) { continue }
    if ($parts[1].Trim() -ne $IdentityType) {
      $out += New-Object psobject -Property @{ Name = $parts[0].Trim(); Type = $parts[1].Trim() }
    }
  }
  return $out
}

# Names from a plain list (one per line) that start with any of the given prefixes.
function Select-ByPrefix([string[]]$Lines, [string[]]$Prefixes) {
  $out = @()
  foreach ($line in $Lines) {
    if (-not $line) { continue }
    foreach ($p in $Prefixes) { if ($line.Trim().StartsWith($p)) { $out += $line.Trim(); break } }
  }
  return $out
}


# Settings that are not Terraform variables, from scripts\local.settings.json (git-ignored):
#   { "appRepo": "C:\\path\\to\\app", "device": "NODE-28ZRUR" }
# Returns an empty object when the file is missing.
function Get-LocalSettings([string]$ScriptsDir) {
  $p = Join-Path $ScriptsDir "local.settings.json"
  if (-not (Test-Path $p)) { return New-Object psobject }
  return (Get-Content -Raw $p | ConvertFrom-Json)
}


# Arguments for a container that runs a piece of PHP with Laravel booted, and nothing else. The code is sent as
# base64, so no quote of it ever passes through PowerShell 5.1 (troubleshooting 48). Two more traps, both
# found on the first real run (troubleshooting 49): az.cmd chokes on a ) in an argument, so this is started
# without it (Invoke-AzDirect), and the Azure CLI's parser reads a separate "-r" as one of its own options
# and refuses it. An argument that starts with a dash is a plain value only if it holds a space, so "-r" and
# the code are ONE argument: PHP takes  -r<code>  with the code attached, and the leading space is harmless.
function New-PhpRunnerArgs([string]$Php) {
  $boot = 'require getcwd() . "/vendor/autoload.php"; $app = require getcwd() . "/bootstrap/app.php"; ' +
          '$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap(); '
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($boot + $Php))
  return @("php", '-r eval(base64_decode($argv[1]));', $b64)
}

# PHP that gives the first seeded IoT node the identifier the IoT Hub device has, unless some node has it already.
function Get-RenameNodePhp([string]$Identifier) {
  if ($Identifier -notmatch '^[A-Za-z0-9-]{3,40}$') { throw "Device name '$Identifier' has characters this script does not allow." }
  return '$id = "' + $Identifier + '"; $t = Illuminate\Support\Facades\DB::table("iot_nodes"); ' +
         'if ((clone $t)->where("node_identifier", $id)->exists()) { echo "NODE_ALREADY_PRESENT"; } else { ' +
         '$n = (clone $t)->where("id", (clone $t)->min("id"))->update(["node_identifier" => $id]); echo "NODE_RENAMED_ROWS=" . $n; }'
}


# How to start the Azure CLI WITHOUT az.cmd. On Windows, az is a batch file that puts every argument inside a
# parenthesised block, so an argument containing ) ends the block early and cmd.exe answers
# ") was unexpected at this time" (troubleshooting 49). The batch file only starts python.exe -IBm azure.cli, so
# this does the same directly, and the arguments reach the CLI as they are. Falls back to plain az.
function Get-AzInvocation {
  $cmd = (Get-Command az -ErrorAction Stop).Source
  if ($cmd -like "*.cmd") {
    $py = Join-Path (Split-Path (Split-Path $cmd -Parent) -Parent) "python.exe"
    if (Test-Path $py) { return New-Object psobject -Property @{ Exe = $py; Prefix = @("-IBm", "azure.cli") } }
  }
  return New-Object psobject -Property @{ Exe = $cmd; Prefix = @() }
}

# Run az with arguments that may contain brackets, semicolons or dollar signs. Stops if az fails.
function Invoke-AzDirect([string[]]$AzArgs) {
  $inv = Get-AzInvocation
  & $inv.Exe @($inv.Prefix + $AzArgs)
  if ($LASTEXITCODE -ne 0) { throw "az $($AzArgs -join ' ') failed with exit code $LASTEXITCODE" }
}


# ---------- Retries (third rebuild, 25 to 26/11/2026: troubleshooting 51, and the network failures in the runbook) ----------

# How to react to a failed command, judged from its own output.
#   capacity : Azure has no room for the resource right now (InsufficientCapacityForPlacement). It clears in minutes
#              to hours, so wait 5 minutes, up to 6 times. A 30 second wait cannot help.
#   network  : a dropped connection, a timeout or a DNS failure on this side. Wait 30 seconds, up to 5 times.
#   other    : one retry after 30 seconds (the 412 race of troubleshooting 46 is cleared by a second attempt).
function Get-RetryPolicy([string]$Text) {
  if ($Text -match 'InsufficientCapacity|capacity constraints|ServerCapacity') {
    return New-Object psobject -Property @{ Kind = "capacity"; MaxRetries = 6; WaitSeconds = 300 }
  }
  if ($Text -match 'connection (may have been )?reset|timeout awaiting response|i/o timeout|TLS handshake timeout|no such host|unexpected EOF|Client\.Timeout|could not connect|Could not connect|connection refused|temporary failure in name resolution|Unable to connect|actively refused') {
    return New-Object psobject -Property @{ Kind = "network"; MaxRetries = 5; WaitSeconds = 30 }
  }
  return New-Object psobject -Property @{ Kind = "other"; MaxRetries = 1; WaitSeconds = 30 }
}

# Runs a command with its output shown live AND kept, so a failure can be classified. The command line goes through
# cmd.exe so that stderr and stdout are merged at the operating system level (PowerShell 5.1 turns a native
# command's stderr into errors). The console is set to UTF-8 meanwhile, so Terraform's box characters survive.
# Returns an object with ExitCode and Text. -Quiet keeps the output and does not show it.
function Invoke-ToolCaptured([string]$Exe, [string[]]$ToolArgs, [switch]$Quiet) {
  $parts = @($(if ($Exe -match '[\s&|<>^()]') { '"' + $Exe + '"' } else { $Exe }))
  foreach ($a in $ToolArgs) {
    if ($a -match '"') { throw "Invoke-ToolCaptured cannot pass an argument that contains a double quote: $a" }
    if ($a -match '[\s&|<>^()]') { $parts += ('"' + $a + '"') } else { $parts += $a }
  }
  # The whole command line goes into an environment variable, and cmd is given it inside one more pair of quotes,
  # which cmd /s strips. That form survives a program path with spaces (C:\Program Files\...) and quoted arguments.
  $env:BUZZYHIVE_CMDLINE = ($parts -join " ") + " 2>&1"
  $old = [Console]::OutputEncoding
  $lines = New-Object System.Collections.ArrayList
  try {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
    & cmd.exe /d /s /c '"%BUZZYHIVE_CMDLINE%"' | ForEach-Object {
      $t = [string]$_
      [void]$lines.Add($t)
      if (-not $Quiet) { Write-Host $t }
    }
    $code = $LASTEXITCODE
  } finally {
    try { [Console]::OutputEncoding = $old } catch { }
    Remove-Item Env:BUZZYHIVE_CMDLINE -ErrorAction SilentlyContinue
  }
  return New-Object psobject -Property @{ ExitCode = $code; Text = ($lines -join "`n") }
}

# Like Invoke-Tool, but the exception carries the command's output (in Data["Output"]) for the retry policy.
function Invoke-ToolRetryable([string]$Exe, [string[]]$ToolArgs, [switch]$Quiet) {
  $r = Invoke-ToolCaptured $Exe $ToolArgs -Quiet:$Quiet
  if ($r.ExitCode -ne 0) {
    $ex = New-Object System.Exception ("$Exe $($ToolArgs -join ' ') failed with exit code $($r.ExitCode)")
    $ex.Data["Output"] = $r.Text
    throw $ex
  }
  return $r.Text
}

# Runs $Attempt until it succeeds or the policy for its error is used up. $Attempt receives one argument: $true when
# the person should be asked to confirm again. That is the first try, and any retry after an "other" error. After a
# capacity or network error the same plan is simply tried again, so a 30 minute wait does not need someone at the
# keyboard. A "Stopped:" (the person said no) is never retried. $Wait is a scriptblock taking seconds.
function Invoke-WithRetryPolicy([scriptblock]$Attempt, [string]$What, [scriptblock]$Wait = { param($s) Start-Sleep -Seconds $s }) {
  $retries = 0
  $confirm = $true
  while ($true) {
    try { & $Attempt $confirm; return }
    catch {
      if ($_.Exception.Message -like "Stopped:*") { throw }
      $text = $_.Exception.Data["Output"]
      if (-not $text) { $text = $_.Exception.Message }
      $p = Get-RetryPolicy $text
      if ($retries -ge $p.MaxRetries) { throw }
      $retries++
      $confirm = ($p.Kind -eq "other")
      Write-Warning ("$What failed ($($p.Kind) error): $($_.Exception.Message). Waiting $($p.WaitSeconds) seconds, then trying again (retry $retries of $($p.MaxRetries)).")
      & $Wait $p.WaitSeconds
    }
  }
}

# The names from the list that do NOT resolve in DNS. Used before the build starts: the third rebuild lost time to
# "no such host" for registry.terraform.io on a campus network.
function Get-UnresolvedNames([string[]]$Names) {
  $bad = @()
  foreach ($n in $Names) {
    $ok = $false
    for ($i = 1; $i -le 3 -and -not $ok; $i++) {
      try { $null = Resolve-DnsName -Name $n -ErrorAction Stop; $ok = $true } catch { if ($i -lt 3) { Start-Sleep -Seconds 3 } }
    }
    if (-not $ok) { $bad += $n }
  }
  return $bad
}
