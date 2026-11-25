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
