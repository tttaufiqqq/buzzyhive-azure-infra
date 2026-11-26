<#
.SYNOPSIS
  Brings the BuzzyHive lab up with one command: apply, build and push images, apply again,
  migrate, and optionally seed the database and register an IoT device.

.DESCRIPTION
  UNTESTED: written 24/11/2026 and never run against Azure. Run it with -DryRun first.
  Run it in Windows PowerShell. It stops and asks before every apply unless you pass -AutoApprove.

  Why two applies: the registry is created inside lab, and the apps need images that can only be
  pushed after the registry exists. So the script applies once with Microsoft's placeholder image,
  pushes your images, and applies again. If the registry is ever moved to foundation (see
  progress.md, section 11), the first pass and the image step disappear.

  How the images are passed: the script writes lab\zz-images.auto.tfvars (git-ignored, and it
  overrides `images` in terraform.tfvars). First `images = {}`, then the real references. The file
  is left in place so a manual terraform apply later in the session keeps the same images.
  down.ps1 deletes it. Image tags are the app repository's short git commit, so there are no
  typos to make (see troubleshooting 29).

  The registry login uses the temporary admin-user workaround from troubleshooting 26, and the
  admin user is switched off again when the images are pushed.

  Needs: az login, lab\terraform.tfvars and lab\backend.hcl, Docker running in WSL (unless
  -SkipImages), and the app repository path (-AppRepo or $env:BUZZYHIVE_APP_REPO).

.PARAMETER SkipImages   Do not build or push images. Pass the references with -Laravel and -Flask.
.PARAMETER Seed         After migrating, seed the database with a throwaway admin password that is
                        printed once and not saved, then restore the migrate Job with another apply.
.PARAMETER RegisterDevice   Register this IoT Hub device (for example NODE-28ZRUR), keys not printed.
.PARAMETER AutoApprove  Do not ask before applying.
.PARAMETER DryRun       Print what would happen. Runs no az, terraform, docker or WSL command.

.EXAMPLE
  $env:BUZZYHIVE_APP_REPO = "<path to the application repository>"
  $env:BUZZYHIVE_PUSHER_KEY = "<pusher app key>"
  .\scripts\up.ps1 -DryRun
  .\scripts\up.ps1 -Seed
