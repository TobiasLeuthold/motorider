# Launches MotoRider on the Pixel 8 with verbose logging.
# Writes a clean UTF-8 log to flutter_run.log so Claude can read it.
#
# Usage (in a dedicated PowerShell terminal at the project root):
#   .\run.ps1
#
# Once running:
#   r  -> hot reload    (UI tweaks)
#   R  -> hot restart   (DB schema / model changes)
#   q  -> quit

$device = "38290DLJH00109"
$log = Join-Path $PSScriptRoot "flutter_run.log"

# Stream both to console and to log file as UTF-8 (Out-File default is UTF-16 LE).
flutter run -v -d $device 2>&1 | ForEach-Object {
    $line = $_.ToString()
    Write-Host $line
    [System.IO.File]::AppendAllText($log, "$line`r`n", [System.Text.Encoding]::UTF8)
}
