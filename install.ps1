param(
  # Renders a representative, side-effect-free installer run. This lets the
  # Linux PowerShell container verify presentation behavior without pretending
  # it can test UAC, Scheduled Tasks, or Windows ACLs.
  [switch]$Preview
)

$ErrorActionPreference = "Stop"
# The Windows bootstrap has the same trust boundary as install.sh: HTTPS plus
# a release checksum before one UAC-elevated helper invocation.

$UseColor = -not [Console]::IsOutputRedirected -and -not $env:NO_COLOR
function Write-Color([string]$Text, [ConsoleColor]$Color) {
  if ($UseColor) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-Title([string]$Text) { Write-Host ""; Write-Color $Text Cyan; Write-Host "────────────────────────────────────────────────────" }
function Write-Step([string]$Text) { Write-Color "  → $Text" Cyan }
function Write-Ok([string]$Text) { Write-Color "  ✓ $Text" Green }
function Write-Warn([string]$Text) { Write-Color "  ! $Text" Yellow }

if ($Preview) {
  Write-Title "Hubbound Installer"
  Write-Host ""
  Write-Color "Installing v0.0.0-preview  (windows-amd64)" Yellow
  Write-Host ""
  Write-Step "Downloading the Hubbound suite"
  Write-Ok "Downloaded hubbound_windows_amd64.zip"
  Write-Step "Verifying the SHA-256 checksum"
  Write-Ok "Checksum verified"
  Write-Step "Preparing the protected system installation"
  Write-Warn "Windows will request administrator permission once to install the system daemon."
  Write-Ok "Installed protected binaries and started hubboundd"
  Write-Step "Configuring your user session"
  Write-Ok "Installed your Hubbound user agent"
  Write-Ok "Daemon health check passed"
  Write-Host ""
  Write-Color "Hubbound v0.0.0-preview is ready!" Green
  Write-Host ""
  Write-Host "Get started:"
  Write-Color "  hubbound auth login       connect your Hubbound account" Cyan
  Write-Color "  hubbound daemon status    check the system daemon" Cyan
  exit 0
}

$Repo = if ($env:HUBBOUND_REPO) { $env:HUBBOUND_REPO } else { "KodastrDevelopment/hubbound-releases" }
$Version = $env:HUBBOUND_VERSION
$Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  "AMD64" { "amd64" }
  "ARM64" { "arm64" }
  default { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}
$Archive = "hubbound_windows_$Arch.zip"
$Root = if ($env:HUBBOUND_SYSTEM_ROOT) { $env:HUBBOUND_SYSTEM_ROOT } else { Join-Path $env:ProgramData "hubbound-lab" }
$UserBin = if ($env:HUBBOUND_USER_BIN) { $env:HUBBOUND_USER_BIN } else { Join-Path $env:LOCALAPPDATA "Hubbound\bin" }

Write-Title "Hubbound Installer"
if (-not $Version) {
  Write-Step "Finding the latest Hubbound release"
  $Version = (Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest").tag_name
}
if (-not $Version) { throw "Could not determine the release version" }
Write-Host ""
Write-Color "Installing $Version  (windows-$Arch)" Yellow
Write-Host ""

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  $Base = "https://github.com/$Repo/releases/download/$Version"

  Write-Step "Downloading the Hubbound suite"
  Invoke-WebRequest "$Base/$Archive" -OutFile (Join-Path $Tmp $Archive)
  Write-Ok "Downloaded $Archive"
  Invoke-WebRequest "$Base/checksums.txt" -OutFile (Join-Path $Tmp "checksums.txt")

  Write-Step "Verifying the SHA-256 checksum"
  $Line = Get-Content (Join-Path $Tmp "checksums.txt") | Where-Object { $_ -match "\s+$([regex]::Escape($Archive))$" } | Select-Object -First 1
  if (-not $Line) { throw "Checksum not found for $Archive" }
  $Expected = ($Line -split '\s+')[0].ToLowerInvariant()
  $Actual = (Get-FileHash (Join-Path $Tmp $Archive) -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Expected -ne $Actual) { throw "Checksum verification failed — installation stopped" }
  Write-Ok "Checksum verified"

  Write-Step "Preparing the protected system installation"
  Expand-Archive (Join-Path $Tmp $Archive) -DestinationPath $Tmp -Force
  $Helper = (Get-ChildItem $Tmp -Recurse -Filter "hubbound-helper.exe" | Select-Object -First 1).FullName
  if (-not $Helper) { throw "Archive is missing hubbound-helper.exe" }
  Write-Warn "Windows will request administrator permission once to install the system daemon."

  # One elevation; no persistent elevated updater is installed.
  $Process = Start-Process -FilePath $Helper -ArgumentList @("system", "install", "--archive", "`"$(Join-Path $Tmp $Archive)`"", "--version", $Version, "--system-root", "`"$Root`"") -Verb RunAs -Wait -PassThru
  if ($Process.ExitCode -ne 0) { throw "System installation or daemon health check failed (exit code $($Process.ExitCode))" }
  Write-Ok "Installed protected binaries and started hubboundd"

  Write-Step "Configuring your user session"
  New-Item -ItemType Directory -Force -Path $UserBin | Out-Null
  foreach ($Binary in @("hubbound.exe", "hubbound-agent.exe", "hubbound-helper.exe")) {
    Copy-Item (Join-Path $Root "current\$Binary") (Join-Path $UserBin $Binary) -Force
  }
  Write-Ok "Installed Hubbound commands at $UserBin"

  $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $PathAdded = ($UserPath -split ';') -notcontains $UserBin
  if ($PathAdded) {
    [Environment]::SetEnvironmentVariable("Path", ($UserPath.TrimEnd(';') + ";" + $UserBin), "User")
    Write-Ok "Added $UserBin to your user PATH"
  }

  $Action = New-ScheduledTaskAction -Execute (Join-Path $Root "current\hubbound-agent.exe") -Argument "run"
  $Trigger = New-ScheduledTaskTrigger -AtLogOn
  $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName "HubboundAgent" -Action $Action -Trigger $Trigger -Principal $Principal -Force | Out-Null
  Start-ScheduledTask -TaskName "HubboundAgent" -ErrorAction SilentlyContinue
  Write-Ok "Installed your Hubbound user agent"
  Write-Ok "Daemon health check passed"

  Write-Host ""
  Write-Color "Hubbound $Version is ready!" Green
  Write-Host ""
  Write-Host "Get started:"
  Write-Color "  hubbound auth login       connect your Hubbound account" Cyan
  Write-Color "  hubbound daemon status    check the system daemon" Cyan
  Write-Color "  hubbound update status    view update state" Cyan
  if ($PathAdded) {
    Write-Host ""
    Write-Host "Open a new terminal to activate Hubbound."
  }
}
catch {
  Write-Color "  ✗ $($_.Exception.Message)" Red
  exit 1
}
finally {
  Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
