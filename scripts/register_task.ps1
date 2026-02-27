param(
    [string]$TaskName = "SnowCamReporter",
    [string]$ProjectDir = "C:\Users\hskai\Desktop\WebCamSnowMeasure",
    [int]$IntervalMinutes = 30
)

$runScript = Join-Path $ProjectDir "scripts\run_snow_reporter.ps1"
if (-not (Test-Path $runScript)) {
    Write-Error "Run script not found: $runScript"
    exit 1
}

$taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$runScript`" -ProjectDir `"$ProjectDir`""

schtasks /Create `
    /TN $TaskName `
    /SC MINUTE `
    /MO $IntervalMinutes `
    /TR $taskCommand `
    /F | Out-Host

Write-Host "Task '$TaskName' registered to run every $IntervalMinutes minutes."
