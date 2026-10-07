#============================================================================
#  run_voice_tb.ps1 —— 单声部层 testbench 一键回归（Windows / PowerShell）
#
#  背景：仓库原有的 simulation/run_demo.sh 是 POSIX shell 脚本，
#        且本机没有 sh/bash/Git Bash，所以在 Windows 上需要这个等价入口。
#        Linux/工作机仍可用 .sh；两边跑的是同一批 RTL 与 TB。
#
#  用法：  pwsh -File simulation/run_voice_tb.ps1
#          （或在仓库根目录执行 .\simulation\run_voice_tb.ps1）
#
#  iverilog 定位顺序：环境变量 IV > PATH > 仓库自带的 iverilog/bin
#============================================================================
param(
    [string]$IV = $env:IV
)

$ErrorActionPreference = 'Continue'
# vvp 的输出是 UTF-8；不设这个，cmd 重定向出来的日志会被按 ANSI 读成乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path      # simulation/
$ROOT = Split-Path -Parent $HERE                             # 仓库根

#---------------- 定位 iverilog ----------------
# 顺序：-IV 参数 > 环境变量 IV > PATH > 仓库近邻的 iverilog/bin
# 注：本机 iverilog 在仓库根的**上两级**（F:\...\FPGA_music\iverilog\bin），故要 ../../。
$cands = @()
if ($IV) { $cands += $IV }
$cands += (Join-Path $ROOT '../../iverilog/bin')
$cands += (Join-Path $ROOT '../iverilog/bin')
$cands += (Join-Path $HERE '../../iverilog/bin')

$cmd = Get-Command iverilog -ErrorAction SilentlyContinue
if ($cmd) { $cands = @((Split-Path -Parent $cmd.Source)) + $cands }

$IV = $null
foreach ($c in $cands) {
    if ($c -and (Test-Path (Join-Path $c 'iverilog.exe'))) { $IV = (Resolve-Path $c).Path; break }
}
if (-not $IV) {
    Write-Host "FAIL: 找不到 iverilog。装好并加进 PATH，或用 -IV <目录> 指定。" -ForegroundColor Red
    exit 1
}

$IVERILOG = Join-Path $IV 'iverilog.exe'
# ⚠ PowerShell 变量名**大小写不敏感**：$VVP 与 $vvp 是同一个变量。
#   这里必须用两个明显不同的名字（解释器 vs 产物文件），否则循环里的
#   $vvp = "$OUT/$name.vvp" 会把解释器路径覆盖掉，cmd 变成"拿 .vvp 产物当程序执行"，
#   而且失败得悄无声息（正是这个坑让第一次全量回归假报 5/5 通过）。
$VVP_EXE  = Join-Path $IV 'vvp.exe'
$OUT      = Join-Path $HERE 'out'
New-Item -ItemType Directory -Force -Path $OUT | Out-Null

Write-Host "iverilog: $IV"
Write-Host ""

#---------------- RTL 源文件 ----------------
$RTL = @(
    "$ROOT/rtl/common/reset_sync.v",
    "$ROOT/rtl/common/sat24.v",
    "$ROOT/rtl/voice/dds_voice.v",
    "$ROOT/rtl/voice/svf_voice.v",
    "$ROOT/rtl/voice/adsr_vca.v",
    "$ROOT/rtl/voice/wave_table_rom.v",
    "$ROOT/rtl/voice/wave_fetch.v",
    "$ROOT/rtl/voice/voice_mono.v"
)

