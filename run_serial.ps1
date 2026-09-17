$ErrorActionPreference = "Continue"
$out = "d:\Locals\tosk\serial.log"
$err = "d:\Locals\tosk\debug.log"
if (Test-Path $out) { Remove-Item $out }
if (Test-Path $err) { Remove-Item $err }

$args = @(
    "-drive", "if=pflash,format=raw,readonly=on,file=ovmf.fd",
    "-serial", "file:$out",
    "-hda", "fat:rw:zig-out/img",
    "-m", "256M",
    "-display", "none"
)

$p = Start-Process -FilePath "D:\Program Files\qemu\qemu-system-x86_64.exe" `
    -ArgumentList $args `
    -RedirectStandardError $err `
    -NoNewWindow

Sleep 7

$procs = Get-Process -Name qemu-system-x86_64 -ErrorAction SilentlyContinue
foreach ($pr in $procs) { if ($pr.Pid -ne $null) { Stop-Process -Id $pr.Pid -Force } }

Sleep 1
Write-Host "--- SERIAL ---"
if (Test-Path $out) { Get-Content $out }
Write-Host "--- STDERR (tail) ---"
if (Test-Path $err) { Get-Content $err | Select-Object -Last 6 }