#>
[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-hive-lab",
  [string]$AppRepo = $env:BUZZYHIVE_APP_REPO,
  [string]$PusherKey = $env:BUZZYHIVE_PUSHER_KEY,
  [string]$PusherCluster = "ap1",
  [switch]$SkipImages,
  [string]$Laravel,
  [string]$Flask,
  [switch]$Seed,
  [string]$RegisterDevice,
  [switch]$AutoApprove,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib.ps1"
$root = Split-Path $PSScriptRoot -Parent
$lab = Join-Path $root "lab"
# Nothing to type: the Pusher key comes from lab\terraform.tfvars, the app repo from scripts\local.settings.json.
$localSettings = Get-LocalSettings $PSScriptRoot
if (-not $AppRepo -and $localSettings.appRepo) { $AppRepo = $localSettings.appRepo }
if (-not $PusherKey -and (Test-Path (Join-Path $lab "terraform.tfvars"))) { $PusherKey = Get-TfvarsString (Join-Path $lab "terraform.tfvars") "pusher-app-key" }
$autoVars = Join-Path $lab "zz-images.auto.tfvars"
$started = Get-Date

function Say([string]$Message) { Write-Host ""; Write-Host "== $Message" -ForegroundColor Cyan }
function Note([string]$Message) { Write-Host "   $Message" }

# Run a script block, or only print what it would do.
function Run([string]$What, [scriptblock]$Block) {
  if ($DryRun) { Note "[dry run] $What"; return }
  & $Block
}

# Call a native tool and stop if it fails.
function Invoke-Tool([string]$Exe, [string[]]$ToolArgs) {
  & $Exe @ToolArgs
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($ToolArgs -join ' ') failed with exit code $LASTEXITCODE" }
}

# Call a native tool and return its trimmed output.
function Get-ToolOutput([string]$Exe, [string[]]$ToolArgs) {
  $out = & $Exe @ToolArgs
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($ToolArgs -join ' ') failed with exit code $LASTEXITCODE" }
  return ($out | Out-String).Trim()
}

function Confirm-Step([string]$Question) {
  if ($AutoApprove -or $DryRun) { return }
  $answer = Read-Host "$Question (type yes)"
  if ($answer -ne "yes") { throw "Stopped: you did not type yes." }
}

function Set-Images([string]$LaravelRef, [string]$FlaskRef) {
  if ($LaravelRef -and $FlaskRef) {
    $body = "images = {`n  laravel = `"$LaravelRef`"`n  flask   = `"$FlaskRef`"`n}`n"
  } else {
    $body = "images = {}`n"
  }
  Set-Content -Path $autoVars -Value $body -Encoding ASCII
}

# Plan, show it, ask, then apply that exact plan file.
function Invoke-TerraformApply([string]$Label) {
  Say $Label
  Run "terraform plan -out=session.tfplan, ask, then terraform apply session.tfplan (in lab)" {
    Push-Location $lab
    try {
      # Retries by kind of error (lib.ps1, Get-RetryPolicy): a capacity shortage waits 5 minutes, up to 6 times
      # (troubleshooting 51); a dropped connection waits 30 seconds, up to 5 times; anything else gets one retry
      # after 30 seconds (the 412 race, troubleshooting 46). Every retry plans again. After an "other" error the
      # new plan is confirmed again; after a capacity or network error the same intent is simply tried again.
      # A "Stopped:" (you said no) is never retried.
      Invoke-WithRetryPolicy -What "The apply" -Attempt {
        param([bool]$AskAgain)
        Invoke-ToolRetryable terraform @("plan", "-input=false", "-no-color", "-out=session.tfplan") | Out-Null
        if ($AskAgain) { Confirm-Step "Apply this plan to Azure now?" }
        Invoke-ToolRetryable terraform @("apply", "-input=false", "-no-color", "session.tfplan") | Out-Null
      }
    } finally {
      Remove-Item "session.tfplan" -Force -ErrorAction SilentlyContinue   # it can contain secret values
      Pop-Location
    }
  }
}

function Wait-Http([string]$Url, [int]$TimeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
      if ($r.StatusCode -eq 200) { return $true }
    } catch { }
    Start-Sleep -Seconds 10
  }
  return $false
}

# Start a Container Apps Job and wait for it to finish.
function Start-JobAndWait([string]$JobName, [int]$TimeoutSeconds) {
  $exec = Get-ToolOutput az @("containerapp", "job", "start", "-n", $JobName, "-g", $ResourceGroup, "--query", "name", "-o", "tsv")
  Note "Started execution $exec"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $status = Get-ToolOutput az @("containerapp", "job", "execution", "show", "-n", $JobName, "-g", $ResourceGroup,
      "--job-execution-name", $exec, "--query", "properties.status", "-o", "tsv")
    Note "status: $status"
    if ($status -in @("Succeeded", "Failed", "Stopped")) { return $status }
    Start-Sleep -Seconds 15
  }
  return "TimedOut"
}

# Make the first seeded node carry the IoT Hub device's name. The seeder gives nodes random identifiers
# (NODE-XXXXXX), so a device named in advance never matches them (troubleshooting 48). Runs as the migrate Job.
function Set-FirstNodeIdentifier([string]$Identifier) {
  $phpArgs = New-PhpRunnerArgs (Get-RenameNodePhp $Identifier)
  # Not through az.cmd: it breaks on the ) in the PHP argument (troubleshooting 49).
  Invoke-AzDirect (@("containerapp", "job", "update", "-n", "laravel-migrate", "-g", $ResourceGroup, "--container-name", "migrate", "--args") + $phpArgs + @("-o", "none"))
  $status = Start-JobAndWait "laravel-migrate" 600
  if ($status -ne "Succeeded") { Write-Warning "Renaming the node ended as $status. Check it in the database before sending readings." }
  else { Note "The first seeded node now has the identifier $Identifier." }
}