#---------------- 测试清单：TB 文件名 -> 需要的 RTL 子集 ----------------
$suite = @(
    @{ tb = 'tb_common.v';     top = 'tb_common';
       rtl = @('reset_sync.v','sat24.v') },
    @{ tb = 'tb_dds_voice.v';  top = 'tb_dds_voice';
       rtl = @('reset_sync.v','dds_voice.v') },
    @{ tb = 'tb_svf_voice.v';  top = 'tb_svf_voice';
       rtl = @('reset_sync.v','svf_voice.v') },
    @{ tb = 'tb_adsr_vca.v';   top = 'tb_adsr_vca';
       rtl = @('reset_sync.v','sat24.v','adsr_vca.v') },
    @{ tb = 'tb_voice_mono.v'; top = 'tb_voice_mono';
       rtl = @('reset_sync.v','sat24.v','dds_voice.v','svf_voice.v','adsr_vca.v',
               'wave_table_rom.v','wave_fetch.v','voice_mono.v') },
    # 用 wave_table/out/wave_table.hex 的**真实数据**跑整链。
    # 需先 `cd wave_table && python convert.py` 生成波表，否则本项会 FAIL。
    @{ tb = 'tb_wave_real.v';  top = 'tb_wave_real';
       rtl = @('reset_sync.v','sat24.v','dds_voice.v','svf_voice.v','adsr_vca.v',
               'wave_table_rom.v','wave_fetch.v','voice_mono.v') }
)

#---------------- 逐个编译 + 运行 ----------------
$pass = 0; $fail = 0
foreach ($t in $suite) {
    $name = $t.top
    Write-Host ("=" * 66)
    Write-Host "== $name" -ForegroundColor Cyan
    Write-Host ("=" * 66)

    $srcs = @()
    foreach ($r in $t.rtl) { $srcs += "$ROOT/rtl/common/$r"; $srcs += "$ROOT/rtl/voice/$r" }
    # 只保留真实存在的（common/ 与 voice/ 下同名文件不会同时存在）
    $srcs = $srcs | Where-Object { Test-Path $_ }
    $tbPath = "$HERE/tb/$($t.tb)"
    if (-not (Test-Path $tbPath)) { Write-Host "  跳过：找不到 $tbPath" -ForegroundColor Yellow; continue }

    $vvpOut = "$OUT/$name.vvp"
    & $IVERILOG -g2012 -s $name -o $vvpOut @srcs $tbPath 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  编译失败 (exit $LASTEXITCODE)" -ForegroundColor Red
        $fail++; continue
    }

    # 跑仿真。⚠ 不要用 `$log = & $VVP ... 2>&1` 捕获原生命令输出 ——
    # 在 Windows PowerShell 上这条路径不可靠（实测会拿到空数组），
    # 而"空日志不含 FAIL"会让失败被静默判成通过。
    # 改用 cmd /c 重定向到日志文件，再读文件，并显式要求日志非空。
    $logFile = "$OUT/$name.log"
    if (Test-Path $logFile) { Remove-Item $logFile -Force }
    # 在**仓库根**跑仿真：tb_wave_real 用 "wave_table/out/wave_table.hex"
    # 这样的仓库相对路径加载波表，cwd 必须是仓库根。
    Push-Location $ROOT
    cmd /c "`"$VVP_EXE`" `"$vvpOut`" > `"$logFile`" 2>&1"
    $runExit = $LASTEXITCODE
    Pop-Location

    $log = @()
    if (Test-Path $logFile) { $log = @(Get-Content $logFile -Encoding UTF8) }
    $log | ForEach-Object { Write-Host "  $_" }

    $ok = $true
    if ($runExit -ne 0)                 { $ok = $false; Write-Host "  运行退出码 $runExit" -ForegroundColor Red }
    if ($log.Count -eq 0)               { $ok = $false; Write-Host "  日志为空 —— 视为失败（不能用空日志判通过）" -ForegroundColor Red }
    elseif (-not ($log -match '\bPASS\b')) { $ok = $false; Write-Host "  日志中没有 PASS —— 视为失败" -ForegroundColor Red }
    if ($log -match '\bFAIL\b')         { $ok = $false }

    if ($ok) { $pass++ } else { $fail++ }
    Write-Host ""
}

Write-Host ("=" * 66)
if ($fail -eq 0) {
    Write-Host "全部通过：$pass / $($pass + $fail) 个 testbench" -ForegroundColor Green
    exit 0
} else {
    Write-Host "有失败：通过 $pass，失败 $fail" -ForegroundColor Red
    exit 1
}
