param(
  # Renders a representative, side-effect-free installer run. This lets the
  # Linux PowerShell container verify presentation behavior without pretending
  # it can test UAC, Scheduled Tasks, or Windows ACLs.
  [switch]$Preview
)

$ErrorActionPreference = "Stop"
# The Windows bootstrap has the same trust boundary as install.sh: HTTPS plus
# a release checksum before one UAC-elevated helper invocation.

# Windows PowerShell 5.1 consoles often use an OEM code page that cannot render
# Unicode arrows/checkmarks. ASCII markers keep the installer from looking like
# a broken/malware script ("???" glyphs).
$UseColor = -not [Console]::IsOutputRedirected -and -not $env:NO_COLOR
function Write-Color([string]$Text, [ConsoleColor]$Color) {
  if ($UseColor) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-Title([string]$Text) { Write-Host ""; Write-Color $Text Cyan; Write-Host "----------------------------------------------------" }
function Write-Step([string]$Text) { Write-Color "  > $Text" Cyan }
function Write-Ok([string]$Text) { Write-Color "  + $Text" Green }
function Write-Warn([string]$Text) { Write-Color "  ! $Text" Yellow }
function Write-Fail([string]$Text) { Write-Color "  x $Text" Red }

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Start-Process -ArgumentList array quoting is unreliable on Windows PowerShell
# 5.1 (extra embedded quotes become literal characters in argv). Build one
# properly escaped command line instead.
function ConvertTo-SingleQuotedPsLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Get-HelperFailureDetail([string]$LogPath, [int]$ExitCode) {
  $detail = "System installation or daemon health check failed (exit code $ExitCode)"
  if (-not (Test-Path -LiteralPath $LogPath)) {
    return $detail
  }
  $raw = (Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue)
  if (-not $raw) {
    return "$detail. See $LogPath"
  }
  $line = (($raw -split "`r?`n") | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
  if ($line) {
    return "$detail. Helper: $line (full log: $LogPath)"
  }
  return "$detail. See $LogPath"
}

function Invoke-SystemInstall {
  param(
    [string]$HelperPath,
    [string]$ArchivePath,
    [string]$Version,
    [string]$SystemRoot,
    [string]$WorkDir
  )

  # Persist outside the temp extract dir so failures survive cleanup.
  $logPath = Join-Path $env:TEMP "hubbound-helper-install.log"
  Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

  # Already elevated (common when the user opened "Run as administrator"):
  # call the helper in-process so stderr stays visible and no UAC flash occurs.
  # Start-Process -Verb RunAs from an elevated host is what caused the
  # "extra console opens and immediately closes" failure mode.
  if (Test-IsAdministrator) {
    & $HelperPath system install --archive $ArchivePath --version $Version --system-root $SystemRoot 2>&1 |
      Tee-Object -FilePath $logPath |
      Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw (Get-HelperFailureDetail -LogPath $logPath -ExitCode $LASTEXITCODE)
    }
    return
  }

  Write-Warn "Windows will request administrator permission once to install the system daemon."

  # Elevate a tiny PowerShell runner instead of the helper EXE directly:
  # 1) call-operator args are correct (no Start-Process ArgumentList quoting bugs)
  # 2) helper stdout/stderr land in a log the parent can read after UAC
  $runner = Join-Path $WorkDir "hubbound-elevate-install.ps1"
  $helperLit = ConvertTo-SingleQuotedPsLiteral $HelperPath
  $archiveLit = ConvertTo-SingleQuotedPsLiteral $ArchivePath
  $versionLit = ConvertTo-SingleQuotedPsLiteral $Version
  $rootLit = ConvertTo-SingleQuotedPsLiteral $SystemRoot
  $logLit = ConvertTo-SingleQuotedPsLiteral $logPath
  @(
    '$ErrorActionPreference = "Continue"'
    "& $helperLit system install --archive $archiveLit --version $versionLit --system-root $rootLit *> $logLit"
    'exit $LASTEXITCODE'
  ) | Set-Content -LiteralPath $runner -Encoding ASCII

  $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runner) `
    -Verb RunAs -Wait -PassThru
  if ($null -eq $process) {
    throw "Administrator permission was not granted"
  }
  if ($process.ExitCode -ne 0) {
    throw (Get-HelperFailureDetail -LogPath $logPath -ExitCode $process.ExitCode)
  }
}

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
  if ($Expected -ne $Actual) { throw "Checksum verification failed - installation stopped" }
  Write-Ok "Checksum verified"

  Write-Step "Preparing the protected system installation"
  Expand-Archive (Join-Path $Tmp $Archive) -DestinationPath $Tmp -Force
  $Helper = (Get-ChildItem $Tmp -Recurse -Filter "hubbound-helper.exe" | Select-Object -First 1).FullName
  if (-not $Helper) { throw "Archive is missing hubbound-helper.exe" }

  $ArchivePath = Join-Path $Tmp $Archive
  Invoke-SystemInstall -HelperPath $Helper -ArchivePath $ArchivePath -Version $Version -SystemRoot $Root -WorkDir $Tmp
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
  Write-Fail $_.Exception.Message
  exit 1
}
finally {
  Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