# ---------- before anything ----------
Say "0. Checks"
if ($DryRun) {
  Note "[dry run] would check: az and terraform on PATH, az login, lab\terraform.tfvars, lab\backend.hcl, app repo path"
} else {
  foreach ($c in "az", "terraform") {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c is not on PATH." }
  }
  $null = az account show --query id -o tsv 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Not signed in. Run: az login" }
  foreach ($f in "terraform.tfvars", "backend.hcl") {
    if (-not (Test-Path (Join-Path $lab $f))) { throw "lab\$f is missing. Copy it from the .example file first." }
  }
  if (-not $SkipImages) {
    if (-not $AppRepo -or -not (Test-Path $AppRepo)) { throw "Set -AppRepo or `$env:BUZZYHIVE_APP_REPO to the application repository path." }
    if (-not $PusherKey) { Write-Warning "No Pusher key given. The Laravel image will be built without VITE_PUSHER_APP_KEY, so live updates will not work." }
  } elseif (-not ($Laravel -and $Flask)) {
    throw "-SkipImages needs both -Laravel and -Flask (full image references)."
  }
  az extension add --name containerapp --only-show-errors 2>$null | Out-Null
}

# ---------- 1. init ----------
Say "1. terraform init (lab)"
Run "terraform init -reconfigure -backend-config=backend.hcl" {
  Push-Location $lab
  try { Invoke-WithRetryPolicy -What "terraform init" -Attempt { param([bool]$AskAgain) Invoke-ToolRetryable terraform @("init", "-reconfigure", "-input=false", "-backend-config=backend.hcl") | Out-Null } } finally { Pop-Location }
}

