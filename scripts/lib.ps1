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
