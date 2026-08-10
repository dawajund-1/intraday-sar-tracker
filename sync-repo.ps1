$ErrorActionPreference = "Stop"
Set-Location "C:\Users\Window\Documents\IntradayTracker-Cloud\intraday-sar-tracker"
$log = "C:\Users\Window\Documents\IntradayTracker-Cloud\intraday-sar-tracker\sync-repo.log"

try {
    $result = git pull --ff-only 2>&1
    if ($LASTEXITCODE -ne 0) {
        "$(Get-Date -Format o)  FAILED: $result" | Add-Content -Path $log
    } elseif ($result -notmatch "Already up to date") {
        "$(Get-Date -Format o)  Synced: $result" | Add-Content -Path $log
    }
} catch {
    "$(Get-Date -Format o)  ERROR: $_" | Add-Content -Path $log
}