# ---------- 2. first apply, with the placeholder image ----------
if ($SkipImages) {
  Run "write lab\zz-images.auto.tfvars with the images you passed" { Set-Images $Laravel $Flask }
  Invoke-TerraformApply "2. terraform apply (lab), with the images you passed"
  $laravelRef = $Laravel; $flaskRef = $Flask
} else {
  Run "write lab\zz-images.auto.tfvars with images = {} (placeholder image)" { Set-Images $null $null }
  Invoke-TerraformApply "2. terraform apply (lab), first pass with the placeholder image"

  # ---------- 3. build and push ----------
  Say "3. Build and push the images from WSL"
  if ($DryRun) {
    $server = "<registry>.azurecr.io"; $tag = "<app repo short git commit>"
    Note "[dry run] terraform output -raw acr_login_server"
    Note "[dry run] az acr update --admin-enabled true, read its credential, log in from WSL with an environment variable"
    Note "[dry run] wsl --cd <app repo> -e docker build -t $server/laravel:$tag --build-arg VITE_PUSHER_APP_KEY=... ."
    Note "[dry run] wsl --cd <app repo>\ml -e docker build -t $server/flask-ml:$tag ."
    Note "[dry run] docker push both, then az acr update --admin-enabled false"
    $laravelRef = "$server/laravel:$tag"; $flaskRef = "$server/flask-ml:$tag"
  } else {
    $server = Get-ToolOutput terraform @("-chdir=$lab", "output", "-raw", "acr_login_server")
    $acrName = $server.Split(".")[0]
    $tag = "latest"
    $sha = (& git -C $AppRepo rev-parse --short HEAD 2>$null | Out-String).Trim()
    if ($sha) {
      $tag = $sha
      if ((& git -C $AppRepo status --porcelain 2>$null | Out-String).Trim()) { $tag = "$sha-dirty" }
    }
    $laravelRef = "$server/laravel:$tag"
    $flaskRef = "$server/flask-ml:$tag"
    Note "Registry: $server   Tag: $tag"

    Invoke-Tool az @("acr", "update", "-n", $acrName, "--admin-enabled", "true", "--only-show-errors", "-o", "none")
    try {
      $user = Get-ToolOutput az @("acr", "credential", "show", "-n", $acrName, "--query", "username", "-o", "tsv")
      $env:ACR_PW = Get-ToolOutput az @("acr", "credential", "show", "-n", $acrName, "--query", "passwords[0].value", "-o", "tsv")
      $env:WSLENV = "ACR_PW"
      & wsl -u root -e bash -lc "service docker start" | Out-Null          # the engine stops now and then
      # A new admin credential can take a little while to be accepted (seen 25/11/2026, troubleshooting 46).
      # Prove it works from Windows first (the password goes in a header, not on a command line), then log in.
      $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:$($env:ACR_PW)"))
      $accepted = $false
      for ($i = 1; $i -le 18 -and -not $accepted; $i++) {
        try {
          $r = Invoke-WebRequest -Uri "https://$server/v2/" -Headers @{ Authorization = "Basic $basic" } -UseBasicParsing -TimeoutSec 20
          if ($r.StatusCode -eq 200) { $accepted = $true }
        } catch { Note "registry does not accept the admin credential yet (try $i of 18), waiting 10 seconds" ; Start-Sleep -Seconds 10 }
      }
      if (-not $accepted) { throw "The registry still rejects the admin credential after 3 minutes. Check: az acr show -n $acrName --query adminUserEnabled" }
      $loggedIn = $false
      for ($i = 1; $i -le 3 -and -not $loggedIn; $i++) {
        & wsl -e bash -lc "docker login $server -u $user -p `"`$ACR_PW`""
        if ($LASTEXITCODE -eq 0) { $loggedIn = $true } else { Note "docker login failed (try $i of 3)"; Start-Sleep -Seconds 10 }
      }
      if (-not $loggedIn) { throw "The registry accepts the credential from Windows but docker login in WSL fails. This is the PowerShell-to-WSL problem from troubleshooting 26." }

      $laravelBuild = @("--cd", $AppRepo, "-e", "docker", "build", "-t", $laravelRef)
      if ($PusherKey) { $laravelBuild += @("--build-arg", "VITE_PUSHER_APP_KEY=$PusherKey") }
      $laravelBuild += @("--build-arg", "VITE_PUSHER_APP_CLUSTER=$PusherCluster", ".")
      Invoke-Tool wsl $laravelBuild
      Invoke-Tool wsl @("--cd", (Join-Path $AppRepo "ml"), "-e", "docker", "build", "-t", $flaskRef, ".")
      # A push is retried because a long upload can time out on a poor connection (26/11/2026); layers that already
      # arrived are skipped by the registry, so a retry only sends what is missing.
      foreach ($ref in @($laravelRef, $flaskRef)) {
        Invoke-WithRetryPolicy -What "docker push $ref" -Attempt { param([bool]$AskAgain) Invoke-ToolRetryable wsl @("-e", "docker", "push", $ref) | Out-Null }
      }
      # Informational only: the pushes above already proved the images arrived, so a failed listing must not stop the build.
      try {
        $repos = ""
        Invoke-WithRetryPolicy -What "listing the registry" -Attempt { param([bool]$AskAgain) $script:repos = Invoke-ToolRetryable az @("acr", "repository", "list", "-n", $acrName, "-o", "tsv") -Quiet }
        Note ("Repositories now in the registry: " + ($script:repos.Trim() -replace "\s+", ", "))
      } catch { Write-Warning "Could not list the registry's repositories ($($_.Exception.Message)). The pushes succeeded, so the build goes on." }
    } finally {
      Remove-Item Env:ACR_PW -ErrorAction SilentlyContinue
      & az acr update -n $acrName --admin-enabled false --only-show-errors -o none 2>$null   # always switch it off again
    }
  }

  # ---------- 4. second apply, with the real images ----------
  Run "write lab\zz-images.auto.tfvars with the real image references" { Set-Images $laravelRef $flaskRef }
  Invoke-TerraformApply "4. terraform apply (lab), second pass with your images"
}

