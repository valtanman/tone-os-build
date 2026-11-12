param(
  [Parameter(Mandatory=$true)][string]$ReleaseDirectory,
  [int]$Iterations = 10
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$wshell = New-Object -ComObject WScript.Shell
$programs = @("toneedit-studio.exe", "toneedit-setup.exe", "toneedit-uninstall.exe")
$report = [System.Collections.Generic.List[object]]::new()
$root = (Resolve-Path $ReleaseDirectory).Path
$captures = Join-Path $env:RUNNER_TEMP "ToneEdit-GUI-10x"
New-Item -ItemType Directory -Force -Path $captures | Out-Null

function WindowTest([string]$filename, [int]$iteration) {
    $exe = Join-Path $root $filename
    if (!(Test-Path $exe)) { throw "Missing EXE: $exe" }
    $proc = if ($filename -eq "toneedit-uninstall.exe") {
        Start-Process -FilePath $exe -ArgumentList '--worker' -PassThru
    } else {
        Start-Process -FilePath $exe -PassThru
    }
    $opened = $false
    $operated = $false
    $screenshot = $false
    $message = ""
    try {
        for ($n=0; $n -lt 40; $n++) {
            Start-Sleep -Milliseconds 500
            $proc.Refresh()
            if ($proc.HasExited) { throw "Process exited during startup: $($proc.ExitCode)" }
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $opened=$true; break }
        }
        if (!$opened) { throw "No actual GUI window appeared within 20 seconds" }
        if (!($wshell.AppActivate($proc.Id))) { throw "Cannot activate GUI window" }
        Start-Sleep -Milliseconds 500
        if ($filename -eq "toneedit-studio.exe") {
            $wshell.SendKeys("^{n}")
            Start-Sleep -Milliseconds 250
            $wshell.SendKeys("^{f}")
            Start-Sleep -Milliseconds 250
            $wshell.SendKeys("ToneEdit-GUI-TEST-$iteration")
            Start-Sleep -Milliseconds 250
            $wshell.SendKeys("{ESC}")
        } else {
            $wshell.SendKeys("{TAB}")
            Start-Sleep -Milliseconds 250
            $wshell.SendKeys("+{TAB}")
        }
        $operated=$true
        $proc.Refresh()
        if ($proc.HasExited) { throw "Process crashed after GUI keyboard input" }
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        if ($screen.Width -le 0 -or $screen.Height -le 0) { throw "No available interactive screen" }
        $bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
            $path = Join-Path $captures ("round-{0:D2}-{1}.png" -f $iteration, $filename)
            $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            if ((Get-Item $path).Length -lt 2000) { throw "Captured screenshot is unexpectedly small" }
            $screenshot=$true
        } finally {
            $graphics.Dispose()
            $bmp.Dispose()
        }
    } catch {
        $message=$_.Exception.Message
    } finally {
        try {
            if (!$proc.HasExited) {
                [void]$proc.CloseMainWindow()
                if (!$proc.WaitForExit(3000)) { $proc.Kill(); $proc.WaitForExit() }
            }
        } catch {}
        $proc.Dispose()
    }
    $record=[PSCustomObject]@{
      iteration=$iteration; exe=$filename; window_open=$opened;
      keyboard_input=$operated; screenshot=$screenshot;
      passed=($opened -and $operated -and $screenshot -and !$message);
      error=$message
    }
    $report.Add($record)
    Write-Host ("GUI ROUND {0}/10 {1}: {2} {3}" -f $iteration, $filename, $(if($record.passed){"PASS"}else{"FAIL"}), $message)
}

for ($iteration=1; $iteration -le $Iterations; $iteration++) {
    foreach ($exe in $programs) { WindowTest $exe $iteration }
}
$report | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $captures "report.csv")
$report | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -Path (Join-Path $captures "report.json")
$pass = @($report | Where-Object passed).Count
Write-Host "Actual Windows GUI trials: passed $pass / $($Iterations * $programs.Count)"
if ($pass -ne $Iterations * $programs.Count) { throw "Windows GUI operation test failed: $pass passed" }
