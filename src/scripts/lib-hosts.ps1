# =============================================================================
#  lib-hosts.ps1 —— 唯一允许改 hosts 的地方
#
#  为什么单独一个文件：
#    lib-common.ps1 有加载期副作用（建数据目录、Add-Type 编译探测类、输出
#    ##HELLO## 握手），不适合被 uninstall.ps1 这类脚本引用 —— 它们自己就定义了
#    Show/Ok/Warn 等同名函数，混在一起会互相覆盖。
#    这个文件**没有任何加载期副作用**，全是函数定义，谁都能安全 dot-source。
#
#  ============================================================================
#  ★★ 为什么绝不原地写 hosts ★★
#
#    Set-Content / [IO.File]::WriteAllText / Out-File 全都是「以 Create 模式
#    打开」—— 打开的那一瞬间文件就被**截断成 0 字节**，然后才往里写内容。
#
#    实测（Windows Defender 实时保护 + 行为监控开着时）：
#      原地写 hosts 有极高概率被拦下并抛 "流不可读" 或 "正由另一进程使用"，
#      而此时文件**已经是 0 字节**。
#    实测数据：连写 30 次，28 次得到一个 0 字节的 hosts。
#
#    后果不是「写入失败」，而是「用户 hosts 里原有的全部条目一起没了」——
#    这比不写严重得多。
#
#  ★ 正确做法 ★
#    1) 先快照当前 hosts（写坏了好还原）
#    2) 只写临时文件，并逐行校验临时文件
#    3) 用「复制/替换」覆盖 hosts —— CopyFile/copy 在这类环境里是可靠的，
#       原地截断写不是
#    4) 回读**逐行比对**；不通过就重试（最多 8 轮）
#    5) 每轮失败后若发现 hosts 已变空，立刻用快照还原
#       —— 绝不把用户停在一个比动手之前更糟的状态
#
#  返回 $true = hosts 确实写成了预期内容
#  返回 $false = 没写成，但 hosts 已还原/保持在动手前的状态
#
#  ★ 编码注意 ★
#    hosts 用 ASCII 写（这是 hosts 文件的传统，最兼容）。
#    因此**调用方不要在 hosts 行里放中文** —— 会被写成 "?"。
#    实测踩过：`# VRChat 免代理 installed` 变成了 `# VRChat ??? installed`。
#    注释一律用英文/拼音。
# =============================================================================

function Test-HostsHasBom {
    param([string]$Path)
    try {
        $b = [IO.File]::ReadAllBytes($Path)
        return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    } catch { return $false }
}

# ---------------------------------------------------------------------------
#  hosts 的编码：不要瞎猜，也不许"统一转 ASCII"
#
#  以前的写法有两个真问题：
#    ① 读：Get-Content 在 PS 5.1 下按系统 ANSI(GBK) 解码，用户的 UTF-8 注释会变乱码；
#    ② 写：无脑 ASCII 落盘，乱码再被写成 "????"，而且 lib-hosts 的逐行比对永远失败，
#       表现成"重试 8 次后报写入失败"，但文件其实已经被改坏了。
#
#  现在按文件自身判定并原样保留：
#    UTF-8 BOM / 纯 ASCII / 合法 UTF-8（无 BOM） → 用同一种编码写回
#    既不是 ASCII 也不是 UTF-8（例如 GBK）      → 返回 $null，调用方放弃写入（绝不猜）
# ---------------------------------------------------------------------------
function Get-HostsEncoding {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) {
            return @{ Enc = (New-Object System.Text.ASCIIEncoding); Bom = $false }
        }
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return @{ Enc = (New-Object System.Text.UTF8Encoding($true)); Bom = $true }
        }
        $ascii = $true
        foreach ($b in $bytes) { if ($b -ge 0x80) { $ascii = $false; break } }
        if ($ascii) { return @{ Enc = (New-Object System.Text.ASCIIEncoding); Bom = $false } }

        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        try { [void]$strict.GetString($bytes); return @{ Enc = $strict; Bom = $false } }
        catch { return $null }
    } catch { return $null }
}

# 用 hosts 自己的编码读成文本；读不到 / 编码不认识都返回 $null
function Read-HostsText {
    param([string]$Path)
    $info = Get-HostsEncoding $Path
    if ($null -eq $info) { return $null }
    try { return [IO.File]::ReadAllText($Path, $info.Enc) } catch { return $null }
}

# 把文件内容规范化成一个字符串：统一换行、去掉首尾空白。
# 这样「末尾多一个换行」「CRLF vs LF」这类无意义差异不会把成功判成失败，
# 但真正的差异（少行、内容不对、被写空）照样能查出来。
function Get-HostsText {
    param([string]$Path)
    $t = Read-HostsText $Path
    if ($null -eq $t) { return $null }
    $t = $t.Replace("`r`n", "`n").Replace("`r", "`n")
    return $t.Trim()
}

