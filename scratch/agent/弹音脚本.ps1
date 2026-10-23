# ============================================================================
#  逐个弹音（每次之间留间隔）—— 用于录音 / 主观听感测试
#
#  用法示例：
#    .\弹音脚本.ps1                                  # 默认 C2/C4/C6，各 2 秒，间隔 1 秒
#    .\弹音脚本.ps1 -Notes 36,48,60,72,84,96         # 自定义音高
#    .\弹音脚本.ps1 -Port COM7 -Hold 3 -Gap 2 -Vel 100
#    .\弹音脚本.ps1 -Volume 30                       # 先把通道音量设成 30
#
#  ⚠ 参数说明
#    -Notes   音符编号（36=C2, 48=C3, 60=C4, 72=C5, 84=C6, 96=C7）
#    -Hold    每个音保持几秒（默认 2）
#    -Gap     两次之间的静音间隔秒数（默认 1）
#    -Vel     力度 1~127（默认 100）
#    -Volume  通道音量 0~127（不传则不动）
# ============================================================================

param(
    [int[]] $Notes   = @(36, 60, 84),
    [int]   $Hold    = 2,
    [int]   $Gap     = 1,
    [int]   $Vel     = 100,
    [int]   $Volume  = -1,
    [string]$Port    = "COM7"
)

$ErrorActionPreference = "Stop"

# ---- 找到 midi_serial.py -----------------------------------------------------
#  脚本放在 scratch\agent\ 下，工程根目录在上面两级
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$midi = Join-Path $root "midi\midi_serial.py"

if (-not (Test-Path $midi)) {
    Write-Host "✗ 找不到 midi_serial.py：$midi" -ForegroundColor Red
    Write-Host "  请在工程根目录下运行，或用 -Port 指定端口后用绝对路径。" -ForegroundColor Yellow
    exit 1
}

# ---- 选 Python（优先用 stm32 环境，它装了串口库）------------------------------
$py = "D:\anaconda\envs\stm32\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

# ---- 音名表（方便打印）------------------------------------------------------
$names = @{
    24="C1"; 36="C2"; 48="C3"; 60="C4"; 72="C5"; 84="C6"; 96="C7"
    21="A0"; 33="A1"; 45="A2"; 57="A3"; 69="A4"; 81="A5"; 93="A6"
}
function Note-Name([int]$n) {
    if ($names.ContainsKey($n)) { return $names[$n] }
    return "note$n"
}

# ---- 频率（用于打印，便于和频谱对照）----------------------------------------
function Note-Freq([int]$n) {
    return [math]::Round(440.0 * [math]::Pow(2.0, ($n - 69) / 12.0), 1)
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " 端口     : $Port" -ForegroundColor Cyan
Write-Host " 力度     : $Vel" -ForegroundColor Cyan
Write-Host " 每音保持 : $Hold 秒" -ForegroundColor Cyan
Write-Host " 间隔     : $Gap 秒" -ForegroundColor Cyan
if ($Volume -ge 0) { Write-Host " 通道音量 : $Volume" -ForegroundColor Cyan }
Write-Host " 音符     : $($Notes -join ', ')" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ---- 可选：先设通道音量 + 表情到满 ------------------------------------------
if ($Volume -ge 0) {
    Write-Host "→ 设置通道音量 = $Volume" -ForegroundColor DarkGray
    & $py $midi -p $Port --byte-gap 320 cc 7  $Volume  | Out-Null
    Write-Host "→ 设置表情 = 127" -ForegroundColor DarkGray
    & $py $midi -p $Port --byte-gap 320 cc 11 127       | Out-Null
    Start-Sleep -Milliseconds 300
}

# ---- 先 panic，保证从干净状态开始 -------------------------------------------
Write-Host "→ 先 panic（清掉所有残留发声）" -ForegroundColor DarkGray
& $py $midi -p $Port panic 2>$null | Out-Null
Start-Sleep -Milliseconds 500

$i = 0
$total = $Notes.Count
foreach ($n in $Notes) {
    $i++
    $nm = Note-Name $n
    $fq = Note-Freq $n
    Write-Host ("[{0}/{1}] {2}（{3} Hz）力度 {4}，保持 {5} 秒 ..." -f `
                $i, $total, $nm, $fq, $Vel, $Hold) -ForegroundColor Green

    & $py $midi -p $Port --byte-gap 320 note $n $Vel --hold $Hold 2>$null | Out-Null

    if ($i -lt $total) {
        Write-Host ("         静音 {0} 秒" -f $Gap) -ForegroundColor DarkGray
        Start-Sleep -Seconds $Gap
    }
}

# ---- 收尾：再 panic 一次 ----------------------------------------------------
Start-Sleep -Milliseconds 300
& $py $midi -p $Port panic 2>$null | Out-Null

Write-Host ""
Write-Host "✓ 全部弹完（共 $total 个音）" -ForegroundColor Cyan
Write-Host ""
