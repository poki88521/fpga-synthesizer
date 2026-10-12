#============================================================================
#  sync_src.ps1 —— 把仓库内容同步到本 Gowin 工程（改完 RTL / 表 / 波表就跑一次）
#
#  背景：Gowin 工程用的是 src/ 下的**副本**，不是仓库里的 rtl/。
#        改了仓库 RTL 却忘了同步，综合的还是旧代码 —— 这个坑踩过，
#        所以做成脚本，改完直接跑它。
#
#  用法：  pwsh -ExecutionPolicy Bypass -File board/full_system/sync_src.ps1
#
#  同步内容：
#    rtl/{channel,common,global,scheduler,top,voice}/*.v  ->  src/<同名目录>/
#    rtl/scheduler/{pan_gl,pan_gr,bend_exp,note_inc}.hex  ->  data/
#    wave_table/out/wave_table.{hex,ini}                  ->  data/
#        （RTL 里的 $readmemh 用 "data/xxx.hex"，
#          WAVE_INIT_FILE = "data/wave_table.hex"，
#          Gowin 按**工程工作目录**解析这些相对路径）
#    rtl/top/full_top.cst / .sdc                          ->  full_system.cst / .sdc
#
#  ⚠ data/ 整个目录是**构建产物**，已在 .gitignore 中忽略。
#     真源头是仓库的 rtl/scheduler/*.hex 与 wave_table/out/。
#
#  ⚠ rtl/extra/ 有意不同步（留档模块，不进综合）
#============================================================================
$ErrorActionPreference = 'Stop'

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path   # board/full_system/
$ROOT = (Resolve-Path (Join-Path $HERE '..\..')).Path     # 仓库根

Write-Host "仓库根: $ROOT"
Write-Host "工程  : $HERE"
Write-Host ""

$n = 0
foreach ($d in 'channel', 'common', 'global', 'scheduler', 'top', 'voice') {
    $src = Join-Path $ROOT "rtl\$d"
    $dst = Join-Path $HERE "src\$d"
    if (-not (Test-Path $src)) { Write-Host "  跳过（仓库无）: rtl\$d" -ForegroundColor Yellow; continue }
    New-Item -ItemType Directory -Force $dst | Out-Null
    $files = Get-ChildItem $src -Filter *.v -File
    Copy-Item "$src\*.v" $dst -Force
    Write-Host ("  src\{0,-10} <- {1,2} 个 .v" -f $d, $files.Count)
    $n += $files.Count
}

# ---- 所有 $readmemh 需要的数据 → data/ ----
$dataDir = Join-Path $HERE 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null

foreach ($h in 'pan_gl.hex', 'pan_gr.hex', 'bend_exp.hex', 'note_inc.hex') {
    Copy-Item (Join-Path $ROOT "rtl\scheduler\$h") $dataDir -Force
}
Write-Host "  data\        <- pan_gl / pan_gr / bend_exp / note_inc.hex"

Copy-Item (Join-Path $ROOT 'wave_table\out\wave_table.hex') $dataDir -Force
Copy-Item (Join-Path $ROOT 'wave_table\out\wave_table.ini') $dataDir -Force -ErrorAction SilentlyContinue
Write-Host "  data\        <- wave_table.hex (+ .ini)"

# ---- 清理旧的散落位置（历史遗留）----
foreach ($stale in 'pan_gl.hex', 'pan_gr.hex', 'bend_exp.hex', 'note_inc.hex') {
    $old = Join-Path $HERE $stale
    if (Test-Path $old) { Remove-Item $old -Force }
}
if (Test-Path (Join-Path $HERE 'wave_table')) { Remove-Item (Join-Path $HERE 'wave_table') -Recurse -Force }

# ---- 约束 ----
Copy-Item (Join-Path $ROOT 'rtl\top\full_top.cst') (Join-Path $HERE 'full_system.cst') -Force
Copy-Item (Join-Path $ROOT 'rtl\top\full_top.sdc') (Join-Path $HERE 'full_system.sdc') -Force
Write-Host "  工程根      <- full_system.cst / full_system.sdc"

Write-Host ""
Write-Host "同步完成：共 $n 个 .v" -ForegroundColor Green