# 读回比对。比「有没有标记块」更严 —— 删块这种场景没有块可查。
function Test-HostsContent {
    param([string]$Path, [string[]]$Want)
    $got = Get-HostsText $Path
    if ($null -eq $got) { return $false }
    if ($got.Length -eq 0) { return $false }           # 0 字节 = 写坏了，绝不能算成功
    $exp = (($Want -join "`n")).Replace("`r`n", "`n").Replace("`r", "`n").Trim()
    return ($got -eq $exp)
}

function Get-HostsSnapshot {
    param([string]$Path)
    try { if (Test-Path $Path) { return [IO.File]::ReadAllText($Path) } } catch { }
    return ''
}

# 把一段字节直接推进 hosts（不做校验）。失败返回 $false，不抛。
function Copy-BytesToHosts {
    param([string]$Path, [string]$SourceFile)
    try { Copy-Item $SourceFile $Path -Force -ErrorAction Stop; return $true } catch { }
    # Copy-Item 被拦时退回 cmd 的 copy（走的是另一条 API 路径，能绕过一些拦截）
    try { & "$env:SystemRoot\System32\cmd.exe" /c "copy /Y `"$SourceFile`" `"$Path`"" 2>&1 | Out-Null } catch { }
    try { return (Test-Path $Path) } catch { return $false }
}

function Write-HostsSafe {
    param(
        [string]$Path,
        # 注意：这里故意用 [object[]] 而不是 [string[]]，而且不加 Mandatory。
        #   PowerShell 对「Mandatory 的 [string[]] 参数」会隐式做非空校验，
        #   hosts 内容里必然有空行（''），于是绑定阶段直接抛
        #   「无法将参数绑定到参数"Lines"，因为该参数为空字符串」——
        #   函数根本没被执行就返回了 null，表现成「写入失败但也不报错」。
        #   用 [object[]] 收，再在函数体里逐项 [string] 强转，稳。
        [object[]]$Lines,
        [string]$ExpectIp = '',        # 传了就额外要求读回内容里含这个 IP
        [int]$Retry = 8,
        [switch]$Quiet
    )

    if ([string]::IsNullOrEmpty($Path)) { return $false }

    $want = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Lines) { foreach ($x in $Lines) { $want.Add([string]$x) } }
    if ($want.Count -eq 0) { return $false }

    # 编码按文件自身判定，不瞎猜、也不无脑转 ASCII
    $info = Get-HostsEncoding $Path
    if ($null -eq $info) {
        if (-not $Quiet) {
            Write-Host '      [x] hosts 的编码既不是 ASCII 也不是 UTF-8（可能是 GBK），为避免写坏已放弃' -ForegroundColor Red
        }
        return $false
    }
    $enc = $info.Enc

    # 跨进程互斥：两个实例 / 两个脚本同时写时，后写的会把前一个的改动覆盖掉，
    # 甚至写出半截文件。这里用命名互斥体把"写"串起来（15 秒超时）。
    $mutex = $null
    $held = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\VrcTool.Hosts')
        $held = $mutex.WaitOne(15000)
    } catch { $held = $false }

    # 快照用**字节**保存：文本快照在还原时又要过一次编码，反而多一个出错点
    $snapshotBytes = $null
    try { if (Test-Path $Path) { $snapshotBytes = [IO.File]::ReadAllBytes($Path) } } catch { }
    $tmp = Join-Path $env:TEMP ("hosts.new.{0}.{1}.txt" -f $PID, (Get-Random))
    $last = ''

    for ($i = 1; $i -le $Retry; $i++) {

        # ---- 1) 写临时文件（用 hosts 自己的编码）----
        try {
            [IO.File]::WriteAllText($tmp, (($want -join "`r`n") + "`r`n"), $enc)
        } catch {
            $last = '写临时文件失败: ' + $_.Exception.Message.Split([char]10)[0]
            Start-Sleep -Milliseconds 400
            continue
        }

        # ---- 2) 临时文件先自校验，别把坏内容推上去 ----
        if (-not (Test-HostsContent $tmp $want)) {
            $last = ("临时文件校验不过（{0} 行，期望 {1} 行）" -f @(Get-Content $tmp -EA SilentlyContinue).Count, $want.Count)
            Start-Sleep -Milliseconds 400
            continue
        }

        # ---- 3) 覆盖 hosts ----
        [void](Copy-BytesToHosts -Path $Path -SourceFile $tmp)

        # ---- 4) 回读逐行比对 ----
        $ok = Test-HostsContent $Path $want
        if ($ok -and $ExpectIp) {
            $curText = Read-HostsText $Path
            $ok = ($null -ne $curText -and $curText.IndexOf($ExpectIp, [StringComparison]::Ordinal) -ge 0)
        }

        if ($ok) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            if ($held) { try { $mutex.ReleaseMutex() } catch { } }
            if ($mutex) { try { $mutex.Dispose() } catch { } }
            return $true
        }

        # ---- 5) 失败：hosts 被写空了就立刻还原（按原始字节还原，不经编码）----
        $curLen = -1
        try { $curLen = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length } catch { $curLen = -1 }

        if ($curLen -le 0) {
            if ($null -ne $snapshotBytes -and $snapshotBytes.Length -gt 0) {
                try {
                    [IO.File]::WriteAllBytes($tmp, $snapshotBytes)
                    [void](Copy-BytesToHosts -Path $Path -SourceFile $tmp)
                    $last = 'hosts 被写空，已用快照还原'
                } catch { $last = 'hosts 被写空，且还原失败' }
            } else {
                $last = 'hosts 被写空，且没有可用快照'
            }
        } else {
            $last = '回读校验未通过（内容与预期不一致）'
        }

        Start-Sleep -Milliseconds 600
    }

    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($held) { try { $mutex.ReleaseMutex() } catch { } }
    if ($mutex) { try { $mutex.Dispose() } catch { } }

    if (-not $Quiet) {
        Write-Host "      [x] 写入 hosts 失败：$last" -ForegroundColor Red
        Write-Host '      hosts 已保持在动手前的状态（没有留下 0 字节空文件）' -ForegroundColor DarkGray
    }
    return $false
}