# ---------- 5. wait for the site ----------
Say "5. Wait for the site"
if ($DryRun) {
  Note "[dry run] poll <web_url>/up until it answers 200 (up to 5 minutes)"
  $webUrl = "<web_url>"
} else {
  $webUrl = Get-ToolOutput terraform @("-chdir=$lab", "output", "-raw", "web_url")
  if (Wait-Http "$webUrl/up" 300) { Note "$webUrl/up answered 200" }
  else { Write-Warning "$webUrl/up did not answer 200 in 5 minutes. Check: az containerapp revision list -n laravel-web -g $ResourceGroup" }
}

# ---------- 6. migrate ----------
Say "6. Run the migration Job"
if ($DryRun) {
  Note "[dry run] az containerapp job start -n laravel-migrate, then poll its execution until it finishes"
} else {
  $status = Start-JobAndWait "laravel-migrate" 600
  if ($status -ne "Succeeded") { throw "The migrate Job ended as $status. Read its log: az containerapp job logs show -n laravel-migrate -g $ResourceGroup --container migrate" }
  Note "Migration succeeded."
}

# ---------- 7. optional seed ----------
if ($Seed) {
  Say "7. Seed the database"
  if ($DryRun) {
    Note "[dry run] az containerapp job update laravel-migrate --args php artisan db:seed (APP_ENV=staging, throwaway passwords)"
    Note "[dry run] start the Job and wait, then restore it with another terraform apply"
  } else {
    $pw = "Lab-" + [guid]::NewGuid().ToString("N")
    Invoke-Tool az @("containerapp", "job", "update", "-n", "laravel-migrate", "-g", $ResourceGroup, "--container-name", "migrate",
      "--args", "php", "artisan", "db:seed", "--set-env-vars", "APP_ENV=staging", "ADMIN_SEED_PASSWORD=$pw", "BEEKEEPER_SEED_PASSWORD=$pw", "-o", "none")
    $status = Start-JobAndWait "laravel-migrate" 900
    if ($status -ne "Succeeded") { Write-Warning "The seed run ended as $status. Read the Job log before going on." }
    Write-Host "   Admin login: admin@buzzyhive.urban-alert.com   password: $pw" -ForegroundColor Yellow
    Write-Host "   Shown once and not saved. Write it down now." -ForegroundColor Yellow
    if ($RegisterDevice) { Set-FirstNodeIdentifier $RegisterDevice }
    Invoke-TerraformApply "7b. terraform apply (lab), to restore the migrate Job after seeding"
  }
}

# ---------- 8. optional IoT device ----------
if ($RegisterDevice) {
  Say "8. Register the IoT Hub device $RegisterDevice"
  if ($DryRun) {
    Note "[dry run] give the first seeded node the identifier $RegisterDevice (a Job running PHP, sent as base64)"
    Note "[dry run] az iot hub device-identity create -n <hub> -d $RegisterDevice -o none   (-o none so the keys are not printed)"
  } else {
    if (-not $Seed) {
      Set-FirstNodeIdentifier $RegisterDevice
      Invoke-TerraformApply "8a. terraform apply (lab), to restore the migrate Job after renaming the node"
    }
    az extension add --name azure-iot --only-show-errors 2>$null | Out-Null
    $hub = Get-ToolOutput terraform @("-chdir=$lab", "output", "-raw", "iothub_name")
    Invoke-Tool az @("iot", "hub", "device-identity", "create", "-n", $hub, "-d", $RegisterDevice, "-o", "none")
    Note "Registered. Read its connection string into the environment without printing it:"
    Note "`$env:IOTHUB_DEVICE_CONNECTION_STRING = az iot hub device-identity connection-string show -n $hub -d $RegisterDevice --query connectionString -o tsv"
  }
}

# ---------- summary ----------
Say "Done"
$minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
Note "Site:    $webUrl"
if ($laravelRef) { Note "Images:  $laravelRef  and  $flaskRef" }
Note "Took:    $minutes minutes"
Note "To keep these images in later manual applies, put them in lab\terraform.tfvars (zz-images.auto.tfvars already does it for this session)."
Note "The lab is BILLING until you run .\scripts\down.ps1."
