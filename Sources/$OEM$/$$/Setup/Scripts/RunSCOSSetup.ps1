param(
    [string]$ScriptsRoot = "C:\Windows\Setup\Scripts",
    [string]$Edition = "Standard",
    [int]$Lockdown = 1
)

$LogPath = "C:\SCOS\Logs\SCOSLauncher.log"
$SetupCompleteLog = "C:\SetupComplete.log"
$SetupUi = "C:\SCOS\Setup\SCOSSetupProgress.ps1"

$EditionFile = "C:\SCOS\Setup\SCOS_EDITION.txt"
$LockdownFile = "C:\SCOS\Setup\SCOS_LOCKDOWN.txt"

New-Item -ItemType Directory -Path "C:\SCOS\Logs" -Force | Out-Null

function Write-LauncherLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message

    Add-Content -Path $LogPath -Value $line

    try {
        Add-Content -Path $SetupCompleteLog -Value $line -ErrorAction Stop
    }
    catch {
        # Ignore access denied on C:\SetupComplete.log when running as normal user.
    }
}

function Normalize-SCOSEdition {
    param(
        [string]$RawEdition,
        [int]$RawLockdown
    )

    $normalizedEdition = "Standard"
    $normalizedLockdown = 1

    if ($RawEdition -and $RawEdition.Trim().Equals("Developer", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedEdition = "Developer"
        $normalizedLockdown = 0
    }
    elseif ($RawEdition -and $RawEdition.Trim().Equals("Standard", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedEdition = "Standard"
        $normalizedLockdown = 1
    }
    elseif ($RawLockdown -eq 0) {
        $normalizedEdition = "Developer"
        $normalizedLockdown = 0
    }

    return @{
        Edition = $normalizedEdition
        Lockdown = $normalizedLockdown
    }
}

Write-LauncherLog "SCOS first-login setup launcher started."
Write-LauncherLog "Received ScriptsRoot parameter: $ScriptsRoot"
Write-LauncherLog "Received Edition parameter: $Edition"
Write-LauncherLog "Received Lockdown parameter: $Lockdown"

# Read SetupComplete state files as the trusted fallback/source of truth.
if (Test-Path $EditionFile) {
    try {
        $fileEdition = (Get-Content $EditionFile -Raw).Trim()

        if (-not [string]::IsNullOrWhiteSpace($fileEdition)) {
            Write-LauncherLog "Read edition from file: $fileEdition"
            $Edition = $fileEdition
        }
    }
    catch {
        Write-LauncherLog "WARN: Failed to read edition file: $($_.Exception.Message)"
    }
}
else {
    Write-LauncherLog "WARN: Edition file missing. Using current/default edition: $Edition"
}

if (Test-Path $LockdownFile) {
    try {
        $fileLockdownRaw = (Get-Content $LockdownFile -Raw).Trim()
        $fileLockdown = 1

        if ([int]::TryParse($fileLockdownRaw, [ref]$fileLockdown)) {
            Write-LauncherLog "Read lockdown from file: $fileLockdown"
            $Lockdown = $fileLockdown
        }
    }
    catch {
        Write-LauncherLog "WARN: Failed to read lockdown file: $($_.Exception.Message)"
    }
}
else {
    Write-LauncherLog "WARN: Lockdown file missing. Using current/default lockdown: $Lockdown"
}

$normalized = Normalize-SCOSEdition -RawEdition $Edition -RawLockdown $Lockdown
$Edition = $normalized.Edition
$Lockdown = $normalized.Lockdown

Write-LauncherLog "Final normalized Edition: $Edition"
Write-LauncherLog "Final normalized Lockdown: $Lockdown"
Write-LauncherLog "ScriptsRoot: $ScriptsRoot"
Write-LauncherLog "Setup UI: $SetupUi"

if (-not (Test-Path $SetupUi)) {
    Write-LauncherLog "ERROR: SCOS setup UI missing: $SetupUi"
    exit 1
}

$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

$ArgumentList = @(
    "-STA",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "`"$SetupUi`"",
    "-ScriptsRoot",
    "`"$ScriptsRoot`"",
    "-Edition",
    "`"$Edition`"",
    "-Lockdown",
    "$Lockdown"
)

try {
    Write-LauncherLog "Launching SCOS setup UI elevated in visible user session..."
    Write-LauncherLog "Passing Edition to UI: $Edition"
    Write-LauncherLog "Passing Lockdown to UI: $Lockdown"

    $process = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList $ArgumentList `
        -Verb RunAs `
        -Wait `
        -PassThru

    Write-LauncherLog "SCOS setup UI exited with code $($process.ExitCode)."

    exit $process.ExitCode
}
catch {
    Write-LauncherLog "ERROR: Failed to launch elevated SCOS setup UI: $($_.Exception.Message)"
    exit 1
}