# 从 hosts 里剥掉本工具写入的标记块，返回保留的行。
#
# ★ 只删「成对」的块 ★
#   旧实现是「看到 BEGIN 就进块，直到 EOF 都不出来」：用户手改 hosts 漏删
#   END、或写入中途被杀，就会把 BEGIN 之后用户自己的条目**全部静默删除**
#   （实测 6 行 hosts 剥完只剩 2 行）。
#   现在：先数 BEGIN/END，数量不配对就一行都不删，返回 Unpaired=True，
#   由调用方中止并提示手工处理 —— 宁可不动，也不能删错。
#
# ★ 读失败 ≠ 文件为空 ★
#   Get-Content -ErrorAction SilentlyContinue 会把「被占用 / 权限不足」和
#   「本来就没有」混成同一个空结果，后面再追加新块就等于把用户原内容整份
#   覆盖掉。所以这里读失败返回 Error，调用方必须中止。
function Remove-HostsBlock {
    param(
        [string]$Path,
        [string]$Begin = '# ===== VRChat-bypass BEGIN =====',
        [string]$End   = '# ===== VRChat-bypass END ====='
    )
    $keep = New-Object System.Collections.Generic.List[string]

    $text = Read-HostsText $Path
    if ($null -eq $text) {
        return @{ Lines = $keep; Removed = 0; HadBlock = $false; Unpaired = $false;
                  Error = '读取失败或编码无法识别（既不是 ASCII 也不是 UTF-8）' }
    }
    # 按 hosts 自身的编码读进来之后再切行，避免 PS 5.1 用 GBK 解码把中文读成乱码
    $lines = @($text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }

    $bCount = 0; $eCount = 0
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -eq $Begin) { $bCount++ }
        elseif ($t -eq $End) { $eCount++ }
    }

    if ($bCount -ne $eCount) {
        foreach ($l in $lines) { $keep.Add($l) }
        return @{ Lines = $keep; Removed = 0; HadBlock = $false; Unpaired = $true; Error = '' }
    }
    if ($bCount -eq 0) {
        foreach ($l in $lines) { $keep.Add($l) }
        return @{ Lines = $keep; Removed = 0; HadBlock = $false; Unpaired = $false; Error = '' }
    }

    $inb = $false
    $removed = 0
    foreach ($l in $lines) {
        $t = $l.Trim()
        # 用 -eq 精确比对整行，不再用 -match 子串匹配：否则
        # "10.0.0.5 nas  # ===== VRChat-bypass BEGIN =====" 这种内联注释
        # 也会被当成块起始，把后面的行全删掉。
        if ($t -eq $Begin) { $inb = $true;  $removed++; continue }
        if ($t -eq $End)   { $inb = $false; $removed++; continue }
        if (-not $inb) { $keep.Add($l) } else { $removed++ }
    }
    return @{ Lines = $keep; Removed = $removed; HadBlock = ($removed -gt 0); Unpaired = $false; Error = '' }
}
