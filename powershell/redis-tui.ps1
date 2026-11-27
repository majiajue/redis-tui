<#
.SYNOPSIS
    Redis 单机与集群管理工具，纯 PowerShell。
.DESCRIPTION
    单文件，自己实现 Redis 协议，不依赖 redis-cli、bash 或 WSL。
      1  查询单个 Key
      2  搜索 Key：模糊匹配，表格显示类型 / 过期时间 / 大小，按前缀分组；
         可按"仅无过期"、类型、前缀筛选，按序号查看值和批量删除
      3  Redis 监控：各节点内存、连接、每秒命令、命中率、主从状态，可自动刷新
.PARAMETER HostName
    登录节点 IP。省略则交互式输入。
.PARAMETER Port
    登录节点端口，默认 7000。
.PARAMETER Password
    旧版位置参数，支持字符串或 SecureString。推荐使用命名配置，在连接时隐藏输入。
.PARAMETER Profile
    加载指定名称的连接配置，连接时输入密码。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\redis-tui.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\redis-tui.ps1 10.0.0.1 7000 "密码"
#>
param(
    [Parameter(Position = 0)][string]$HostName,
    [Parameter(Position = 1)][int]$Port,
    [Parameter(Position = 2)]$Password,
    [string]$Profile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ============ 全局状态 ============
$script:LoginNode = ''          # 登录节点，形如 "ip:port"
$script:AllowWrites = $false
$script:UseColor = -not [Console]::IsOutputRedirected -and -not $env:NO_COLOR -and $env:TERM -ne 'dumb'
$script:SearchBudget = $null
$script:Secret = ''             # 仅在当前进程内用于 AUTH
$script:LoginProfile = $null
$script:RedisMode = 'cluster'
$script:Database = 0
$script:ProfileDirectory = $env:REDIS_TUI_CONFIG_DIR
if (-not $script:ProfileDirectory) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $script:ProfileDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RedisTui\Connections'
    }
    else {
        $configRoot = $env:XDG_CONFIG_HOME
        if (-not $configRoot) { $configRoot = Join-Path $env:HOME '.config' }
        $script:ProfileDirectory = Join-Path $configRoot 'redis-tui/connections'
    }
}
$script:Connections = @{}       # "ip:port" -> 连接对象
$script:ConnectTimeoutMs = 5000
$script:CrLf = [byte[]](13, 10)
$script:LastPattern = ''        # 上次搜索的 Pattern，回车可复用
$script:LineCount = 0           # 监控画面一次刷新写了多少行

# 控制台编码：中/日/韩文代码页和 UTF-8 原样不动；其它代码页显示不了中文，临时切到 UTF-8，退出时改回去。
# 不去改输入编码：在这台 Windows 上改它会连带改掉整个控制台窗口的代码页，而且脚本退出后也不会恢复。
# 重定向进来的输入（自动化调用）因此按系统默认编码解码
$script:OriginalOutputEncoding = $null
try {
    $cp = [Console]::OutputEncoding.CodePage
    if ($cp -ne 65001 -and $cp -ne 932 -and $cp -ne 936 -and $cp -ne 949 -and $cp -ne 950) {
        $script:OriginalOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
} catch { }

# ============ 输出与输入 ============
function Write-C {
    param([string]$Text, [ConsoleColor]$Color = 'Gray', [switch]$NoNewline, [ConsoleColor]$BackgroundColor)
    $style = @{ Object = $Text; NoNewline = $NoNewline }
    if ($script:UseColor) {
        $style.ForegroundColor = $Color
        if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $style.BackgroundColor = $BackgroundColor }
    }
    Write-Host @style
}

function Clear-Screen {
    if ([Console]::IsOutputRedirected) { return }
    try { Clear-Host } catch { }
}

function Get-ConsoleWidth {
    if ($env:REDIS_TUI_WIDTH) {
        $n = 0
        if ([int]::TryParse($env:REDIS_TUI_WIDTH, [ref]$n) -and $n -ge 40) { return $n }
    }
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -ge 40) { return $w }
    } catch { }
    return 120
}

function Get-PageSize([bool]$Grouped) {
    # 一页显示多少行；窗口高度减去表头和命令区的行数
    if ($env:REDIS_TUI_PAGE_SIZE) {
        $n = 0
        if ([int]::TryParse($env:REDIS_TUI_PAGE_SIZE, [ref]$n) -and $n -ge 1) { return $n }
    }
    $height = 40
    try {
        $h = $Host.UI.RawUI.WindowSize.Height
        if ($h -ge 12) { $height = $h }
    } catch { }
    $rows = $height - 18
    if ($Grouped) { $rows = [Math]::Floor($rows / 2) }
    return [int][Math]::Max(1, [Math]::Min(200, $rows))
}

function Write-Rule([int]$Width = 0) {
    if ($Width -le 0) { $Width = Get-ConsoleWidth }
    $n = $Width - 3
    if ($n -lt 10) { $n = 10 }
    Write-C ('  ' + ('─' * $n)) DarkGray
}

function Show-Header([int]$Width = (Get-ConsoleWidth)) {
    Write-Host ''
    Write-C '  ' -NoNewline
    Write-C ' REDIS ' White -BackgroundColor DarkRed -NoNewline
    $title = '  集群管理'
    $location = $script:LoginNode
    if ($script:RedisMode -eq 'standalone') {
        $title = '  单机管理'
        $location = "DB $script:Database · $location"
    }
    Write-C $title White
    if ($script:LoginNode) {
        Write-C '  ' -NoNewline
        if ($script:AllowWrites) { Write-C '[可写]' Black -BackgroundColor Yellow -NoNewline }
        else { Write-C '[只读]' White -BackgroundColor DarkBlue -NoNewline }
        Write-C '   节点 ' Gray -NoNewline
        Write-Fit $location White ($Width - 17)
        if ($script:LoginProfile.Name -or $script:LoginProfile.Tls) {
            $label = $script:LoginProfile.Name
            if (-not $label) { $label = '临时连接' }
            if ($script:LoginProfile.Tls) { $label += ' · TLS' }
            Write-Fit ('  配置 ' + $label) Gray ($Width - 1)
        }
    }
    else { Write-Host '' }
    Write-Rule $Width
}

# 文字的显示宽度：中文、全角符号算 2 格
function Get-TextWidth([string]$Text) {
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE4F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

# 按显示宽度补齐或截断成一列
function Format-Cell([string]$Text, [int]$Width, [switch]$Right) {
    if ((Get-TextWidth $Text) -gt $Width) {
        $sb = New-Object System.Text.StringBuilder
        $w = 0
        foreach ($ch in $Text.ToCharArray()) {
            $c = [int]$ch
            $cw = 1
            if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
                ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE4F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
                ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $cw = 2 }
            if ($w + $cw -gt $Width - 3) { break }
            [void]$sb.Append($ch)
            $w += $cw
        }
        # 用三个点表示截断：省略号在中文控制台里是全角的，会多占一格
        $Text = $sb.ToString() + '...'
    }
    $pad = $Width - (Get-TextWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    if ($Right) { return (' ' * $pad) + $Text }
    return $Text + (' ' * $pad)
}

function Write-Fit([string]$Text, [ConsoleColor]$Color, [int]$Width) {
    Write-C ((Format-Cell (Convert-ToSafeText $Text) $Width).TrimEnd()) $Color
}

# 读一行；输入结束时返回 $null（与空输入区分开，避免菜单死循环）
function Read-Line([string]$Prompt) {
    $value = Read-Host -Prompt $Prompt
    if ($null -eq $value) { return $null }
    return [string]$value
}

function Read-Password([string]$Prompt) {
    # 重定向输入时直接从标准输入读取，避免回显密码。
    if ([Console]::IsInputRedirected) {
        Write-C $Prompt Gray
        return [Console]::ReadLine()
    }
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    if ($null -eq $secure) { return '' }
    return (Convert-ToPlain $secure)
}

function Pause-Script { $null = Read-Host '按回车继续...' }

function Show-Error($Err) {
    Write-C ('× ' + $Err.Exception.Message) Red
    # 设置环境变量 REDIS_TUI_DEBUG=1 时显示出错位置，便于排查
    if ($env:REDIS_TUI_DEBUG) {
        Write-C ('  出错位置: 第 {0} 行' -f $Err.InvocationInfo.ScriptLineNumber) DarkGray
        foreach ($frame in ([string]$Err.ScriptStackTrace -split "`n")) {
            if ($frame) { Write-C ('  ' + $frame.Trim()) DarkGray }
        }
    }
}

function Convert-ToPlain($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Security.SecureString]) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return [string]$Value
}

# ============ 格式化 ============
function Format-Ttl($Ttl) {
    if ($null -eq $Ttl) { return '-' }
    $s = [long]$Ttl
    if ($s -eq -1) { return '永不过期' }
    if ($s -lt 0) { return '已失效' }
    $d = [int][Math]::Floor($s / 86400)
    $h = [int][Math]::Floor(($s % 86400) / 3600)
    $m = [int][Math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { return ('{0}天{1}小时' -f $d, $h) }
    if ($h -gt 0) { return ('{0}小时{1}分钟' -f $h, $m) }
    $sec = [int]($s % 60)
    if ($m -gt 0) {
        if ($sec -gt 0) { return ('{0}分钟{1}秒' -f $m, $sec) }
        return ('{0}分钟' -f $m)
    }
    return ('{0}秒' -f $sec)
}

function Format-Size($Bytes) {
    if ($null -eq $Bytes) { return '-' }
    $b = [double]$Bytes
    if ($b -lt 0) { return '—' }
    if ($b -lt 1024) { return ('{0} B' -f [long]$b) }
    if ($b -lt 1MB) { return ('{0:0.0} KB' -f ($b / 1KB)) }
    if ($b -lt 1GB) { return ('{0:0.0} MB' -f ($b / 1MB)) }
    if ($b -lt 1TB) { return ('{0:0.0} GB' -f ($b / 1GB)) }
    return ('{0:0.0} TB' -f ($b / 1TB))
}

function Format-Uptime($Seconds) {
    if ($null -eq $Seconds) { return '-' }
    $s = [long]$Seconds
    $d = [int][Math]::Floor($s / 86400)
    $h = [int][Math]::Floor(($s % 86400) / 3600)
    $m = [int][Math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { return ('{0}天{1}小时' -f $d, $h) }
    if ($h -gt 0) { return ('{0}小时{1}分' -f $h, $m) }
    return ('{0}分{1}秒' -f $m, ($s % 60))
}

function Format-Count($Value) {
    if ($null -eq $Value) { return '-' }
    return ('{0:N0}' -f [long]$Value)
}

function Get-TypeColor([string]$Type) {
    switch ($Type) {
        'string' { return 'Green' }
        'hash' { return 'Yellow' }
        'list' { return 'Cyan' }
        'set' { return 'Magenta' }
        'zset' { return 'Blue' }
        'stream' { return 'DarkCyan' }
    }
    return 'Gray'
}

function Get-OnOff([bool]$On) {
    if ($On) { return '开' }
    return '关'
}

function Format-Row([string[]]$Cells, [int[]]$Widths) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('  ')
    for ($i = 0; $i -lt $Widths.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append('  ') }
        $text = ''
        if ($i -lt $Cells.Count) { $text = $Cells[$i] }
        [void]$sb.Append((Format-Cell $text $Widths[$i] -Right ($i -gt 0)))
    }
    return $sb.ToString()
}

# ============ Redis 协议（RESP2） ============
function Get-SearchSetting([string]$Value, [int]$Default, [int]$Maximum) {
    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Maximum) {
        return $parsed
    }
    return $Default
}

function Test-SearchActive {
    $budget = $script:SearchBudget
    if ($null -eq $budget) { return $true }
    if ($budget.Reason) { return $false }
    $elapsed = $budget.Watch.ElapsedMilliseconds
    if ($elapsed -ge $budget.LimitMs) {
        $budget.Reason = '达到时间上限'
        return $false
    }
    if ($budget.Interactive -and $elapsed -ge $budget.NextKeyCheck) {
        $budget.NextKeyCheck = $elapsed + 75
        try {
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Q) {
                $budget.Reason = '用户已取消'
                return $false
            }
        }
        catch { $budget.Interactive = $false }
    }
    return $true
}

function Get-SearchTimeout([int]$Default) {
    if ($null -eq $script:SearchBudget) { return $Default }
    if (-not (Test-SearchActive)) { throw [OperationCanceledException]::new($script:SearchBudget.Reason) }
    $remaining = $script:SearchBudget.LimitMs - $script:SearchBudget.Watch.ElapsedMilliseconds
    return [int][Math]::Max(1, [Math]::Min(1500, $remaining))
}

function Set-ConnectionTimeout($Conn) {
    $timeout = Get-SearchTimeout 30000
    $Conn.Client.ReceiveTimeout = $timeout
    if ($null -eq $script:SearchBudget) { $Conn.Client.SendTimeout = 0 }
    else { $Conn.Client.SendTimeout = $timeout }
}

function Send-Command($Conn, [string[]]$Parts) {
    $ms = New-Object System.IO.MemoryStream
    $head = [System.Text.Encoding]::ASCII.GetBytes('*' + $Parts.Length + "`r`n")
    $ms.Write($head, 0, $head.Length)
    foreach ($part in $Parts) {
        $body = [System.Text.Encoding]::UTF8.GetBytes($part)
        $head = [System.Text.Encoding]::ASCII.GetBytes('$' + $body.Length + "`r`n")
        $ms.Write($head, 0, $head.Length)
        $ms.Write($body, 0, $body.Length)
        $ms.Write($script:CrLf, 0, 2)
    }
    $payload = $ms.ToArray()
    $Conn.Stream.Write($payload, 0, $payload.Length)
}

function Read-RespLine($Stream) {
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { throw (New-Object System.IO.IOException '连接被服务器关闭') }
        if ($b -eq 10) { break }
        if ($b -ne 13) { [void]$sb.Append([char]$b) }
    }
    return $sb.ToString()
}

# 读取一个回复。数组按原样返回（嵌套结构保留）。
# 默认把服务器返回的错误抛出为异常；-Raw 时错误作为带 RedisError 标记的对象返回（批量执行时用）
function Read-Reply {
    param($Stream, [switch]$Raw)
    if ($null -ne $script:SearchBudget -and -not (Test-SearchActive)) {
        throw [OperationCanceledException]::new($script:SearchBudget.Reason)
    }
    $line = Read-RespLine $Stream
    if ($line.Length -eq 0) { throw (New-Object System.IO.IOException '服务器返回了空行') }
    $kind = $line[0]
    $body = $line.Substring(1)

    if ($kind -eq '+') { return $body }

    if ($kind -eq '-') {
        if ($Raw) { return ([pscustomobject]@{ RedisError = $true; Message = $body }) }
        throw (New-Object System.InvalidOperationException $body)
    }

    if ($kind -eq ':') { return [long]$body }

    if ($kind -eq '$') {
        $len = [int]$body
        if ($len -lt 0) { return $null }
        $buffer = New-Object byte[] $len
        $offset = 0
        while ($offset -lt $len) {
            if ($null -ne $script:SearchBudget -and -not (Test-SearchActive)) {
                throw [OperationCanceledException]::new($script:SearchBudget.Reason)
            }
            $n = $Stream.Read($buffer, $offset, $len - $offset)
            if ($n -le 0) { throw (New-Object System.IO.IOException '连接中断') }
            $offset += $n
        }
        $null = $Stream.ReadByte()
        $null = $Stream.ReadByte()
        return [System.Text.Encoding]::UTF8.GetString($buffer)
    }

    if ($kind -eq '*') {
        $count = [int]$body
        if ($count -lt 0) { return $null }
        $items = New-Object object[] $count
        for ($i = 0; $i -lt $count; $i++) { $items[$i] = (Read-Reply $Stream -Raw:$Raw) }
        return ,$items
    }

    throw (New-Object System.IO.IOException ('无法识别的回复类型: ' + $kind))
}

function Test-RedisError($Reply) {
    if ($null -eq $Reply) { return $false }
    return ($Reply -is [pscustomobject] -and $null -ne $Reply.PSObject.Properties['RedisError'])
}

function Invoke-OnConnection($Conn, [string[]]$Parts) {
    try {
        Set-ConnectionTimeout $Conn
        Send-Command $Conn $Parts
        $Conn.Stream.Flush()
        $reply = Read-Reply $Conn.Stream
        return ,$reply
    } catch {
        if ($_.Exception -is [System.InvalidOperationException]) { throw }
        $inner = $_.Exception
        if ($inner.InnerException) { $inner = $inner.InnerException }
        throw (New-Object System.IO.IOException ('与 {0} 通信失败: {1}' -f $Conn.Node, $inner.Message))
    }
}

function New-SecureRedisStream([IO.Stream]$Transport, [string]$ServerName, [string]$CaPath, [int]$Timeout) {
    if ($CaPath) {
        if (-not ('RedisTuiTls' -as [type])) {
            # TLS 回调可能在后台线程运行。使用纯 .NET 回调，兼容 Windows PowerShell 5.1。
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;

public static class RedisTuiTls {
    public static SslStream Create(Stream transport, string caPath) {
        var roots = new X509Certificate2Collection();
        foreach (Match match in Regex.Matches(File.ReadAllText(caPath),
                    "-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\\s]+)-----END CERTIFICATE-----")) {
            roots.Add(new X509Certificate2(Convert.FromBase64String(match.Groups[1].Value)));
        }
        if (roots.Count == 0) throw new ArgumentException("CA file contains no PEM certificate");

        return new SslStream(transport, false, (sender, certificate, presented, errors) => {
            if (certificate == null ||
                (errors & (SslPolicyErrors.RemoteCertificateNameMismatch |
                           SslPolicyErrors.RemoteCertificateNotAvailable)) != 0) return false;

            using (var chain = new X509Chain())
            using (var leaf = new X509Certificate2(certificate)) {
                chain.ChainPolicy.ExtraStore.AddRange(roots);
                if (presented != null) {
                    foreach (X509ChainElement element in presented.ChainElements)
                        chain.ChainPolicy.ExtraStore.Add(element.Certificate);
                }
                chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                if (!chain.Build(leaf) || chain.ChainElements.Count == 0) return false;
                var anchor = Convert.ToBase64String(chain.ChainElements[chain.ChainElements.Count - 1].Certificate.RawData);
                foreach (X509Certificate2 root in roots) {
                    if (Convert.ToBase64String(root.RawData) == anchor) return true;
                }
                return false;
            }
        });
    }
}
'@
        }
        $tlsStream = [RedisTuiTls]::Create($Transport, $CaPath)
    }
    else {
        $tlsStream = [System.Net.Security.SslStream]::new($Transport, $false)
    }
    try {
        $certs = New-Object System.Security.Cryptography.X509Certificates.X509CertificateCollection
        $pending = $tlsStream.BeginAuthenticateAsClient(
            $ServerName, $certs, [System.Security.Authentication.SslProtocols]::None, $false, $null, $null
        )
        if (-not $pending.AsyncWaitHandle.WaitOne($Timeout)) { throw 'TLS 握手超时' }
        $tlsStream.EndAuthenticateAsClient($pending)
        return $tlsStream
    }
    catch {
        $tlsStream.Dispose()
        throw
    }
}

function New-Connection([string]$Node, [int]$Database = $script:Database) {
    $sep = $Node.LastIndexOf(':')
    $server = $Node.Substring(0, $sep).Trim('[', ']')
    $port = [int]$Node.Substring($sep + 1)

    $connectTimeout = Get-SearchTimeout $script:ConnectTimeoutMs
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($server, $port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($connectTimeout)) { throw '连接超时' }
        $client.EndConnect($pending)
        $client.NoDelay = $true
        $client.ReceiveTimeout = 30000
        $transport = $client.GetStream()
        if ($script:LoginProfile.Tls) {
            $verifyName = $script:LoginProfile.TlsName
            if (-not $verifyName) { $verifyName = $server }
            $transport = New-SecureRedisStream $transport $verifyName $script:LoginProfile.CaPath (Get-SearchTimeout $script:ConnectTimeoutMs)
        }

        $conn = [pscustomobject]@{
            Node   = $Node
            Client = $client
            Stream = [System.IO.BufferedStream]::new($transport, 65536)
        }
        if ($script:LoginProfile.Username -or $script:Secret) {
            $auth = @('AUTH')
            if ($script:LoginProfile.Username) { $auth += $script:LoginProfile.Username }
            $auth += $script:Secret
            try {
                $reply = Invoke-OnConnection $conn $auth
                if ([string]$reply -ne 'OK') { throw 'unexpected authentication reply' }
            }
            catch { throw 'Redis 认证失败，请核对 ACL 用户名和密码。' }
        }
        if ($Database -ne 0) {
            $reply = Invoke-OnConnection $conn @('SELECT', [string]$Database)
            if ($reply -ne 'OK') { throw 'Redis 未确认 SELECT' }
        }
        return $conn
    }
    catch {
        $why = $_.Exception.Message
        if ($_.Exception.InnerException) { $why = $_.Exception.InnerException.Message }
        $client.Close()
        throw [System.IO.IOException]::new(('无法连接 {0}: {1}' -f $Node, $why))
    }
}

function Get-Connection([string]$Node) {
    $conn = $script:Connections[$Node]
    if ($null -eq $conn) {
        $conn = New-Connection $Node
        $script:Connections[$Node] = $conn
    }
    return $conn
}

function Close-Connections {
    foreach ($conn in $script:Connections.Values) {
        try { $conn.Client.Close() } catch { }
    }
    $script:Connections.Clear()
}

# 对某个节点执行一条命令（默认登录节点）。遇到 MOVED / ASK 自动跳转到负责该槽位的节点
function Invoke-Redis {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$Node = ''
    )
    if (-not $Node) { $Node = $script:LoginNode }
    if (-not $Node) { throw (New-Object System.InvalidOperationException '尚未登录') }

    $ask = $false
    $retried = $false
    while ($true) {
        $conn = $null
        try {
            $conn = Get-Connection $Node
            if ($ask) {
                $null = Invoke-OnConnection $conn @('ASKING')
                $ask = $false
            }
            $reply = Invoke-OnConnection $conn (@($Command) + $Arguments)
            return ,$reply
        } catch {
            $ex = $_.Exception
            if ($ex -is [System.IO.IOException]) {
                # 连接可能被服务器按空闲断开：丢掉旧连接重试一次
                if ($null -ne $conn) {
                    $script:Connections.Remove($Node)
                    try { $conn.Client.Close() } catch { }
                    if (-not $retried -and (Test-SearchActive)) { $retried = $true; continue }
                }
                throw
            }
            if ($ex.Message -match '^(MOVED|ASK) \d+ (.+):(\d+)$') {
                $Node = $Matches[2] + ':' + $Matches[3]
                if ($Matches[1] -eq 'ASK') { $ask = $true }
                continue
            }
            throw
        }
    }
}

# 在一个节点上批量执行命令（流水线）：一次发完再按顺序收回复，每个回复与命令一一对应。
# 服务器返回的错误不抛出，以带 RedisError 标记的对象出现在对应位置
function Invoke-Pipeline {
    param(
        [Parameter(Mandatory = $true)][object[]]$Commands,
        [string]$Node = ''
    )
    if (-not $Node) { $Node = $script:LoginNode }
    if (-not $Node) { throw (New-Object System.InvalidOperationException '尚未登录') }
    if ($Commands.Count -eq 0) { return ,@() }

    $retried = $false
    while ($true) {
        $conn = $null
        try {
            $conn = Get-Connection $Node
            Set-ConnectionTimeout $conn
            foreach ($command in $Commands) { Send-Command $conn ([string[]]$command) }
            $conn.Stream.Flush()
            $replies = New-Object object[] $Commands.Count
            for ($i = 0; $i -lt $Commands.Count; $i++) { $replies[$i] = (Read-Reply $conn.Stream -Raw) }
            return ,$replies
        } catch {
            $ex = $_.Exception
            if ($null -ne $conn) {
                $script:Connections.Remove($Node)
                try { $conn.Client.Close() } catch { }
                if ($ex -is [System.IO.IOException] -and -not $retried -and (Test-SearchActive)) {
                    $retried = $true
                    continue
                }
            }
            throw
        }
    }
}

# ============ 集群 ============
function Get-ClusterNodes {
    $nodes = New-Object 'System.Collections.Generic.List[object]'
    if ($script:RedisMode -eq 'standalone') {
        $nodes.Add([pscustomobject]@{ Id = 'standalone'; Addr = $script:LoginNode; IsMaster = $true; MasterId = '-'; Connected = $true })
        return ,$nodes
    }

    # 解析 CLUSTER NODES：Id / Addr / IsMaster / MasterId / Connected
    $text = [string](Invoke-Redis -Command 'CLUSTER' -Arguments @('NODES'))
    foreach ($line in ($text -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $fields = $line -split '\s+'
        if ($fields.Count -lt 8) { continue }
        $flags = $fields[2] -split ','
        $addr = ($fields[1] -split '@')[0]
        if (($flags -contains 'noaddr') -or ($flags -contains 'handshake') -or -not $addr) { continue }
        $nodes.Add([pscustomobject]@{
                Id        = $fields[0]
                Addr      = $addr
                IsMaster  = (($flags -contains 'master') -and -not ($flags -contains 'slave'))
                MasterId  = $fields[3]
                Connected = ($fields[7] -eq 'connected')
            })
    }
    return ,$nodes
}

function Get-MasterNodes {
    $masters = New-Object 'System.Collections.Generic.List[string]'
    foreach ($node in (Get-ClusterNodes)) {
        if ($node.IsMaster) { $masters.Add($node.Addr) }
    }
    return ,$masters
}



# ============ 登录 ============
function Get-ProfileFile([string]$Name) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Name)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 60 -or $Name -match '[\x00-\x1F\x7F]') {
        throw '连接名称须为 1–60 个 UTF-8 字节。'
    }
    $hex = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    return Join-Path $script:ProfileDirectory ('p-' + $hex + '.connection')
}

function New-LoginProfile([string]$Name, [string]$HostName, [string]$PortText,
    [string]$Username, [string]$TlsFlag, [string]$CaPath, [string]$TlsName) {
    $number = 0
    if (-not $HostName -or $HostName -match '[\s\x00-\x1F\x7F]' -or $PortText -notmatch '^[0-9]{1,5}$' -or
        -not [int]::TryParse($PortText, [ref]$number) -or $number -lt 1 -or $number -gt 65535 -or
        ($Username + $CaPath) -match '[\x00-\x1F\x7F]' -or $TlsName -match '[\s\x00-\x1F\x7F]' -or
        ($TlsFlag -ne '1' -and ($TlsFlag -ne '0' -or $CaPath -or $TlsName))) {
        throw '主机、端口或连接选项无效。'
    }
    return @{
        Name = $Name; HostName = $HostName; Port = $number; Username = $Username
        Tls = $TlsFlag -eq '1'; CaPath = $CaPath; TlsName = $TlsName
    }
}

function Read-ConnectionProfile([string]$Path) {
    $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    if ($lines.Count -ne 8 -or $lines[0] -ne 'redis-tui-connection-v1' -or
        [IO.Path]::GetFullPath((Get-ProfileFile $lines[1])) -cne [IO.Path]::GetFullPath($Path)) {
        throw '连接配置文件格式无效。'
    }
    return New-LoginProfile $lines[1] $lines[2] $lines[3] $lines[4] $lines[5] $lines[6] $lines[7]
}

function Save-ConnectionProfile($Settings, [bool]$Replace) {
    $path = Get-ProfileFile $Settings.Name
    $null = [IO.Directory]::CreateDirectory($script:ProfileDirectory)
    $temp = Join-Path $script:ProfileDirectory ('.connection.' + [Guid]::NewGuid().ToString('N'))
    $flag = '0'
    if ($Settings.Tls) { $flag = '1' }
    $lines = @('redis-tui-connection-v1', $Settings.Name, $Settings.HostName, [string]$Settings.Port,
        $Settings.Username, $flag, $Settings.CaPath, $Settings.TlsName)
    try {
        [IO.File]::WriteAllText($temp, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        if ($Replace -and [IO.File]::Exists($path)) { [IO.File]::Replace($temp, $path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $path) }
    }
    finally { [IO.File]::Delete($temp) }
}

function Get-RedisMode {
    try {
        $info = [string](Invoke-Redis -Command 'INFO' -Arguments @('server'))
        if ($info -match '(?m)^redis_mode:standalone\r?$') { return 'standalone' }
        if ($info -match '(?m)^redis_mode:cluster\r?$') { return 'cluster' }
    } catch { }
    try {
        $null = Invoke-Redis -Command 'CLUSTER' -Arguments @('INFO')
    }
    catch {
        if ($_.Exception.Message -like '*cluster support disabled*') { return 'standalone' }
    }
    return 'cluster'
}

function Connect-LoginProfile($Settings, [string]$Secret) {
    $previousNode = $script:LoginNode
    $previousSecret = $script:Secret
    $previousSettings = $script:LoginProfile
    $previousConnections = $script:Connections
    $previousDatabase = $script:Database
    $script:Database = 0
    $script:LoginNode = "$($Settings.HostName):$($Settings.Port)"
    $script:Secret = $Secret
    $script:LoginProfile = $Settings
    $script:Connections = @{}
    Write-C '  正在测试连接...' DarkGray
    try {
        $reply = Invoke-Redis -Command 'PING'
        if ([string]$reply -ne 'PONG') { throw 'Redis 未返回 PONG' }
    }
    catch {
        Close-Connections
        $script:LoginNode = $previousNode
        $script:Secret = $previousSecret
        $script:LoginProfile = $previousSettings
        $script:Connections = $previousConnections
        $script:Database = $previousDatabase
        Write-C ('  × 连接失败: ' + $_.Exception.Message) Red
        Pause-Script
        return $false
    }
    foreach ($conn in $previousConnections.Values) {
        try { $conn.Client.Close() } catch { }
    }
    $script:RedisMode = Get-RedisMode
    $script:AllowWrites = $false
    $script:LastPattern = ''
    Write-C '  √ 连接成功' Green
    return $true
}

function Switch-Database {
    $text = Read-Line '  DB 编号 [非负整数，回车取消] > '
    if (-not $text -or -not $text.Trim()) { return }
    $text = $text.Trim()
    $database = 0
    if ($text -notmatch '^[0-9]{1,10}$' -or -not [int]::TryParse($text, [ref]$database)) {
        Write-C '  请输入有效的 DB 编号。' Yellow
        Pause-Script
        return
    }
    if ($database -eq $script:Database) { return }
    try { $connection = New-Connection $script:LoginNode $database }
    catch {
        Write-C ('  × 切换 DB 失败: ' + (Convert-ToSafeText $_.Exception.Message)) Red
        Pause-Script
        return
    }
    Close-Connections
    $script:Connections[$script:LoginNode] = $connection
    $script:Database = $database
    $script:AllowWrites = $false
    $script:LastPattern = ''
}

function Switch-WriteMode {
    if ($script:AllowWrites) { $script:AllowWrites = $false; return }
    Write-C ('  启用写入 · ' + (Convert-ToSafeText $script:LoginNode)) Yellow
    if ((Read-Line '  输入 WRITE 确认 > ') -ceq 'WRITE') { $script:AllowWrites = $true }
}

function Connect-SavedProfile($Settings) {
    Write-Fit ('  连接 {0} · {1}:{2}' -f $Settings.Name, $Settings.HostName, $Settings.Port) Cyan ((Get-ConsoleWidth) - 1)
    $secret = Read-Password '  密码 [无密码留空] >'
    if ($null -eq $secret) { return $false }
    return Connect-LoginProfile $Settings $secret
}

function New-InteractiveConnection {
    Write-C '  新建连接' Cyan
    $serverName = Read-Line '  主机 [默认 127.0.0.1] > '
    if ($null -eq $serverName) { return $false }
    $serverName = $serverName.Trim()
    if (-not $serverName) { $serverName = '127.0.0.1' }
    $portText = Read-Line '  端口 [默认 7000] > '
    if ($null -eq $portText) { return $false }
    $portText = $portText.Trim()
    if (-not $portText) { $portText = '7000' }
    $username = Read-Line '  ACL 用户名 [回车使用默认用户] > '
    if ($null -eq $username) { return $false }
    $tlsChoice = Read-Line '  启用 TLS [y/N] > '
    if ($null -eq $tlsChoice) { return $false }
    $flag = '0'; $caPath = ''; $verifyName = ''
    if ($tlsChoice.Trim() -in @('y', 'yes')) {
        $flag = '1'
        $caPath = Read-Line '  CA PEM 路径 [回车使用系统信任] > '
        if ($null -eq $caPath) { return $false }
        $verifyName = Read-Line '  TLS 验证名 [回车按节点地址校验] > '
        if ($null -eq $verifyName) { return $false }
        $verifyName = $verifyName.Trim()
        if ($caPath -and -not [IO.Path]::IsPathRooted($caPath)) {
            $caPath = Join-Path (Get-Location).Path $caPath
        }
    }
    elseif ($tlsChoice.Trim() -notin @('', 'n', 'no')) {
        Write-C '  TLS 设置请输入 y 或 n。' Yellow
        Pause-Script
        return $false
    }

    try { $settings = New-LoginProfile '' $serverName $portText $username $flag $caPath $verifyName }
    catch { Show-Error $_; Pause-Script; return $false }
    $secret = Read-Password '  密码 [无密码留空] >'
    if ($null -eq $secret -or -not (Connect-LoginProfile $settings $secret)) { return $false }
    $name = Read-Line '  保存为名称 [回车仅本次使用] > '
    if ($null -eq $name -or -not $name.Trim()) { return $true }
    $name = $name.Trim()
    try {
        $path = Get-ProfileFile $name
        $replace = [IO.File]::Exists($path)
        if ($replace -and (Read-Line '  同名配置已存在。输入 YES 更新 > ') -cne 'YES') { return $true }
        $candidate = $settings.Clone()
        $candidate.Name = $name
        Save-ConnectionProfile $candidate $replace
        $script:LoginProfile = $candidate
    }
    catch {
        Write-C ('  保存失败，当前连接可继续使用。' + $_.Exception.Message) Yellow
        Pause-Script
    }
    return $true
}

function Invoke-Login {
    while ($true) {
        $width = Get-ConsoleWidth
        Clear-Screen
        Show-Header $width
        Write-Host ''
        Write-C '  连接配置' Cyan
        $profiles = @(
            if ([IO.Directory]::Exists($script:ProfileDirectory)) {
                foreach ($file in (Get-ChildItem -LiteralPath $script:ProfileDirectory -Filter 'p-*.connection' -File | Sort-Object Name)) {
                    try { Read-ConnectionProfile $file.FullName } catch { }
                }
            }
        )
        if ($profiles.Count -eq 0) { return New-InteractiveConnection }
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            $entry = $profiles[$i]
            $mode = 'TCP'
            if ($entry.Tls) { $mode = 'TLS' }
            Write-Fit ('  {0}) {1}  ·  {2}:{3}  ·  {4}' -f ($i + 1), $entry.Name, $entry.HostName, $entry.Port, $mode) White ($width - 1)
        }
        Write-Host ''
        Write-HintLine n 新建连接 q 返回
        $choice = Read-Line '  连接 > '
        if ($null -eq $choice) { return $false }
        $choice = $choice.Trim()
        if (-not $choice -or $choice -eq 'q') { return $false }
        if ($choice -eq 'n') {
            if (New-InteractiveConnection) { return $true }
            continue
        }
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $profiles.Count) {
            if (Connect-SavedProfile $profiles[$index - 1]) { return $true }
        }
    }
}

# ============ 查看单个 Key ============
function Show-DetailHeader([int]$Width, [string]$Key, [string]$Type, $Ttl, $Size) {
    Clear-Screen
    Show-Header $Width
    Write-Host ''
    Write-C '  Key 详情' Cyan
    Write-C ('  ' + (Convert-ToSafeText $Key)) White
    Write-Host ''
    Write-C ('  ' + (Format-Cell '类型' 6)) DarkGray -NoNewline
    Write-C $Type (Get-TypeColor $Type)
    Write-C ('  ' + (Format-Cell '过期' 6) + (Format-Ttl $Ttl)) Gray
    if ($null -ne $Size) {
        Write-C ('  ' + (Format-Cell '大小' 6) + (Format-Size $Size)) Gray
    }
    Write-Rule $Width
}

function Format-DetailValue($Value) {
    $text = Convert-ToSafeText $Value
    if ($text -eq '') { return '（空）' }
    return $text
}

function Format-DetailTuple($Items, [int]$Index, [string]$Type) {
    $name = Format-DetailValue $Items[$Index]
    if ($Type -eq 'hash') { return '  ' + $name + ' = ' + (Format-DetailValue $Items[$Index + 1]) }
    if ($Type -eq 'zset') { return '  ' + $name + '    分数 ' + (Format-DetailValue $Items[$Index + 1]) }
    return '  ' + $name
}

# 游标和批内偏移构成一个页位置。只缓存当前 Redis 批次，前翻到旧批次时按游标重读。
function Get-DetailScanPage($Context, $Location) {
    $command = 'SSCAN'
    $stride = 1
    if ($Context.Type -eq 'hash') { $command = 'HSCAN'; $stride = 2 }
    $cursor = $Location.Position
    $offset = $Location.Offset
    $rounds = 0
    while ($true) {
        $rounds++
        if ($cursor -ne $Context.CacheCursor) {
            $arguments = @($Context.Key, $cursor, 'COUNT', [string]$Context.PageSize)
            if ($Context.FilterPattern) { $arguments += @('MATCH', $Context.FilterPattern) }
            $reply = Invoke-Redis -Command $command -Arguments $arguments
            $next = [string]$reply[0]
            if ($next -notmatch '^[0-9]+$' -or ($reply[1].Count % $stride) -ne 0) { throw 'Redis 返回了无效的扫描批次' }
            $Context.ScanBatch = $reply[1]
            $Context.CacheNext = $next
            $Context.CacheCursor = $cursor
        }
        $available = [int]($Context.ScanBatch.Count / $stride)
        if ($offset -lt $available -or $Context.CacheNext -eq '0' -or $rounds -ge 4) { break }
        $cursor = $Context.CacheNext
        $offset = 0
    }

    $end = [Math]::Min($offset + $Context.PageSize, $available)
    $lines = @(
        for ($i = $offset; $i -lt $end; $i++) {
            Format-DetailTuple $Context.ScanBatch ($i * $stride) $Context.Type
        }
    )
    $nextLocation = $null
    if ($end -lt $available) { $nextLocation = @{ Position = $cursor; Offset = $end } }
    elseif ($Context.CacheNext -ne '0') { $nextLocation = @{ Position = $Context.CacheNext; Offset = 0 } }
    return @{ Lines = $lines; Count = $lines.Count; Next = $nextLocation }
}

function Get-DetailRangePage($Context, $Location) {
    $start = [long]$Location.Position
    $last = $start + $Context.PageSize - 1
    $arguments = @($Context.Key, [string]$start, [string]$last)
    $command = 'LRANGE'
    $stride = 1
    if ($Context.Type -eq 'zset') {
        $command = 'ZRANGE'
        $stride = 2
        $arguments += 'WITHSCORES'
    }
    $items = Invoke-Redis -Command $command -Arguments $arguments
    if (($items.Count % $stride) -ne 0) { throw 'Redis 返回了无效的集合页' }
    $lines = @(
        for ($i = 0; $i -lt $items.Count; $i += $stride) {
            Format-DetailTuple $items $i $Context.Type
        }
    )
    $nextLocation = $null
    if ($lines.Count -eq $Context.PageSize -and ($null -eq $Context.Total -or $last -lt $Context.Total - 1)) {
        $nextLocation = @{ Position = [string]($last + 1); Offset = 0 }
    }
    return @{ Lines = $lines; Count = $lines.Count; Next = $nextLocation }
}

# 计算下一条的包含式起点，兼容 Redis 5/6.0 和完整的无符号 64 位 ID。
function Get-NextStreamId([string]$Id) {
    $parts = $Id.Split('-')
    $timestamp = [decimal]$parts[0]
    $sequence = [decimal]$parts[1]
    if ($sequence -eq [decimal][uint64]::MaxValue) {
        if ($timestamp -eq [decimal][uint64]::MaxValue) { return $null }
        return (([string]($timestamp + 1)) + '-0')
    }
    return ($parts[0] + '-' + [string]($sequence + 1))
}

function Get-DetailStreamPage($Context, $Location, [int]$Page) {
    $entries = Invoke-Redis -Command 'XRANGE' -Arguments @(
        $Context.Key, $Location.Position, '+', 'COUNT', [string]$Context.PageSize
    )
    $lines = @(
        foreach ($entry in $entries) {
            '  ' + $entry[0]
            $fields = $entry[1]
            for ($i = 0; $i + 1 -lt $fields.Count; $i += 2) {
                '  ' + (Format-DetailTuple $fields $i 'hash')
            }
        }
    )
    $nextLocation = $null
    if ($entries.Count -eq $Context.PageSize -and
        ($null -eq $Context.Total -or ($Page + 1) * $Context.PageSize -lt $Context.Total)) {
        $start = Get-NextStreamId $entries[-1][0]
        if ($start) { $nextLocation = @{ Position = $start; Offset = 0 } }
    }
    return @{ Lines = $lines; Count = $entries.Count; Next = $nextLocation }
}

function Show-Collection([string]$Key, [string]$Type, $Ttl, $Size) {
    $counter = @{ hash = 'HLEN'; set = 'SCARD'; list = 'LLEN'; zset = 'ZCARD'; stream = 'XLEN' }[$Type]
    $total = $null
    try { $total = Invoke-Redis -Command $counter -Arguments @($Key) } catch { }
    $pageSize = [Math]::Min(20, (Get-PageSize $false))
    $first = '0'
    if ($Type -eq 'stream') { $first = '-'; $pageSize = [Math]::Min(10, $pageSize) }
    $context = @{
        Key = $Key; Type = $Type; Total = $total; PageSize = $pageSize
        FilterPattern = ''; CacheCursor = ''; CacheNext = ''; ScanBatch = @()
    }
    $locations = New-Object 'System.Collections.Generic.List[object]'
    $locations.Add(@{ Position = $first; Offset = 0 })
    $page = 0
    $filter = ''
    $message = ''
    $load = $true
    $result = $null
    while ($true) {
        if ($load) {
            $message = ''
            $result = @{ Lines = @(); Count = 0; Next = $null }
            try {
                switch ($Type) {
                    { $_ -eq 'hash' -or $_ -eq 'set' } { $result = Get-DetailScanPage $context $locations[$page] }
                    'stream' { $result = Get-DetailStreamPage $context $locations[$page] $page }
                    default { $result = Get-DetailRangePage $context $locations[$page] }
                }
            }
            catch { $message = '读取当前页失败，按 r 重试。' }
            $load = $false
        }
        $width = Get-ConsoleWidth
        Show-DetailHeader $width $Key $Type $Ttl $Size
        Write-C ('  值 · 第 {0} 页 · 本页 {1} 项' -f ($page + 1), $result.Count) Cyan
        if ($null -ne $context.Total) { Write-C ('  集合总量 ' + $context.Total) Gray }
        if ($filter) { Write-Fit ('  字段包含 ' + $filter) Gray ($width - 1) }
        foreach ($line in $result.Lines) { Write-C $line White }
        if ($result.Count -eq 0 -and -not $message) {
            if ($result.Next) { Write-C '  本批无匹配，按 > 继续扫描。' Gray }
            else { Write-C '  本页没有可显示的数据。' Gray }
        }
        if ($message) { Write-C ('  ' + $message) Yellow }
        Write-Host ''
        Write-HintLine '<' 上页 '>' 下页 r 重试 q 返回
        if ($Type -eq 'hash') { Write-HintLine f 字段筛选 }

        $choice = Read-Line '  详情 > '
        if ($null -eq $choice) { return }
        $message = ''
        switch ($choice.Trim()) {
            { $_ -eq 'q' -or $_ -eq '' } { return }
            '<' {
                if ($page -gt 0) { $page--; $load = $true }
                else { $message = '已经是第一页。' }
            }
            '>' {
                if ($result.Next) {
                    $page++
                    if ($page -lt $locations.Count) { $locations[$page] = $result.Next }
                    else { $locations.Add($result.Next) }
                    $load = $true
                }
                else { $message = '当前没有下一页。' }
            }
            'r' {
                try { $context.Total = Invoke-Redis -Command $counter -Arguments @($Key) }
                catch { $context.Total = $null }
                $context.CacheCursor = ''
                $load = $true
            }
            'f' {
                if ($Type -eq 'hash') {
                    $filter = Read-Line '  字段包含 [回车清除] > '
                    if ($null -eq $filter) { return }
                    $context.FilterPattern = ''
                    if ($filter) { $context.FilterPattern = '*' + (ConvertTo-PrefixPattern $filter) }
                    $locations.Clear()
                    $locations.Add(@{ Position = '0'; Offset = 0 })
                    $page = 0
                    $context.CacheCursor = ''
                    $load = $true
                }
            }
        }
    }
}

function Format-JsonPreview([string]$Value) {
    if ($Value -notmatch '^\s*[\[{]') { return $null }

    # 只验证和缩进，保留字符串转义和数字原文。
    $null = ConvertFrom-Json -InputObject $Value -ErrorAction Stop
    $tokens = [regex]::Matches($Value, '"(?:\\.|[^"\\])*"|[{}\[\],:]|[^\s{}\[\],:]+')
    $formatted = [Text.StringBuilder]::new()
    $depth = 0
    $previous = ''
    foreach ($match in $tokens) {
        $token = $match.Value
        if ($token -in @('}', ']')) {
            $depth--
            if ($previous -notin @('{', '[')) { $null = $formatted.AppendLine().Append('  ' * $depth) }
        }
        elseif ($previous -in @('{', '[', ',')) { $null = $formatted.AppendLine().Append('  ' * $depth) }
        elseif ($previous -eq ':') { $null = $formatted.Append(' ') }
        if ($token -cin @('NaN', 'Infinity', '-Infinity') -or $depth -gt 100) { return $null }
        $null = $formatted.Append($token)
        if ($token -in @('{', '[')) { $depth++ }
        $previous = $token
    }
    return $formatted.ToString()
}

function Show-StringPreview([string]$Key) {
    $limit = 65536
    $length = $null
    try { $length = [long](Invoke-Redis -Command 'STRLEN' -Arguments @($Key)) } catch { }
    $value = [string](Invoke-Redis -Command 'GETRANGE' -Arguments @($Key, '0', [string]($limit - 1)))
    if ($null -eq $length) { Write-C "  预览最多 $limit B · 总长度不可用" Yellow }
    elseif ($length -gt $limit) { Write-C "  预览前 $limit B · 总计 $length B" Yellow }
    elseif ($length -lt $limit -and [Text.Encoding]::UTF8.GetByteCount($value) -lt $limit) {
        $formatted = $null
        try { $formatted = Format-JsonPreview $value } catch { }
        if ($formatted) {
            $value = $formatted
            Write-C '  JSON 格式化预览' Gray
        }
    }
    $value = [regex]::Replace($value.Replace("`r", ''), '[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F-\x9F]', '?')
    if ($value) { Write-Host -Object $value }
    else { Write-C '  (空 String)' Gray }
}

function Show-KeyDetail([string]$Key) {
    $width = Get-ConsoleWidth
    try {
        $type = [string](Invoke-Redis -Command 'TYPE' -Arguments @($Key))
        if (-not $type -or $type -eq 'none') {
            Clear-Screen
            Show-Header $width
            Write-Host ''
            Write-C '  Key 详情' Cyan
            Write-C ('  Key 不存在 · ' + (Convert-ToSafeText $Key)) Red
            Write-C '  从主菜单选择 2 搜索 Key。' Gray
        }
        else {
            $ttl = Invoke-Redis -Command 'TTL' -Arguments @($Key)
            $size = $null
            try { $size = Invoke-Redis -Command 'MEMORY' -Arguments @('USAGE', $Key) } catch { }
            if ($type -in @('hash', 'set', 'list', 'zset', 'stream')) {
                Show-Collection $Key $type $ttl $size
                return
            }
            Show-DetailHeader $width $Key $type $ttl $size
            Write-C '  值' Cyan
            if ($type -eq 'string') {
                Show-StringPreview $Key
            }
            else { Write-C ('  (不支持显示类型: ' + $type + ')') Gray }
        }
    }
    catch { Show-Error $_ }
    Write-Host ''
    Pause-Script
}

function Invoke-QueryKey {
    Clear-Screen
    Show-Header
    Write-Host ''
    Write-C '  查询单个 Key' Cyan
    $key = Read-Line '  Key > '
    if ($null -eq $key) { return }
    $key = $key.Trim()
    if (-not $key) { return }
    # 带通配符（* 或 ?，含全角）说明是想搜索，直接转到搜索界面
    if ($key -match '[*＊?？]') {
        Invoke-KeyList -InitialPattern $key
        return
    }
    Show-KeyDetail $key
}

# ============ 搜索 Key ============
# 把用户输入变成搜索用的 Pattern：
#   - 中文输入法可能把 * 和 ? 打成全角，统一换成半角
#   - 不带通配符时按模糊匹配处理，前后各补一个 *：输入 permission 就等于 *permission*
function Convert-ToPattern([string]$Text) {
    $t = $Text.Trim()
    $t = $t.Replace([string][char]0xFF0A, '*').Replace([string][char]0xFF1F, '?')
    if ($t -notmatch '[*?]') { $t = '*' + $t + '*' }
    return $t
}

function Get-KeyPrefix([string]$Key) {
    # 分组前缀：第一个冒号（含）之前的部分，例如 sit:data:permission:1 归到 sit:
    $i = $Key.IndexOf(':')
    if ($i -gt 0) { return $Key.Substring(0, $i + 1) }
    return ''
}

# 给一批 Key 补上类型和过期时间（按所在节点分批流水线执行）
function Add-KeyMetadata($Rows) {
    foreach ($group in ($Rows | Group-Object Node)) {
        $node = $group.Name
        $items = $group.Group
        for ($start = 0; $start -lt $items.Count; $start += 200) {
            if (-not (Test-SearchActive)) { return }
            $end = [Math]::Min($start + 200, $items.Count)
            $commands = New-Object 'System.Collections.Generic.List[object]'
            for ($i = $start; $i -lt $end; $i++) {
                $commands.Add(@('TYPE', $items[$i].Key))
                $commands.Add(@('TTL', $items[$i].Key))
            }
            $replies = $null
            try { $replies = Invoke-Pipeline -Node $node -Commands $commands.ToArray() } catch { $replies = $null }

            for ($i = $start; $i -lt $end; $i++) {
                $typeReply = $null
                $ttlReply = $null
                if ($null -ne $replies) {
                    $typeReply = $replies[($i - $start) * 2]
                    $ttlReply = $replies[($i - $start) * 2 + 1]
                }
                if ((Test-RedisError $typeReply) -or (Test-RedisError $ttlReply) -or $null -eq $typeReply -or $null -eq $ttlReply) {
                    # 槽位已迁移或批量失败：单条重试（会跟随 MOVED / ASK 跳转）
                    if (-not (Test-SearchActive)) { return }
                    try { $typeReply = Invoke-Redis -Node $node -Command 'TYPE' -Arguments @($items[$i].Key) } catch { $typeReply = $null }
                    try { $ttlReply = Invoke-Redis -Node $node -Command 'TTL' -Arguments @($items[$i].Key) } catch { $ttlReply = $null }
                    if (-not (Test-SearchActive)) { return }
                }
                $ttl = $null
                $n = 0L
                if ([long]::TryParse([string]$ttlReply, [ref]$n)) { $ttl = $n }
                $items[$i].Type = [string]$typeReply
                $items[$i].Ttl = $ttl
            }
        }
    }
}

# 给当前页的 Key 补上占用内存（只在显示时才查，避免对大量 Key 做不必要的计算）
function Add-KeySize($Rows) {
    $pending = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Rows) { if (-not $row.SizeLoaded) { $pending.Add($row) } }
    if ($pending.Count -eq 0) { return }
    foreach ($group in ($pending | Group-Object Node)) {
        $items = $group.Group
        $commands = New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in $items) { $commands.Add(@('MEMORY', 'USAGE', $row.Key)) }
        $replies = $null
        try { $replies = Invoke-Pipeline -Node $group.Name -Commands $commands.ToArray() } catch { $replies = $null }
        for ($i = 0; $i -lt $items.Count; $i++) {
            $reply = $null
            if ($null -ne $replies) { $reply = $replies[$i] }
            if ((Test-RedisError $reply) -or $null -eq $reply) {
                try { $reply = Invoke-Redis -Node $group.Name -Command 'MEMORY' -Arguments @('USAGE', $items[$i].Key) } catch { $reply = $null }
            }
            $size = -1L
            $n = 0L
            if ($null -ne $reply -and -not (Test-RedisError $reply)) {
                if ([long]::TryParse([string]$reply, [ref]$n)) { $size = $n }
            }
            $items[$i].Size = $size
            $items[$i].SizeLoaded = $true
        }
    }
}

function Search-ClusterKeys([string]$Pattern, [int]$Limit) {
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $scansOk = 0
    $reason = ''
    $nextProgress = 0
    try {
        $masters = Get-MasterNodes
        if ($masters.Count -eq 0) { throw 'CLUSTER NODES 没有返回主节点' }
    }
    catch {
        if (Test-SearchActive) { throw }
        $masters = @()
    }

    :nodes foreach ($master in $masters) {
        $cursor = '0'
        do {
            if (-not (Test-SearchActive)) { break nodes }
            $elapsed = $script:SearchBudget.Watch.ElapsedMilliseconds
            if ($elapsed -ge $nextProgress) {
                Write-C ('  已找到 {0} 个 · {1}' -f $rows.Count, $master) Gray
                $nextProgress = $elapsed + 1000
            }
            try {
                $reply = Invoke-Redis -Node $master -Command 'SCAN' -Arguments @($cursor, 'MATCH', $Pattern, 'COUNT', '500')
                $cursor = [string]$reply[0]
                if ($cursor -notmatch '^\d+$') { throw 'SCAN 返回了无效游标' }
            }
            catch {
                if (-not (Test-SearchActive)) { break nodes }
                $warnings.Add(('扫描失败 {0} · {1}' -f $master, $_.Exception.Message))
                break
            }
            foreach ($key in $reply[1]) {
                $name = [string]$key
                if (-not $seen.Add($name)) { continue }
                if ($rows.Count -ge $Limit) { $reason = '达到结果上限'; break nodes }
                $rows.Add([pscustomobject]@{
                    Key        = $name
                    Node       = $master
                    Type       = ''
                    Ttl        = $null
                    Size       = -1L
                    SizeLoaded = $false
                    Prefix     = (Get-KeyPrefix $name)
                })
            }
            if ($cursor -eq '0') { $scansOk++; break }
            if ($rows.Count -ge $Limit) { $reason = '达到结果上限'; break nodes }
        } while ($true)
    }
    $active = Test-SearchActive
    if ($scansOk -eq 0 -and $rows.Count -eq 0 -and $active -and -not $reason) {
        throw '所有主节点扫描失败'
    }
    if ($rows.Count -gt 0 -and $active) {
        Write-C ('  已找到 {0} 个 · 正在读取类型和 TTL' -f $rows.Count) Gray
        Add-KeyMetadata $rows
    }

    # 空类型表示读取尚未完成，只有明确返回 none 的 Key 才从结果移除。
    $alive = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $rows) {
        if ($row.Type -ne 'none') { $alive.Add($row) }
    }
    if ($script:SearchBudget.Reason) { $reason = $script:SearchBudget.Reason }
    return @{ Rows = $alive; Warnings = $warnings; StopReason = $reason }
}

function Invoke-WithSearchBudget([int]$Seconds, [scriptblock]$Action) {
    $script:SearchBudget = @{
        Watch = [System.Diagnostics.Stopwatch]::StartNew()
        LimitMs = $seconds * 1000
        Interactive = -not [Console]::IsInputRedirected
        NextKeyCheck = 0
        Reason = ''
    }
    try { & $Action }
    finally { $script:SearchBudget = $null }
}

function Find-Keys([string]$Pattern) {
    $limit = Get-SearchSetting $env:REDIS_TUI_SEARCH_LIMIT 2000 10000
    $seconds = Get-SearchSetting $env:REDIS_TUI_SEARCH_SECONDS 15 120
    Write-C ('  搜索上限 {0} 个 / {1}秒' -f $limit, $seconds) Gray
    if (-not [Console]::IsInputRedirected) { Write-C '  按 q 停止搜索' Gray }
    Invoke-WithSearchBudget $seconds { Search-ClusterKeys $Pattern $limit }
}

# 把 "1,3,5-8" 或 "all" 解析成当前列表里的行
function Resolve-RowSpec([string]$Spec, $Visible) {
    $result = New-Object 'System.Collections.Generic.List[object]'
    if ($Spec -eq 'all') {
        foreach ($row in $Visible) { $result.Add($row) }
        return ,$result
    }
    $wanted = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($part in ($Spec -split '[,\s]+')) {
        if (-not $part) { continue }
        if ($part -match '^(\d+)-(\d+)$') {
            $from = [int]$Matches[1]
            $to = [int]$Matches[2]
            if ($from -gt $to) { $t = $from; $from = $to; $to = $t }
            if ($to - $from -gt 100000) { $to = $from + 100000 }
            for ($i = $from; $i -le $to; $i++) { [void]$wanted.Add($i) }
        }
        elseif ($part -match '^\d+$') { [void]$wanted.Add([int]$part) }
        else { return $null }
    }
    # 序号就是当前列表里的位置（从 1 开始）
    foreach ($number in @($wanted | Sort-Object)) {
        if ($number -ge 1 -and $number -le $Visible.Count) { $result.Add($Visible[$number - 1]) }
    }
    return ,$result
}

function Remove-Keys($Rows) {
    if (-not $script:AllowWrites) { throw '只读会话，删除已禁用' }
    $result = [pscustomobject]@{ Removed = 0L; Failed = (New-Object 'System.Collections.Generic.List[string]') }
    foreach ($group in ($Rows | Group-Object Node)) {
        $node = $group.Name
        $items = $group.Group
        for ($start = 0; $start -lt $items.Count; $start += 500) {
            $end = [Math]::Min($start + 500, $items.Count)
            $commands = New-Object 'System.Collections.Generic.List[object]'
            for ($i = $start; $i -lt $end; $i++) { $commands.Add(@('UNLINK', $items[$i].Key)) }
            $replies = $null
            try { $replies = Invoke-Pipeline -Node $node -Commands $commands.ToArray() } catch { $replies = $null }

            for ($i = $start; $i -lt $end; $i++) {
                $reply = $null
                if ($null -ne $replies) { $reply = $replies[$i - $start] }
                if ((Test-RedisError $reply) -or $null -eq $reply) {
                    # 槽位已迁移或批量失败：单条重试（会跟随 MOVED / ASK 跳转）。UNLINK 对不存在的 Key 返回 0，重试不会重复计数
                    try { $reply = Invoke-Redis -Node $node -Command 'UNLINK' -Arguments @($items[$i].Key) } catch { $result.Failed.Add($items[$i].Key); continue }
                }
                if (Test-RedisError $reply) { $result.Failed.Add($items[$i].Key); continue }
                $n = 0L
                if ([long]::TryParse([string]$reply, [ref]$n)) { $result.Removed += $n }
            }
        }
    }
    return $result
}

# 按当前筛选条件算出可见列表（有前缀的按 Key 排序，无前缀的排在最后），并统计各组数量
function Update-Visible($State) {
    $withPrefix = New-Object 'System.Collections.Generic.List[object]'
    $noPrefix = New-Object 'System.Collections.Generic.List[object]'
    $groups = @{}
    foreach ($row in $State.Rows) {
        if ($State.NoExpire -and $row.Ttl -ne -1) { continue }
        if ($State.Type -and $row.Type -ne $State.Type) { continue }
        if ($State.Prefix -and $row.Prefix -ne $State.Prefix) { continue }
        if ($row.Prefix) { $withPrefix.Add($row) } else { $noPrefix.Add($row) }
        if ($groups.ContainsKey($row.Prefix)) { $groups[$row.Prefix] = $groups[$row.Prefix] + 1 } else { $groups[$row.Prefix] = 1 }
    }
    $visible = New-Object 'System.Collections.Generic.List[object]'
    # 注意：不能写成 @($list) | Sort-Object —— PowerShell 5.1 下对装着自定义对象的列表这样做会报"参数类型不匹配"
    if ($withPrefix.Count -gt 0) { foreach ($row in ($withPrefix.ToArray() | Sort-Object -Property Key)) { $visible.Add($row) } }
    if ($noPrefix.Count -gt 0) { foreach ($row in ($noPrefix.ToArray() | Sort-Object -Property Key)) { $visible.Add($row) } }
    $State.Visible = $visible
    $State.Groups = $groups
    $State.Total = $State.Rows.Count
    $State.Dirty = $false
}

function Write-KeyRow($Row, [int]$Number, [int]$KeyWidth, [int]$NumberWidth, [int]$TtlWidth, [int]$SizeWidth) {
    $ttlColor = 'Gray'
    if ($Row.Ttl -eq -1) { $ttlColor = 'Yellow' }
    elseif ($Row.Ttl -ge 0 -and $Row.Ttl -lt 600) { $ttlColor = 'Red' }

    Write-C ('  ' + (Format-Cell ([string]$Number) $NumberWidth -Right)) Gray -NoNewline
    Write-C ('  ' + (Format-Cell (Convert-ToSafeText $Row.Key) $KeyWidth)) White -NoNewline
    $typeText = $Row.Type
    if (-not $typeText) { $typeText = '-' }
    Write-C ('  ' + (Format-Cell $typeText 6)) (Get-TypeColor $Row.Type) -NoNewline
    Write-C ('  ' + (Format-Cell (Format-Ttl $Row.Ttl) $TtlWidth)) $ttlColor -NoNewline
    if ($SizeWidth -gt 0) {
        $sizeText = '-'
        if ($Row.SizeLoaded) { $sizeText = Format-Size $Row.Size }
        Write-C ('  ' + (Format-Cell $sizeText $SizeWidth -Right)) Gray -NoNewline
    }
    Write-Host ''
}

function Show-KeyTable($State, [string]$Pattern, $PageRows, [int]$Start, [int]$PageCount,
    [int]$Width, [int]$SizeWidth, [string]$Message, [ConsoleColor]$MessageColor) {
    Clear-Screen
    Show-Header $Width

    $limit = $Width - 1
    $shown = $State.Visible.Count
    Write-C '  搜索结果  ' Cyan -NoNewline
    Write-Fit $Pattern White ($limit - 12)
    $grouping = '关闭'
    if ($State.Grouped) { $grouping = '开启' }
    Write-C ('  显示 {0} / {1}    分组 {2}' -f $shown, $State.Total, $grouping) Gray
    $filters = @()
    if ($State.NoExpire) { $filters += '无过期' }
    if ($State.Type) { $filters += '类型 ' + $State.Type }
    if ($State.Prefix) { $filters += '前缀 ' + $State.Prefix }
    if ($filters.Count -eq 0) { $filters = @('全部') }
    Write-Fit ('  筛选  ' + ($filters -join '  ')) Gray $limit
    if ($State.Warnings.Count -gt 0) {
        Write-C ('  部分结果 · {0} 节点失败 [?]' -f $State.Warnings.Count) Yellow
    }
    if ($State.StopReason) { Write-C ('  部分结果 · ' + $State.StopReason) Yellow }
    if ($State.RefreshError) {
        Write-Fit ('  上次结果 · ' + $State.RefreshError) Red $limit
    }
    Write-Host ''

    if ($shown -eq 0) {
        if ($State.Total -eq 0 -and ($State.StopReason -or $State.Warnings.Count -gt 0)) {
            Write-C '  暂无可显示的 Key。输入 r 重试。' Gray
        }
        elseif ($State.Total -eq 0) { Write-C '  没有匹配的 Key。输入 n 换关键词。' Gray }
        else { Write-C '  筛选后无结果。输入 c 清除筛选。' Gray }
    }
    else {
        $numberWidth = [Math]::Max(4, ([string]$shown).Length)
        $ttlWidth = 10
        if ($SizeWidth -gt 0) { $ttlWidth = 14 }
        # 预留最后一格防止终端自动换行。
        $keyWidth = $limit - 14 - $numberWidth - $ttlWidth
        if ($SizeWidth -gt 0) { $keyWidth -= $SizeWidth + 2 }
        $keyWidth = [Math]::Min($keyWidth, 90)
        $columns = @((Format-Cell '#' $numberWidth -Right), (Format-Cell 'Key' $keyWidth),
            (Format-Cell '类型' 6), (Format-Cell '过期' $ttlWidth))
        if ($SizeWidth -gt 0) { $columns += Format-Cell '大小' $SizeWidth -Right }
        Write-C '  ' -NoNewline
        Write-C ($columns -join '  ') White -BackgroundColor DarkGray

        $lastPrefix = $null
        $first = $true
        $number = $Start
        foreach ($row in $PageRows) {
            $number++
            if ($State.Grouped -and ($first -or $row.Prefix -ne $lastPrefix)) {
                $count = $State.Groups[$row.Prefix]
                $label = $row.Prefix
                if (-not $label) { $label = '无前缀' }
                Write-Fit ('  {0} 个 · {1}' -f $count, $label) Cyan $limit
                $lastPrefix = $row.Prefix
                $first = $false
            }
            Write-KeyRow $row $number $keyWidth $numberWidth $ttlWidth $SizeWidth
        }
    }

    Write-Rule $Width
    if ($Message) { Write-Fit ('  ' + $Message) $MessageColor $limit }
    Write-HintLine ('第 {0} / {1} 页' -f ($State.Page + 1), $PageCount) '' '<' 上页 '>' 下页
    Write-HintLine 序号 查看 r 刷新 n 新搜 q 返回
    Write-HintLine f 无过期 t 类型 p 前缀 g 分组
    if ($script:AllowWrites) { Write-HintLine c 清筛选 d 删除 '?' 帮助 }
    else { Write-HintLine c 清筛选 '?' 帮助 }
}

function Write-HintLine {
    Write-C '  ' -NoNewline
    for ($i = 0; $i -lt $args.Count; $i += 2) {
        if ($i -gt 0) { Write-C '  ' -NoNewline }
        Write-C $args[$i] Cyan -NoNewline
        if ($args[$i + 1]) { Write-C (' ' + $args[$i + 1]) Gray -NoNewline }
    }
    Write-Host ''
}

function Read-ChoiceFromList([string]$Title, $Items) {
    # 返回选中的名称，空字符串表示全部，$null 表示取消或无效输入。
    $limit = (Get-ConsoleWidth) - 1
    Write-Host ''
    Write-C ('  ' + $Title) Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Fit ('  {0}) ({1}) {2}' -f ($i + 1), $Items[$i][1], $Items[$i][0]) Gray $limit
    }
    Write-C '  a) 全部    q) 取消' Gray
    $answer = Read-Line '  选择: '
    if ($null -eq $answer) { return $null }
    $answer = $answer.Trim().ToLower()
    if ($answer -eq '' -or $answer -eq 'a') { return '' }
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return [string]$Items[$n - 1][0] }
    return $null
}

function Get-ChoiceItems($Rows, [string]$Property) {
    $counts = @{}
    foreach ($row in $Rows) {
        $value = [string]$row.$Property
        if (-not $value) { continue }
        if ($counts.ContainsKey($value)) { $counts[$value] = $counts[$value] + 1 } else { $counts[$value] = 1 }
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @($counts.Keys | Sort-Object)) {
        $items.Add(@($name, $counts[$name]))
    }
    return ,$items.ToArray()
}

function Invoke-ListDelete($State, [string]$Spec) {
    if (-not $script:AllowWrites) { throw '只读会话，删除已禁用' }
    if ($State.RefreshError) { throw '请先刷新，再执行删除' }
    if ($Spec -eq 'all' -and ($State.StopReason -or $State.Warnings.Count -gt 0)) {
        throw '结果不完整，请按序号选择'
    }
    $targets = Resolve-RowSpec $Spec $State.Visible
    if ($null -eq $targets) {
        Write-C '  序号格式不对。示例: d 1,3,5-8 或 d all' Red
        Pause-Script
        return
    }
    if ($targets.Count -eq 0) {
        Write-C '  没有匹配的序号（只能选当前列表里的序号）' Red
        Pause-Script
        return
    }

    Write-Host ''
    Write-C ('  将删除 {0} 个 Key' -f $targets.Count) Yellow
    $show = [Math]::Min(10, $targets.Count)
    for ($i = 0; $i -lt $show; $i++) { Write-C ('    ' + (Convert-ToSafeText $targets[$i].Key)) Gray }
    if ($targets.Count -gt $show) { Write-C ('    ... 还有 {0} 个' -f ($targets.Count - $show)) DarkGray }
    $answer = Read-Line '  输入 YES 确认删除: '
    if ($answer -cne 'YES') {
        Write-C '  已取消' Gray
        Pause-Script
        return
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Remove-Keys $targets
    $failed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($name in $result.Failed) { [void]$failed.Add($name) }
    $gone = 0
    foreach ($target in $targets) {
        if ($failed.Contains($target.Key)) { continue }
        if ($State.Rows.Remove($target)) { $gone++ }
    }
    $State.Dirty = $true

    Write-Host ''
    Write-C ('  √ 已删除 {0} 个，用时 {1:0.0} 秒' -f $result.Removed, $watch.Elapsed.TotalSeconds) Green
    if ($result.Failed.Count -gt 0) {
        Write-C ('  × {0} 个删除失败' -f $result.Failed.Count) Red
        for ($i = 0; $i -lt [Math]::Min(5, $result.Failed.Count); $i++) { Write-C ('    ' + $result.Failed[$i]) Red }
    }
    Write-Host ''
    Pause-Script
}

function Show-ListScreen($Result, [string]$Pattern) {
    $state = @{
        Rows    = $Result.Rows
        Warnings = $Result.Warnings
        StopReason = $Result.StopReason
        RefreshError = ''
        NoExpire = $false
        Type    = ''
        Prefix  = ''
        Grouped = $true
        Page    = 0
        Dirty   = $true
        Visible = $null
        Groups  = @{}
        Total   = $Result.Rows.Count
    }
    $message = ''
    $messageColor = 'Gray'

    while ($true) {
        if ($state.Dirty) { Update-Visible $state }
        $width = Get-ConsoleWidth
        $sizeWidth = 0
        if ($width -ge 64) { $sizeWidth = 10 }
        $pageSize = Get-PageSize $state.Grouped
        $pageCount = [int][Math]::Ceiling($state.Visible.Count / [double]$pageSize)
        if ($pageCount -lt 1) { $pageCount = 1 }
        if ($state.Page -ge $pageCount) { $state.Page = $pageCount - 1 }
        $start = $state.Page * $pageSize
        $pageRows = New-Object 'System.Collections.Generic.List[object]'
        $stop = [Math]::Min($start + $pageSize, $state.Visible.Count)
        for ($i = $start; $i -lt $stop; $i++) { $pageRows.Add($state.Visible[$i]) }
        if ($sizeWidth -gt 0 -and $pageRows.Count -gt 0 -and -not $state.StopReason -and -not $state.RefreshError) {
            try { Add-KeySize $pageRows } catch { }
        }

        Show-KeyTable $state $Pattern $pageRows $start $pageCount $width $sizeWidth $message $messageColor
        $message = ''
        $messageColor = 'Gray'

        $line = Read-Line '  命令 > '
        if ($null -eq $line) { return 'back' }
        $text = $line.Trim()
        if (-not $text) { continue }

        $verb = $text
        $arg = ''
        $space = $text.IndexOf(' ')
        if ($space -gt 0) {
            $verb = $text.Substring(0, $space)
            $arg = $text.Substring($space + 1).Trim()
        }
        $verb = $verb.ToLower()

        if ($verb -eq 'q') { return 'back' }
        elseif ($verb -eq 'n') { return 'new' }
        elseif ($verb -eq 'r') {
            Write-C '  正在刷新搜索结果...' Gray
            try {
                $result = Find-Keys $Pattern
                if ($result.StopReason -and $result.Rows.Count -eq 0) {
                    $state.RefreshError = $result.StopReason
                    continue
                }
                $state.Rows = $result.Rows
                $state.Warnings = $result.Warnings
                $state.StopReason = $result.StopReason
                $state.Page = 0
                $state.Dirty = $true
                $state.RefreshError = ''
                if (-not $state.StopReason) { $message = '已刷新'; $messageColor = 'Green' }
            }
            catch {
                $state.RefreshError = $_.Exception.Message
            }
        }
        elseif ($verb -eq 'c') {
            $state.NoExpire = $false
            $state.Type = ''
            $state.Prefix = ''
            $state.Page = 0
            $state.Dirty = $true
        }
        elseif ($verb -eq '?' -or $verb -eq '？') {
            Write-Host ''
            Write-C '  查看：3、1,3 或 v 1-3' Gray
            if ($script:AllowWrites) {
                Write-C '  删除：d 1,3 或 d 1-3' Gray
                Write-C '  d all 选择完整筛选结果（含其他页）' Yellow
                Write-C '  删除前需输入 YES 确认' Gray
            }
            if ($sizeWidth -eq 0) { Write-C '  Key 详情可查看大小' Gray }
            if ($state.RefreshError) { Write-C ('  刷新失败：' + $state.RefreshError) Red }
            foreach ($warning in $state.Warnings) { Write-Fit ('  ' + $warning) Yellow ($width - 1) }
            Pause-Script
        }
        elseif ($verb -eq 'f') {
            $state.NoExpire = -not $state.NoExpire
            $state.Page = 0
            $state.Dirty = $true
        }
        elseif ($verb -eq 'g') {
            $state.Grouped = -not $state.Grouped
            $state.Page = 0
        }
        elseif ($verb -eq '>') {
            if ($state.Page + 1 -lt $pageCount) { $state.Page++ }
            else { $message = '已经是最后一页'; $messageColor = 'Yellow' }
        }
        elseif ($verb -eq '<') {
            if ($state.Page -gt 0) { $state.Page-- }
            else { $message = '已经是第一页'; $messageColor = 'Yellow' }
        }
        elseif ($verb -eq 't') {
            $picked = Read-ChoiceFromList '按类型筛选' (Get-ChoiceItems $state.Rows 'Type')
            if ($null -ne $picked) {
                $state.Type = $picked
                $state.Page = 0
                $state.Dirty = $true
            }
        }
        elseif ($verb -eq 'p') {
            $picked = Read-ChoiceFromList '按前缀筛选' (Get-ChoiceItems $state.Rows 'Prefix')
            if ($null -ne $picked) {
                $state.Prefix = $picked
                $state.Page = 0
                $state.Dirty = $true
            }
        }
        elseif ($verb -eq 'd') {
            try {
                if ($arg) { Invoke-ListDelete $state $arg }
                elseif (-not $script:AllowWrites) { throw '只读会话，删除已禁用' }
                else { throw '删除要带序号，例如: d 1,3,5-8 或 d all' }
            }
            catch { $message = $_.Exception.Message; $messageColor = 'Yellow' }
        }
        elseif ($verb -eq 'v' -or $verb -match '^\d') {
            $spec = $arg
            if ($verb -match '^\d') { $spec = $text -replace '\s+', ',' }
            if (-not $spec) { $message = '查看要带序号，例如: 3 或 v 1,3'; $messageColor = 'Yellow' }
            else {
                $targets = Resolve-RowSpec $spec $state.Visible
                if ($null -eq $targets -or $targets.Count -eq 0) { $message = '没有匹配的序号（只能选当前列表里的序号）'; $messageColor = 'Yellow' }
                else { foreach ($target in $targets) { Show-KeyDetail ([string]$target.Key) } }
            }
        }
        else {
            $message = ('不认识的命令: ' + $verb)
            $messageColor = 'Yellow'
        }
    }
}

function Invoke-KeyList([string]$InitialPattern = '') {
    # $InitialPattern 有值时（例如在"查询单个 Key"里输入了带通配符的内容）直接用它搜，不再询问
    $pattern = $InitialPattern
    while ($true) {
        if (-not $pattern) {
            Clear-Screen
            $width = Get-ConsoleWidth
            Show-Header $width
            Write-Host ''
            Write-C '  搜索 Key' Cyan
            Write-C '  输入关键词或通配符，如 user:*' Gray
            if ($script:LastPattern) { Write-Fit ('  回车沿用 ' + $script:LastPattern) Gray ($width - 1) }
            Write-C '  输入 :q 返回主菜单' Gray
            $typed = Read-Line '  搜索 > '
            if ($null -eq $typed) { return }
            $typed = $typed.Trim()
            if ($typed -eq ':q') { return }
            if ($typed) { $pattern = Convert-ToPattern $typed }
            elseif ($script:LastPattern) { $pattern = $script:LastPattern }
            else { return }
        }
        $pattern = Convert-ToPattern $pattern
        $script:LastPattern = $pattern

        Write-C '  正在搜索并读取类型、过期时间...' DarkGray
        $result = $null
        try { $result = Find-Keys $pattern }
        catch {
            Write-Host ''
            Show-Error $_
            Write-Host ''
            Pause-Script
            return
        }
        $action = Show-ListScreen $result $pattern
        if ($action -ne 'new') { return }
        # n = 换条件重新搜索：清空后回到上面的输入提示
        $pattern = ''
    }
}

# ============ Redis 监控 ============
function Get-InfoMap([string]$Node) {
    $text = [string](Invoke-Redis -Node $Node -Command 'INFO')
    $map = @{}
    $keys = 0L
    foreach ($line in ($text -split "`n")) {
        $line = $line.Trim()
        if (-not $line -or $line[0] -eq '#') { continue }
        $i = $line.IndexOf(':')
        if ($i -lt 1) { continue }
        $name = $line.Substring(0, $i)
        $value = $line.Substring($i + 1)
        if ($name -match '^db\d+$') {
            if ($value -match '(?:^|,)keys=(\d+)') { $keys += [long]$Matches[1] }
            continue
        }
        if (-not $map.ContainsKey($name)) { $map[$name] = $value }
    }
    $map['__keys'] = $keys
    return $map
}

function Get-InfoNum($Map, [string]$Name) {
    # 注意：PowerShell 的哈希表没有 TryGetValue 方法（那是泛型字典才有的）
    if ($null -ne $Map -and $Map.ContainsKey($Name)) {
        $value = $Map[$Name]
        if ($null -ne $value) {
            $n = 0L
            if ([long]::TryParse([string]$value, [ref]$n)) { return $n }
        }
    }
    return $null
}

function Get-InfoText($Map, [string]$Name) {
    if ($null -ne $Map -and $Map.ContainsKey($Name)) { return [string]$Map[$Name] }
    return ''
}

function Get-NodeStats([string]$Node) {
    $map = Get-InfoMap $Node
    $offset = Get-InfoNum $map 'slave_repl_offset'
    if ($null -eq $offset) { $offset = Get-InfoNum $map 'master_repl_offset' }
    return [pscustomobject]@{
        Node         = $Node
        Ok           = $true
        Role         = (Get-InfoText $map 'role')
        Version      = (Get-InfoText $map 'redis_version')
        Uptime       = (Get-InfoNum $map 'uptime_in_seconds')
        UsedMem      = (Get-InfoNum $map 'used_memory')
        MaxMem       = (Get-InfoNum $map 'maxmemory')
        Frag         = (Get-InfoText $map 'mem_fragmentation_ratio')
        Clients      = (Get-InfoNum $map 'connected_clients')
        OpsPerSec    = (Get-InfoNum $map 'instantaneous_ops_per_sec')
        Hits         = (Get-InfoNum $map 'keyspace_hits')
        Misses       = (Get-InfoNum $map 'keyspace_misses')
        Expired      = (Get-InfoNum $map 'expired_keys')
        Evicted      = (Get-InfoNum $map 'evicted_keys')
        Keys         = [long]$map['__keys']
        Slaves       = (Get-InfoNum $map 'connected_slaves')
        LinkStatus   = (Get-InfoText $map 'master_link_status')
        LastIo       = (Get-InfoNum $map 'master_last_io_seconds_ago')
        ReplOffset   = $offset
        RdbStatus    = (Get-InfoText $map 'rdb_last_bgsave_status')
        AofEnabled   = (Get-InfoNum $map 'aof_enabled')
        AofStatus    = (Get-InfoText $map 'aof_last_bgrewrite_status')
        Rejected     = (Get-InfoNum $map 'rejected_connections')
    }
}

function Write-MLine([string]$Text, [ConsoleColor]$Color = 'Gray', [int]$Width = 0) {
    if ($Width -le 0) { $Width = (Get-ConsoleWidth) - 1 }
    Write-C (Format-Cell $Text $Width) $Color
    $script:LineCount++
}

function Write-MTable([string]$Title, [string[]]$Headers, [int[]]$Widths, $Rows) {
    Write-MLine ''
    Write-MLine ('  ' + $Title) Cyan
    Write-MLine (Format-Row $Headers $Widths) DarkCyan
    if ($Rows.Count -eq 0) { Write-MLine (Format-Row @('-') $Widths) DarkGray }
    foreach ($row in $Rows) {
        Write-MLine (Format-Row ([string[]]$row.Cells) $Widths) $row.Color
    }
}

# 按窗口宽度挑选表格列：$Display 是按显示顺序排好的 @(列名, 宽度)，$Priority 是重要程度的先后。
# 返回 @(列名数组, 宽度数组)，列的先后仍按 $Display 的顺序
function Select-Columns($Display, $Priority, [int]$Available) {
    $chosen = New-Object 'System.Collections.Generic.HashSet[string]'
    $used = 0
    foreach ($name in $Priority) {
        $colWidth = 0
        foreach ($column in $Display) {
            if ($column[0] -eq $name) { $colWidth = [int]$column[1] }
        }
        $cost = $colWidth
        if ($chosen.Count -gt 0) { $cost += 2 }
        if ($chosen.Count -eq 0 -or $used + $cost -le $Available) {
            [void]$chosen.Add($name)
            $used += $cost
        }
    }
    $names = New-Object 'System.Collections.Generic.List[string]'
    $colWidths = New-Object 'System.Collections.Generic.List[int]'
    foreach ($column in $Display) {
        if ($chosen.Contains([string]$column[0])) {
            $names.Add([string]$column[0])
            $colWidths.Add([int]$column[1])
        }
    }
    return , @($names.ToArray(), $colWidths.ToArray())
}

function Get-MonitorCell($S, [string]$Column, $HitRate) {
    if ($Column -eq '节点') { return $S.Node }
    if (-not $S.Ok) {
        if ($Column -eq '角色') { return $S.RoleText }
        if ($Column -eq '内存') { return '× 无法连接' }
        return '—'
    }
    switch ($Column) {
        '角色' { return $S.RoleText }
        '内存' { return (Format-Size $S.UsedMem) }
        '上限' { if ($S.MaxMem -gt 0) { return (Format-Size $S.MaxMem) } return '不限' }
        '占用' { if ($S.MaxMem -gt 0) { return ('{0:0}%' -f (100.0 * $S.UsedMem / $S.MaxMem)) } return '-' }
        '碎片率' { if ($S.Frag) { return $S.Frag } return '-' }
        '客户端' { return (Format-Count $S.Clients) }
        '每秒命令' { return (Format-Count $S.OpsPerSec) }
        '命中率' { return $HitRate }
        '键数' { return (Format-Count $S.Keys) }
        '运行时间' { return (Format-Uptime $S.Uptime) }
        '主节点' { return $S.MasterAddr }
        '同步' { if ($S.LinkStatus) { return $S.LinkStatus } return '-' }
        '主从延迟' { if ($null -ne $S.LastIo) { return ('{0} 秒' -f $S.LastIo) } return '-' }
        '复制落后' { if ($null -ne $S.Lag) { return (Format-Size $S.Lag) } return '-' }
        '版本' { return $S.Version }
        '从节点' { if ($S.Role -eq 'master') { return (Format-Count $S.Slaves) } return '-' }
        '过期键' { return (Format-Count $S.Expired) }
        '驱逐键' { return (Format-Count $S.Evicted) }
        '拒绝连接' { return (Format-Count $S.Rejected) }
        'RDB' { if ($S.RdbStatus) { return $S.RdbStatus } return '-' }
        'AOF' { if ($S.AofEnabled -eq 1) { return $S.AofStatus } return '关' }
    }
    return '-'
}

function Show-MonitorSnapshot($Previous) {
    $width = Get-ConsoleWidth
    $now = Get-Date
    $all = Get-ClusterNodes
    $ordered = New-Object 'System.Collections.Generic.List[object]'
    $masterAddrById = @{}
    foreach ($node in $all) {
        if ($node.IsMaster) {
            $ordered.Add($node)
            $masterAddrById[$node.Id] = $node.Addr
        }
    }
    $masterCount = $ordered.Count
    foreach ($node in $all) {
        if (-not $node.IsMaster) { $ordered.Add($node) }
    }
    # "节点"列的宽度按实际地址长度定，窄窗口里好省出空间给其它列
    $addrWidth = 15
    foreach ($node in $all) {
        if ($node.Addr.Length -gt $addrWidth) { $addrWidth = $node.Addr.Length }
    }

    $clusterState = '-'
    $slotsText = '-'
    $ok = $null
    $assigned = $null
    try {
        $info = ''
        if ($script:RedisMode -eq 'cluster') {
            $info = [string](Invoke-Redis -Command 'CLUSTER' -Arguments @('INFO'))
        }
        foreach ($line in ($info -split "`n")) {
            $pair = ($line.Trim() -split ':', 2)
            if ($pair.Count -ne 2) { continue }
            if ($pair[0] -eq 'cluster_state') { $clusterState = $pair[1] }
            elseif ($pair[0] -eq 'cluster_slots_ok') { $ok = $pair[1] }
            elseif ($pair[0] -eq 'cluster_slots_assigned') { $assigned = $pair[1] }
        }
        if ($ok -and $assigned) { $slotsText = ('{0:N0} / {1:N0}' -f [long]$ok, [long]$assigned) }
    } catch { }

    # 逐个节点取 INFO；主节点排前面
    $stats = New-Object 'System.Collections.Generic.List[object]'
    $next = @{}
    foreach ($node in $ordered) {
        $roleText = '从'
        if ($node.IsMaster) { $roleText = '主' }
        $masterAddr = ''
        if (-not $node.IsMaster -and $masterAddrById.ContainsKey($node.MasterId)) { $masterAddr = $masterAddrById[$node.MasterId] }
        $s = $null
        try {
            $s = Get-NodeStats -Node $node.Addr
            if ($s.Role -eq 'master') { $roleText = '主' } elseif ($s.Role -eq 'slave') { $roleText = '从' }
        }
        catch {
            $s = [pscustomobject]@{ Node = $node.Addr; Ok = $false; Error = $_.Exception.Message }
        }
        $hitRate = '-'
        if ($s.Ok) {
            $prev = $Previous[$node.Addr]
            $dh = $null
            $dm = $null
            if ($null -ne $prev) {
                $dh = [long]$s.Hits - [long]$prev.Hits
                $dm = [long]$s.Misses - [long]$prev.Misses
                if ($dh -lt 0 -or $dm -lt 0) { $dh = $null; $dm = $null }
            }
            if ($null -ne $dh -and ($dh + $dm) -gt 0) { $hitRate = ('{0:0.0}%' -f (100.0 * $dh / ($dh + $dm))) }
            elseif (($s.Hits + $s.Misses) -gt 0) { $hitRate = ('{0:0.0}%' -f (100.0 * $s.Hits / ($s.Hits + $s.Misses))) }
            $next[$node.Addr] = @{ Hits = [long]$s.Hits; Misses = [long]$s.Misses }
        }
        $s | Add-Member -NotePropertyName RoleText -NotePropertyValue $roleText
        $s | Add-Member -NotePropertyName MasterAddr -NotePropertyValue $masterAddr
        $s | Add-Member -NotePropertyName IsMaster -NotePropertyValue $node.IsMaster
        $s | Add-Member -NotePropertyName HitRate -NotePropertyValue $hitRate
        $stats.Add($s)
    }

    # 从节点的复制落后字节数 = 主节点复制偏移量 - 从节点已复制的偏移量
    foreach ($s in $stats) {
        $lag = $null
        if ($s.Ok -and -not $s.IsMaster -and $s.MasterAddr) {
            foreach ($m in $stats) {
                if ($m.Ok -and $m.Node -eq $s.MasterAddr) {
                    $lag = [long]$m.ReplOffset - [long]$s.ReplOffset
                    if ($lag -lt 0) { $lag = 0 }
                }
            }
        }
        $s | Add-Member -NotePropertyName Lag -NotePropertyValue $lag
    }

    # ---- 标题与汇总 ----
    Write-MLine ''
    $title = '  Redis 集群监控'
    if ($script:RedisMode -eq 'standalone') { $title = '  Redis 单机监控' }
    $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
    $left = $width - 1 - (Get-TextWidth $stamp) - 2
    Write-MLine ($title + (' ' * [Math]::Max(1, $left - (Get-TextWidth $title))) + $stamp) White
    if ($script:RedisMode -eq 'cluster') {
        Write-MLine ('  集群状态 ' + $clusterState + '    槽位 ' + $slotsText + '    节点 ' + $stats.Count + ' 个 (' + $masterCount + ' 主 ' + ($stats.Count - $masterCount) + ' 从)') Cyan
    }
    $totalKeys = 0L
    $totalMem = 0L
    $totalClients = 0L
    $totalOps = 0L
    $reachable = 0
    foreach ($s in $stats) {
        if (-not $s.Ok) { continue }
        $reachable++
        $totalKeys += [long]$s.Keys
        if ($s.IsMaster) { $totalMem += [long]$s.UsedMem }
        $totalClients += [long]$s.Clients
        if ($s.IsMaster) { $totalOps += [long]$s.OpsPerSec }
    }
    $summary = '主节点合计'
    if ($script:RedisMode -eq 'standalone') { $summary = '实例合计' }
    Write-MLine ('  {0}: {1} 个键 · {2} · 每秒 {3} 条命令' -f $summary, (Format-Count $totalKeys), (Format-Size $totalMem), (Format-Count $totalOps)) Gray
    Write-MLine ('  全部节点客户端 {0}    可连接 {1} / {2}' -f (Format-Count $totalClients), $reachable, $stats.Count) Gray

    $problem = @{}
    foreach ($s in $stats) {
        $bad = -not $s.Ok
        if ($s.Ok) {
            if (-not $s.IsMaster -and $s.LinkStatus -ne 'up') { $bad = $true }
            if ($s.RdbStatus -eq 'err') { $bad = $true }
            if ($s.AofEnabled -eq 1 -and $s.AofStatus -eq 'err') { $bad = $true }
            if ($s.MaxMem -gt 0 -and (100.0 * $s.UsedMem / $s.MaxMem) -ge 90) { $bad = $true }
        }
        $problem[$s.Node] = $bad
    }

    # ---- 表 1：概览（列按窗口宽度取舍：先保证重要的列，放得下才加次要的列） ----
    $display = @(@('节点', $addrWidth), @('角色', 4), @('内存', 10), @('上限', 9), @('碎片率', 6), @('占用', 6), @('客户端', 7), @('每秒命令', 8), @('命中率', 8), @('键数', 9), @('运行时间', 11))
    $priority = @('节点', '角色', '内存', '客户端', '每秒命令', '命中率', '键数', '上限', '运行时间', '碎片率', '占用')
    $selection = Select-Columns $display $priority ($width - 3)
    $columns = $selection[0]
    $widths = $selection[1]
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $stats) {
        $cells = New-Object 'System.Collections.Generic.List[string]'
        foreach ($c in $columns) { $cells.Add((Get-MonitorCell $s $c $s.HitRate)) }
        $color = 'White'
        if ($problem[$s.Node]) { $color = 'Red' }
        $rows.Add(@{ Cells = $cells.ToArray(); Color = $color })
    }
    Write-MTable '概览' $columns $widths $rows

    # ---- 表 2：主从复制 ----
    if ($stats.Count -gt $masterCount) {
        $columns = @('节点', '主节点', '同步', '主从延迟', '复制落后')
        $widths = @($addrWidth, $addrWidth, 6, 10, 10)
        $rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($s in $stats) {
            if ($s.IsMaster) { continue }
            $cells = New-Object 'System.Collections.Generic.List[string]'
            foreach ($c in $columns) { $cells.Add((Get-MonitorCell $s $c $s.HitRate)) }
            $color = 'White'
            if ($problem[$s.Node]) { $color = 'Red' }
            $rows.Add(@{ Cells = $cells.ToArray(); Color = $color })
        }
        Write-MTable '主从复制' $columns $widths $rows
    }

    # ---- 表 3：持久化与累计计数（同样按窗口宽度取舍列） ----
    $display = @(@('节点', $addrWidth), @('运行时间', 11), @('过期键', 9), @('驱逐键', 9), @('拒绝连接', 8), @('RDB', 6), @('AOF', 6), @('从节点', 6), @('版本', 8))
    $priority = @('节点', '运行时间', 'RDB', 'AOF', '驱逐键', '过期键', '从节点', '拒绝连接', '版本')
    $selection = Select-Columns $display $priority ($width - 3)
    $columns = $selection[0]
    $widths = $selection[1]
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $stats) {
        $cells = New-Object 'System.Collections.Generic.List[string]'
        foreach ($c in $columns) { $cells.Add((Get-MonitorCell $s $c $s.HitRate)) }
        $color = 'White'
        if ($problem[$s.Node]) { $color = 'Red' }
        $rows.Add(@{ Cells = $cells.ToArray(); Color = $color })
    }
    Write-MTable '持久化与累计计数（自启动以来）' $columns $widths $rows

    # 取不到信息的节点把原因列出来："无法连接"四个字不足以判断是网络、密码还是权限问题
    $unreachable = 0
    foreach ($s in $stats) {
        if ($s.Ok) { continue }
        if ($unreachable -eq 0) {
            Write-MLine ''
            Write-MLine '  以下节点的信息取不到:' Red
        }
        $unreachable++
        Write-MLine ('  × ' + $s.Node + ': ' + $s.Error) Red
    }

    Write-MLine ''
    Write-MLine '  红色 = 有异常：连不上、主从断开、持久化出错、内存占用超过 90%' DarkGray
    Write-MLine '  命中率 = 两次刷新之间的增量    过期键 / 驱逐键 = 自启动以来的累计数' DarkGray

    return $next
}

function Test-KeyPending {
    try { return [bool]$Host.UI.RawUI.KeyAvailable } catch { return $false }
}

function Invoke-Overview {
    Clear-Screen
    Show-Header
    Write-Host ''
    if ($script:RedisMode -eq 'standalone') { Write-C '  单机概览' Yellow }
    else { Write-C '  集群概览' Yellow }
    $interval = 2
    $text = Read-Line '  刷新间隔秒数 (回车 = 2，输入 0 只看一次): '
    if ($null -eq $text) { return }
    if ($text.Trim()) {
        $n = 0
        if ([int]::TryParse($text.Trim(), [ref]$n) -and $n -ge 0) { $interval = $n }
    }
    $maxCount = 0
    if ($interval -gt 0) {
        $text = Read-Line '  刷新次数 (回车 = 一直刷新，按任意键停止): '
        if ($null -eq $text) { return }
        if ($text.Trim()) {
            $n = 0
            if ([int]::TryParse($text.Trim(), [ref]$n) -and $n -gt 0) { $maxCount = $n }
        }
    }

    Clear-Screen
    Show-Header
    $hasOrigin = $false
    $originX = 0
    $originY = 0
    try {
        $origin = $Host.UI.RawUI.CursorPosition
        $originX = $origin.X
        $originY = $origin.Y
        $hasOrigin = $true
    } catch { }

    $previous = @{}
    $maxLines = 0
    $done = 0
    $stopped = $false
    while ($true) {
        if ($hasOrigin) {
            try { $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($originX, $originY) }
            catch { $hasOrigin = $false }
        }
        $script:LineCount = 0
        try { $previous = Show-MonitorSnapshot $previous }
        catch {
            Write-MLine ''
            Write-MLine ('  × ' + $_.Exception.Message) Red
        }
        if ($interval -gt 0) { Write-MLine '  刷新中，按任意键停止 ...' DarkGray }
        $maxLines = [Math]::Max($maxLines, $script:LineCount)
        # 用空行盖掉上一轮多出来的内容，光标回到最底下
        for ($i = $script:LineCount; $i -lt $maxLines; $i++) { Write-Host '' }

        $done++
        if ($interval -le 0 -or ($maxCount -gt 0 -and $done -ge $maxCount)) { break }

        $deadline = (Get-Date).AddSeconds($interval)
        while ((Get-Date) -lt $deadline) {
            if (Test-KeyPending) { $stopped = $true; break }
            Start-Sleep -Milliseconds 150
        }
        if ($stopped) {
            try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
            break
        }
    }

    Write-Host ''
    if ($stopped) { Write-C '  已停止刷新' Gray }
    Pause-Script
}

# ============ 监控子菜单、慢查询日志、命令与错误统计 ============
# 监控页面用的节点列表，主节点在前。每个元素是 @{ Addr; IsMaster }
function Get-MonitorNodeList {
    $all = Get-ClusterNodes
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($node in $all) {
        if ($node.IsMaster) { $result.Add(@{ Addr = $node.Addr; IsMaster = $true }) }
    }
    foreach ($node in $all) {
        if (-not $node.IsMaster) { $result.Add(@{ Addr = $node.Addr; IsMaster = $false }) }
    }
    return ,$result
}

function Invoke-Monitor {
    $message = ''
    while ($true) {
        $width = Get-ConsoleWidth
        Clear-Screen
        Show-Header $width
        Write-Host ''
        Write-C '  Redis 监控' Cyan
        $overview = '集群概览'
        if ($script:RedisMode -eq 'standalone') { $overview = '单机概览' }
        Write-MenuItem $width 1 $overview '内存、连接、吞吐和主从状态'
        Write-MenuItem $width 2 '慢查询日志' '按时间查看各节点的慢命令'
        Write-MenuItem $width 3 '命令与错误统计' '命令次数、耗时和错误'
        Write-MenuItem $width 4 '大 Key 排行' '按节点和前缀采样内存占用'
        Write-Host ''
        Write-MenuItem $width 0 '返回'
        Write-Host ''
        if ($message) { Write-C ('  ' + $message) Yellow }
        $message = ''
        $choice = Read-Line '  选择 [0–4] > '
        if ($null -eq $choice) { return }
        $choice = $choice.Trim()
        if ($choice -eq '1') { Invoke-Overview }
        elseif ($choice -eq '2') { Show-SlowLog }
        elseif ($choice -eq '3') { Show-CommandStats }
        elseif ($choice -eq '4') { Invoke-BigKeys }
        elseif ($choice -eq '0') { return }
        else { $message = '请输入 0 到 4。' }
    }
}

# ============ 大 Key 排行 ============
function ConvertTo-PrefixPattern([string]$Prefix) {
    return ($Prefix.Replace('\', '\\').Replace('*', '\*').Replace('?', '\?').Replace('[', '\[').Replace(']', '\]') + '*')
}

function Measure-BigKeys([string[]]$Nodes, [string]$Pattern, [int]$SampleLimit, [int]$RoundLimit) {
    $coverage = @(
        foreach ($node in $Nodes) {
            @{ Node = $node; Samples = 0; Measured = 0; Rounds = 0; Status = '未开始' }
        }
    )
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($nodeIndex = 0; $nodeIndex -lt $coverage.Count; $nodeIndex++) {
        if (-not (Test-SearchActive)) { break }
        $stats = $coverage[$nodeIndex]
        $node = $stats.Node
        $cursor = '0'
        Write-C ('  采样 {0} / {1} · {2}' -f ($nodeIndex + 1), $Nodes.Count, $node) Gray
        while (Test-SearchActive) {
            $stats.Rounds++
            try {
                $scan = Invoke-Redis -Node $node -Command 'SCAN' -Arguments @($cursor, 'MATCH', $Pattern, 'COUNT', '200')
                $cursor = [string]$scan[0]
                if ($cursor -notmatch '^[0-9]+$') { throw 'SCAN 返回了无效游标' }
            }
            catch {
                $stats.Status = '扫描失败'
                break
            }
            $pending = New-Object 'System.Collections.Generic.List[string]'
            $overflow = $false
            foreach ($entry in $scan[1]) {
                $key = [string]$entry
                if ($seen.Contains($key)) { continue }
                if ($stats.Samples -ge $SampleLimit) { $overflow = $true; break }
                [void]$seen.Add($key)
                $stats.Samples++
                $pending.Add($key)
            }
            for ($offset = 0; $offset -lt $pending.Count -and (Test-SearchActive); $offset += 64) {
                $length = [Math]::Min(64, $pending.Count - $offset)
                $commands = New-Object 'System.Collections.Generic.List[object]'
                for ($i = 0; $i -lt $length; $i++) {
                    $commands.Add(@('MEMORY', 'USAGE', $pending[$offset + $i], 'SAMPLES', '5'))
                }
                # 只接受该节点的测量结果，槽迁移期间的重定向算未测量。
                try { $sizes = Invoke-Pipeline -Node $node -Commands $commands.ToArray() }
                catch { continue }
                for ($i = 0; $i -lt $length; $i++) {
                    $bytes = 0L
                    if ($null -eq $sizes[$i] -or -not [long]::TryParse([string]$sizes[$i], [ref]$bytes) -or $bytes -lt 0) { continue }
                    $stats.Measured++
                    $rows.Add([pscustomobject]@{
                            Key   = $pending[$offset + $i]
                            Node  = $node
                            Bytes = $bytes
                            Order = $rows.Count
                        })
                }
            }
            if ($script:SearchBudget.Reason) { break }
            if ($cursor -eq '0' -and -not $overflow) { $stats.Status = '已遍历'; break }
            if ($stats.Samples -ge $SampleLimit) { $stats.Status = '样本上限'; break }
            if ($stats.Rounds -ge $RoundLimit) { $stats.Status = '轮次上限'; break }
        }
        if ($script:SearchBudget.Reason) { $stats.Status = '已中止'; break }
    }
    return @{ Rows = $rows; Coverage = $coverage; Stop = $script:SearchBudget.Reason }
}

function Read-RankNumber([string]$Prompt, [int]$Default, [int]$Maximum) {
    while ($true) {
        $inputText = Read-Line $Prompt
        if ($null -eq $inputText) { return $null }
        $text = $inputText.Trim()
        if (-not $text) { return $Default }
        if ($text -eq 'q') { return $null }
        $value = 0
        if ($text -match '^[0-9]{1,5}$' -and [int]::TryParse($text, [ref]$value) -and
            $value -le $Maximum -and ($Default -eq 0 -or $value -gt 0)) {
            return $value
        }
        Write-C '  请输入有效序号或数字，q 返回。' Yellow
    }
}

function Write-RankRow([string]$Number, [string]$Memory, [string]$Node, [string]$Key,
    [int]$NodeWidth, [int]$Width, [switch]$Header) {
    $line = (Format-Cell $Number 3 -Right) + '  ' + (Format-Cell $Memory 10 -Right) + '  '
    $keyWidth = $Width - 20
    if ($NodeWidth -gt 0) {
        $line += (Format-Cell $Node $NodeWidth) + '  '
        $keyWidth -= $NodeWidth + 2
    }
    $line += Format-Cell $Key $keyWidth
    Write-C '  ' -NoNewline
    if ($Header) { Write-C $line White -BackgroundColor DarkGray }
    else { Write-C $line White }
}

function Show-BigKeyResults($Result, [string]$Prefix, [int]$Top, [int]$SampleLimit,
    [int]$RoundLimit, [int]$Seconds) {
    $ranked = @($Result.Rows.ToArray() | Sort-Object -Property @{Expression = 'Bytes'; Descending = $true}, 'Order' | Select-Object -First $Top)
    $sampled = 0
    $failed = 0
    foreach ($stat in $Result.Coverage) {
        $sampled += $stat.Samples
        if ($stat.Status -eq '扫描失败') { $failed++ }
    }
    $prefixLabel = $Prefix
    if (-not $prefixLabel) { $prefixLabel = '全部 Key' }
    $page = 0
    $scope = $false
    while ($true) {
        $width = Get-ConsoleWidth
        $pageSize = Get-PageSize $false
        $nodeWidth = 0
        if ($width -ge 64) { $nodeWidth = 21 }
        $total = $ranked.Count
        if ($scope) {
            $total = $Result.Coverage.Count
            $pageSize = [int][Math]::Ceiling($pageSize / 2.0)
        }
        $pages = [Math]::Max(1, [Math]::Ceiling($total / [double]$pageSize))
        $page = [Math]::Min($page, $pages - 1)
        $end = [Math]::Min(($page + 1) * $pageSize, $total)
        Clear-Screen
        Show-Header $width
        Write-Host ''
        Write-C ('  大 Key 排行 · Top ' + $Top) Cyan
        Write-Fit ('  前缀  ' + $prefixLabel) White ($width - 1)
        if ($Result.Coverage.Count -eq 1) {
            Write-Fit ('  节点  ' + $Result.Coverage[0].Node) White ($width - 1)
        }
        Write-C ('  主节点 {0} · 采样 {1} · 已测量 {2}' -f $Result.Coverage.Count, $sampled, $Result.Rows.Count) Gray
        Write-Fit ('  每节点最多 {0} 个 / {1} 轮 · {2} 秒' -f $SampleLimit, $RoundLimit, $Seconds) Gray ($width - 1)
        if ($failed -gt 0) { Write-C ('  节点扫描失败 {0} 个 [s]' -f $failed) Yellow }
        if ($Result.Stop) { Write-C ('  部分结果 · ' + $Result.Stop) Yellow }
        Write-Host ''
        if ($scope) {
            Write-C '  采样范围 · 各主节点' Cyan
            Write-Fit '  SCAN 游标从 0 开始，按返回顺序取样' Gray ($width - 1)
            for ($i = $page * $pageSize; $i -lt $end; $i++) {
                $stat = $Result.Coverage[$i]
                Write-Fit ('  {0} · {1}' -f $stat.Node, $stat.Status) White ($width - 1)
                Write-Fit ('    采样 {0} · 已测量 {1} · SCAN {2} 轮' -f $stat.Samples, $stat.Measured, $stat.Rounds) Gray ($width - 1)
            }
        }
        elseif ($total -eq 0) {
            Write-C '  本次采样暂无可排行的 Key。' Gray
        }
        else {
            Write-RankRow '#' 内存 节点 Key $nodeWidth $width -Header
            for ($i = $page * $pageSize; $i -lt $end; $i++) {
                $entry = $ranked[$i]
                $name = Convert-ToSafeText $entry.Key
                if (-not $name) { $name = '(空 Key)' }
                Write-RankRow ($i + 1) (Format-Size $entry.Bytes) $entry.Node $name $nodeWidth $width
            }
        }
        Write-Rule $width
        Write-HintLine ('第 {0} / {1} 页' -f ($page + 1), $pages) '' '<' 上页 '>' 下页
        if ($scope) { Write-HintLine s 返回排行 q 返回 }
        else { Write-HintLine s 采样范围 序号 完整Key q 返回 }
        $command = Read-Line '  命令 > '
        if ($null -eq $command) { return }
        $command = $command.Trim()
        switch ($command) {
            'q' { return }
            's' { $scope = -not $scope; $page = 0 }
            '<' { if ($page -gt 0) { $page-- } }
            '>' { if ($page + 1 -lt $pages) { $page++ } }
            default {
                if (-not $scope -and $command -match '^[0-9]{1,2}$' -and [int]$command -ge 1 -and [int]$command -le $total) {
                    $entry = $ranked[[int]$command - 1]
                    Write-C ('  Key  ' + (Convert-ToSafeText $entry.Key)) White
                    Write-C ('  {0} · {1} B' -f $entry.Node, $entry.Bytes) Gray
                    Pause-Script
                }
            }
        }
    }
}

function Invoke-BigKeys {
    $width = Get-ConsoleWidth
    $seconds = Get-SearchSetting $env:REDIS_TUI_SEARCH_SECONDS 15 120
    $roundLimit = 50
    Clear-Screen
    Show-Header $width
    Write-Host ''
    Write-C '  大 Key 排行' Cyan
    try {
        $nodes = @(Invoke-WithSearchBudget $seconds { (Get-MasterNodes).ToArray() } | Sort-Object -Unique)
        if ($nodes.Count -eq 0) { throw 'CLUSTER NODES 没有返回主节点' }
    }
    catch {
        Write-C '  无法读取集群主节点。' Red
        Pause-Script
        return
    }
    Write-C '  0) 全部主节点' Gray
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        Write-Fit ('  {0}) {1}' -f ($i + 1), $nodes[$i]) Gray ($width - 1)
    }
    $selected = Read-RankNumber '  节点 [默认 0，q 返回] > ' 0 $nodes.Count
    if ($null -eq $selected) { return }
    if ($selected -gt 0) { $nodes = @($nodes[$selected - 1]) }
    $prefix = Read-Line '  Key 前缀 [回车 = 全部] > '
    if ($null -eq $prefix) { return }
    $pattern = ConvertTo-PrefixPattern $prefix
    $sampleLimit = Read-RankNumber '  每节点样本数 [1–500，默认 100] > ' 100 500
    if ($null -eq $sampleLimit) { return }
    $top = Read-RankNumber '  Top N [1–50，默认 10] > ' 10 50
    if ($null -eq $top) { return }
    if (-not [Console]::IsInputRedirected) { Write-C '  按 q 停止采样' Gray }
    $result = Invoke-WithSearchBudget $seconds { Measure-BigKeys $nodes $pattern $sampleLimit $roundLimit }
    Show-BigKeyResults $result $prefix $top $sampleLimit $roundLimit $seconds
}

# 文本里夹着的控制字符换成 ?（慢查询日志的参数里可能有），免得把屏幕搅乱
function Convert-ToSafeText($Value) {
    if ($null -eq $Value) { return '' }
    return ([regex]::Replace([string]$Value, '[\x00-\x1F\x7F]', '?'))
}

# 慢查询日志：每个节点各自记录的、执行超过阈值的命令（存在内存里，节点重启就没有了）
function Show-SlowLog {
    Clear-Screen
    Show-Header
    Write-Host ''
    Write-C '  慢查询日志' Cyan
    $text = Read-Line '  每个节点显示最近多少条 (回车 = 20): '
    if ($null -eq $text) { return }
    $count = 20
    $n = 0
    if ($text.Trim() -and [int]::TryParse($text.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 128) { $count = $n }

    Write-C '  正在读取...' DarkGray
    $nodes = $null
    try { $nodes = Get-MonitorNodeList } catch { Show-Error $_; Pause-Script; return }

    $threshold = ''
    $maxLen = ''
    $lengths = New-Object 'System.Collections.Generic.List[string]'
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $addrWidth = 15
    foreach ($node in $nodes) {
        try {
            $len = [long](Invoke-Redis -Node $node.Addr -Command 'SLOWLOG' -Arguments @('LEN'))
            $lengths.Add(($node.Addr.Split(':')[-1]) + ': ' + (Format-Count $len))
            if ($threshold -eq '') {
                # 阈值和保留条数是配置项；取不到（比如 CONFIG 被禁用）就标成 ? ，不再重复试
                $threshold = '?'
                try {
                    $cfg = Invoke-Redis -Node $node.Addr -Command 'CONFIG' -Arguments @('GET', 'slowlog-log-slower-than', 'slowlog-max-len')
                    # 回复是"名字、值"交替的一维数组，但顺序不一定和请求的一致，要按名字找
                    if ($null -ne $cfg) {
                        for ($i = 0; $i + 1 -lt $cfg.Count; $i += 2) {
                            if ([string]$cfg[$i] -eq 'slowlog-log-slower-than') { $threshold = [string]$cfg[$i + 1] }
                            elseif ([string]$cfg[$i] -eq 'slowlog-max-len') { $maxLen = [string]$cfg[$i + 1] }
                        }
                    }
                } catch { }
            }
            $entries = Invoke-Redis -Node $node.Addr -Command 'SLOWLOG' -Arguments @('GET', [string]$count)
            if ($null -ne $entries) {
                foreach ($entry in $entries) {
                    if ($null -eq $entry -or $entry.Count -lt 5) { continue }
                    $parts = @()
                    if ($null -ne $entry[3]) { $parts = @($entry[3]) }
                    $command = ''
                    if ($parts.Count -gt 0) { $command = ([string]$parts[0]).ToUpper() }
                    $argText = ''
                    if ($parts.Count -gt 1) { $argText = (($parts[1..($parts.Count - 1)]) -join ' ') }
                    if ($node.Addr.Length -gt $addrWidth) { $addrWidth = $node.Addr.Length }
                    $rows.Add([pscustomobject]@{
                            Ts      = [long]$entry[1]
                            Usecs   = [long]$entry[2]
                            Node    = $node.Addr
                            Command = (Convert-ToSafeText $command)
                            Args    = (Convert-ToSafeText $argText)
                            Client  = (Convert-ToSafeText $entry[4])
                        })
                }
            }
        } catch {
            $problems.Add($node.Addr + ': ' + $_.Exception.Message)
        }
    }

    Clear-Screen
    Show-Header
    Write-Host ''
    Write-C '  慢查询日志' Cyan
    Write-C ('  每个节点最近 ' + $count + ' 条，共 ' + $rows.Count + ' 条，新的在前') Gray

    $cfgText = '记录阈值: 未知（CONFIG GET 不可用）'
    if ($threshold -ne '' -and $threshold -ne '?') {
        if ($threshold -eq '-1') { $cfgText = '当前不记录（阈值为 -1）' }
        elseif ($threshold -eq '0') { $cfgText = '记录所有命令（阈值为 0）' }
        else { $cfgText = '记录执行超过 ' + ([double]$threshold / 1000.0) + ' 毫秒的命令' }
        if ($maxLen -ne '') { $cfgText = $cfgText + '，每个节点最多保留 ' + $maxLen + ' 条' }
    }
    Write-C ('  ' + $cfgText) Gray
    if ($lengths.Count -gt 0) { Write-C ('  各节点现有记录:  ' + ($lengths -join '    ')) Gray }
    foreach ($problem in $problems) { Write-C ('  × 取不到 ' + $problem) Red }

    if ($rows.Count -eq 0) {
        Write-Host ''
        Write-C '  没有慢查询记录' Gray
    }
    else {
        $width = Get-ConsoleWidth
        # 列：时间 14 + 耗时 9 + 节点 + 命令 10 + 来源 21 + 参数（占剩下的宽度）；窗口窄时先去掉"来源"
        $showClient = $true
        $argsWidth = $width - 1 - (2 + 14 + 2 + 9 + 2 + $addrWidth + 2 + 10 + 2 + 21 + 2)
        if ($argsWidth -lt 12) {
            $showClient = $false
            $argsWidth = $width - 1 - (2 + 14 + 2 + 9 + 2 + $addrWidth + 2 + 10 + 2)
        }
        if ($argsWidth -lt 12) { $argsWidth = 12 }

        Write-Rule $width
        $header = '  ' + (Format-Cell '时间' 14) + '  ' + (Format-Cell '耗时' 9 -Right) + '  ' + (Format-Cell '节点' $addrWidth) + '  ' + (Format-Cell '命令' 10) + '  ' + (Format-Cell '参数' $argsWidth)
        if ($showClient) { $header = $header + '  ' + (Format-Cell '来源客户端' 21 -Right) }
        Write-C $header DarkCyan
        foreach ($row in ($rows.ToArray() | Sort-Object -Property Ts -Descending)) {
            $time = [DateTimeOffset]::FromUnixTimeSeconds($row.Ts).LocalDateTime.ToString('MM-dd HH:mm:ss')
            $durText = '{0:0.0} ms' -f ($row.Usecs / 1000.0)
            if ($row.Usecs -ge 1000000) { $durText = '{0:0.00} s' -f ($row.Usecs / 1000000.0) }
            $durColor = 'Gray'
            if ($row.Usecs -ge 30000) { $durColor = 'Yellow' }
            if ($row.Usecs -ge 100000) { $durColor = 'Red' }
            Write-C '  ' -NoNewline
            Write-C (Format-Cell $time 14) Gray -NoNewline
            Write-C '  ' -NoNewline
            Write-C (Format-Cell $durText 9 -Right) $durColor -NoNewline
            Write-C '  ' -NoNewline
            Write-C (Format-Cell $row.Node $addrWidth) White -NoNewline
            Write-C '  ' -NoNewline
            Write-C (Format-Cell $row.Command 10) Cyan -NoNewline
            Write-C '  ' -NoNewline
            Write-C (Format-Cell $row.Args $argsWidth) Gray -NoNewline
            if ($showClient) {
                Write-C '  ' -NoNewline
                Write-C (Format-Cell $row.Client 21 -Right) DarkGray
            }
            else { Write-Host '' }
        }
        Write-Rule $width
        Write-C '  耗时: 黄色 ≥ 30 毫秒，红色 ≥ 100 毫秒' DarkGray
        Write-C '  阻塞类命令（如 XREAD … BLOCK）等待数据的时间也算在耗时里' DarkGray
    }
    Write-Host ''
    Pause-Script
}

# 把 "calls=1,usec=2,..." 这样的值解析成哈希表
function ConvertFrom-InfoPairs([string]$Value) {
    $pairs = @{}
    if ($null -eq $Value) { return $pairs }
    foreach ($part in ($Value -split ',')) {
        $i = $part.IndexOf('=')
        if ($i -gt 0) { $pairs[$part.Substring(0, $i)] = $part.Substring($i + 1) }
    }
    return $pairs
}

function Get-ErrorDescription([string]$Name) {
    $descriptions = @{
        'WRONGPASS' = '密码错误'
        'NOAUTH' = '没有认证'
        'NOPERM' = '没有权限'
        'CLUSTERDOWN' = '集群不可用'
        'MOVED' = '请求发到了错误的节点'
        'ASK' = '要求跳转到其它节点'
        'TRYAGAIN' = '集群迁移中，需要重试'
        'CROSSSLOT' = 'Key 不在同一个槽'
        'READONLY' = '从节点只读'
        'MASTERDOWN' = '主节点不可用'
        'NOSCRIPT' = '脚本还没加载'
        'BUSY' = '脚本正在执行'
        'BUSYKEY' = '目标 Key 已存在'
        'LOADING' = '节点正在加载数据'
        'OOM' = '内存不足'
        'EXECABORT' = '事务被中止'
        'WRONGTYPE' = 'Key 类型不匹配'
        'NOREPLICAS' = '从节点数量不足'
        'ERR' = '其它错误'
    }
    if ($descriptions.ContainsKey($Name)) { return $descriptions[$Name] }
    return ''
}

# 两次取样之间某类报错新增的次数。第二次样本没取到时返回 $null
function Get-ErrorDelta($Item, [string]$Name) {
    if (-not $Item.Ok2) { return $null }
    $before = 0
    $after = 0
    if ($Item.Errors.ContainsKey($Name)) { $before = [long]$Item.Errors[$Name] }
    if ($Item.Errors2.ContainsKey($Name)) { $after = [long]$Item.Errors2[$Name] }
    return ($after - $before)
}

# 命令与错误统计：INFO 里的累计数，自各节点启动以来
function Show-CommandStats {
    Clear-Screen
    Show-Header
    Write-Host ''
    Write-C '  命令与错误统计' Cyan
    Write-C '  自各节点启动以来的累计数' Gray
    Write-C '  正在读取...' DarkGray
    $nodes = $null
    try { $nodes = Get-MonitorNodeList } catch { Show-Error $_; Pause-Script; return }

    # 所有节点在同一台机器上时，列标题只写端口和角色（如 2320主），节省宽度
    $sameHost = $true
    $firstHost = ''
    foreach ($node in $nodes) {
        $hostName = $node.Addr.Substring(0, $node.Addr.LastIndexOf(':'))
        if ($firstHost -eq '') { $firstHost = $hostName } elseif ($hostName -ne $firstHost) { $sameHost = $false }
    }

    $items = New-Object 'System.Collections.Generic.List[object]'
    $errorNames = @{}
    $errorTotals = @{}
    $cmdCalls = @{}
    $cmdUsec = @{}
    $cmdFailed = @{}
    $cmdRejected = @{}
    $addrWidth = 15
    foreach ($node in $nodes) {
        $roleText = '从'
        if ($node.IsMaster) { $roleText = '主' }
        $label = $node.Addr
        if ($sameHost) { $label = $node.Addr.Split(':')[-1] + $roleText }
        if ($node.Addr.Length -gt $addrWidth) { $addrWidth = $node.Addr.Length }
        $item = [pscustomobject]@{
            Node = $node.Addr; Label = $label; RoleText = $roleText; Ok = $false; Reason = ''
            Uptime = $null; Commands = $null; Connections = $null; ErrorReplies = $null; Errors = @{}
            Ok2 = $false; ErrorReplies2 = $null; Errors2 = @{}
        }
        try {
            $map = Get-InfoMap $node.Addr
            $item.Ok = $true
            $item.Uptime = Get-InfoNum $map 'uptime_in_seconds'
            $item.Commands = Get-InfoNum $map 'total_commands_processed'
            $item.Connections = Get-InfoNum $map 'total_connections_received'
            $item.ErrorReplies = Get-InfoNum $map 'total_error_replies'
            foreach ($key in @($map.Keys)) {
                $value = [string]$map[$key]
                if ($key.StartsWith('errorstat_')) {
                    $name = $key.Substring(10)
                    $count = 0
                    if ($value -match 'count=(\d+)') { $count = [long]$Matches[1] }
                    $item.Errors[$name] = $count
                    $errorNames[$name] = $true
                    $errorTotals[$name] = [long]$errorTotals[$name] + $count
                }
            }
            # INFO 不带参数时不包含"命令统计"这一段，要单独取。只合计主节点的（从节点上的主要是复制和心跳）
            if ($node.IsMaster) {
                $cmdText = [string](Invoke-Redis -Node $node.Addr -Command 'INFO' -Arguments @('commandstats'))
                foreach ($line in ($cmdText -split "`n")) {
                    $line = $line.Trim()
                    if (-not $line.StartsWith('cmdstat_')) { continue }
                    $i = $line.IndexOf(':')
                    if ($i -lt 1) { continue }
                    $name = $line.Substring(8, $i - 8)
                    $pairs = ConvertFrom-InfoPairs ($line.Substring($i + 1))
                    $cmdCalls[$name] = [long]$cmdCalls[$name] + [long]$pairs['calls']
                    $cmdUsec[$name] = [long]$cmdUsec[$name] + [long]$pairs['usec']
                    $cmdFailed[$name] = [long]$cmdFailed[$name] + [long]$pairs['failed_calls']
                    $cmdRejected[$name] = [long]$cmdRejected[$name] + [long]$pairs['rejected_calls']
                }
            }
        } catch {
            $item.Reason = $_.Exception.Message
        }
        $items.Add($item)
    }

    # 第二次取样：隔 10 秒再读一遍报错计数，两次之差就是这 10 秒里新发生的
    Write-C '  等 10 秒后取第二次样本...' DarkGray
    Start-Sleep -Seconds 10
    foreach ($item in $items) {
        if (-not $item.Ok) { continue }
        try {
            $map2 = Get-InfoMap $item.Node
            $item.ErrorReplies2 = Get-InfoNum $map2 'total_error_replies'
            foreach ($key in @($map2.Keys)) {
                if ($key.StartsWith('errorstat_')) {
                    $name = $key.Substring(10)
                    $count = 0
                    if ([string]$map2[$key] -match 'count=(\d+)') { $count = [long]$Matches[1] }
                    $item.Errors2[$name] = $count
                }
            }
            $item.Ok2 = $true
        } catch { }
    }

    Clear-Screen
    Show-Header
    Write-Host ''
    Write-C '  命令与错误统计' Cyan
    Write-C '  自各节点启动以来的累计数' Gray
    $width = Get-ConsoleWidth

    # ---- 表 1：各节点总量 ----
    $display = @(@('节点', $addrWidth), @('角色', 4), @('运行时间', 11), @('累计命令', 16), @('累计连接', 12), @('错误回复', 12), @('近10秒新增', 12))
    # 窗口窄时按这个先后保留列："近10秒新增"是判断健康最关键的，排在累计数前面
    $priority = @('节点', '角色', '近10秒新增', '错误回复', '运行时间', '累计命令', '累计连接')
    $selection = Select-Columns $display $priority ($width - 3)
    $columns = $selection[0]
    $widths = $selection[1]
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $items) {
        # 值按列名存放，最后只按选中的列、按列的顺序取（中间的列被省略时数值不能错位）
        $values = @{ '节点' = $item.Node; '角色' = $item.RoleText }
        $color = 'White'
        if ($item.Ok) {
            $values['运行时间'] = (Format-Uptime $item.Uptime)
            $values['累计命令'] = (Format-Count $item.Commands)
            $values['累计连接'] = (Format-Count $item.Connections)
            # 累计数显示第二次样本（更新），和"近10秒新增"正好对得上
            if ($item.Ok2 -and $null -ne $item.ErrorReplies2) { $values['错误回复'] = (Format-Count $item.ErrorReplies2) }
            else { $values['错误回复'] = (Format-Count $item.ErrorReplies) }
            # 这 10 秒里新增的错误回复数（两次取样之差）
            $deltaText = '?'
            if ($item.Ok2 -and $null -ne $item.ErrorReplies2 -and $null -ne $item.ErrorReplies) {
                $d = [long]$item.ErrorReplies2 - [long]$item.ErrorReplies
                $deltaText = '-'
                if ($d -gt 0) { $deltaText = '+' + $d; $color = 'Yellow' } elseif ($d -lt 0) { $deltaText = [string]$d; $color = 'Yellow' }
            }
            $values['近10秒新增'] = $deltaText
        }
        else {
            $color = 'Red'
            $values['运行时间'] = '× 取不到'
            $values['累计命令'] = '—'
            $values['累计连接'] = '—'
            $values['错误回复'] = '—'
            $values['近10秒新增'] = '—'
        }
        $cells = New-Object 'System.Collections.Generic.List[string]'
        foreach ($column in $columns) { $cells.Add([string]$values[$column]) }
        $rows.Add(@{ Cells = $cells.ToArray(); Color = $color })
    }
    Write-MTable '各节点总量' $columns $widths $rows

    # ---- 表 2：各类报错的次数，每个节点一列，按合计从多到少排 ----
    $errorList = @($errorNames.Keys | ForEach-Object { [string]$_ })
    $sortedErrors = @()
    if ($errorList.Count -gt 0) {
        $sortedErrors = @($errorList | Sort-Object { [long]$errorTotals[$_] } -Descending)
    }
    if ($sortedErrors.Count -gt 0) {
        $nodeColWidth = @{}
        foreach ($item in $items) {
            $w = (Get-TextWidth $item.Label)
            if ($w -lt 5) { $w = 5 }
            if ($item.Ok) {
                foreach ($name in $sortedErrors) {
                    if ($item.Errors.ContainsKey($name)) {
                        $text = Format-Count $item.Errors[$name]
                        if ($text.Length -gt $w) { $w = $text.Length }
                    }
                }
            }
            $nodeColWidth[$item.Node] = $w
        }
        # 放不下时先去掉"说明"列
        $total = 2 + 16 + 2 + 12
        foreach ($item in $items) { $total += 2 + $nodeColWidth[$item.Node] }
        $showDesc = $false
        # $total 已经含行首的两格缩进，所以只和"窗口宽度减 1"比
        if ($total + 2 + 22 -le ($width - 1)) { $showDesc = $true }

        $deltaLines = New-Object 'System.Collections.Generic.List[string]'
        $deltaKnown = $false
        foreach ($item in $items) { if ($item.Ok2) { $deltaKnown = $true } }
        $deltaSeen = $false

        Write-Host ''
        Write-C '  各类报错的次数' Cyan
        $header = '  ' + (Format-Cell '报错' 16)
        if ($showDesc) { $header = $header + '  ' + (Format-Cell '说明' 22) }
        $header = $header + '  ' + (Format-Cell '近10秒新增' 12 -Right)
        foreach ($item in $items) { $header = $header + '  ' + (Format-Cell $item.Label $nodeColWidth[$item.Node] -Right) }
        Write-C $header Cyan
        foreach ($name in $sortedErrors) {
            # 近 10 秒新增：每个节点两次取样之差，再合计；有变化的节点记下来
            $delta = 0L
            $unknown = $false
            $parts = @()
            foreach ($item in $items) {
                $d = Get-ErrorDelta $item $name
                if ($null -eq $d) { $unknown = $true; continue }
                $delta += $d
                if ($d -gt 0) { $parts += ($item.Label + ' +' + $d) } elseif ($d -lt 0) { $parts += ($item.Label + ' ' + $d) }
            }
            $deltaCell = '-'
            $deltaColor = 'DarkGray'
            if ($delta -gt 0) { $deltaCell = '+' + $delta; $deltaColor = 'Yellow' }
            elseif ($delta -lt 0) { $deltaCell = [string]$delta; $deltaColor = 'Yellow' }
            elseif ($unknown) { $deltaCell = '?' }

            Write-C ('  ' + (Format-Cell $name 16)) White -NoNewline
            if ($showDesc) { Write-C ('  ' + (Format-Cell (Get-ErrorDescription $name) 22)) DarkGray -NoNewline }
            Write-C ('  ' + (Format-Cell $deltaCell 12 -Right)) $deltaColor -NoNewline
            foreach ($item in $items) {
                $cell = '—'
                $cellColor = 'DarkGray'
                if ($item.Ok) {
                    $cell = '-'
                    # 累计数显示第二次样本（更新），和"近10秒新增"正好对得上
                    if ($item.Ok2 -and $item.Errors2.ContainsKey($name)) { $cell = Format-Count $item.Errors2[$name]; $cellColor = 'White' }
                    elseif ($item.Errors.ContainsKey($name)) { $cell = Format-Count $item.Errors[$name]; $cellColor = 'White' }
                }
                Write-C ('  ' + (Format-Cell $cell $nodeColWidth[$item.Node] -Right)) $cellColor -NoNewline
            }
            Write-Host ''
            if ($parts.Count -gt 0) {
                $deltaSeen = $true
                $deltaLines.Add($name + ' 近 10 秒新增 ' + $delta + ':  ' + ($parts -join '    '))
            }
        }
        # 有新增的报错列出来是哪些节点；一个都没有就说明表里的数字都是历史
        foreach ($line in $deltaLines) { Write-C ('  ' + $line) Yellow }
        if (-not $deltaSeen -and $deltaKnown) {
            Write-C '  近 10 秒内所有节点的报错计数都没有变化，表里的数字都是历史累计' Gray
        }
    }

    # ---- 表 3：主节点合计的命令，按次数从多到少排 ----
    $cmdList = @($cmdCalls.Keys | ForEach-Object { [string]$_ })
    $sortedCmds = @()
    if ($cmdList.Count -gt 0) {
        $sortedCmds = @($cmdList | Sort-Object { [long]$cmdCalls[$_] } -Descending)
    }
    if ($sortedCmds.Count -gt 0) {
        $display = @(@('命令', 18), @('次数', 18), @('平均耗时', 12), @('失败', 14), @('被拒绝', 14))
        $priority = @('命令', '次数', '平均耗时', '失败', '被拒绝')
        $selection = Select-Columns $display $priority ($width - 3)
        $columns = $selection[0]
        $widths = $selection[1]
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $shown = 0
        foreach ($name in $sortedCmds) {
            $shown++
            if ($shown -gt 20) { break }
            $calls = [long]$cmdCalls[$name]
            $avg = 0.0
            if ($calls -gt 0) { $avg = [double]$cmdUsec[$name] / [double]$calls }
            $avgText = '-'
            if ($calls -gt 0) {
                if ($avg -ge 1000.0) { $avgText = '{0:0.00} 毫秒' -f ($avg / 1000.0) }
                else { $avgText = '{0:0} 微秒' -f $avg }
            }
            $color = 'White'
            if ($avg -ge 1000.0) { $color = 'Yellow' }
            $cells = New-Object 'System.Collections.Generic.List[string]'
            $cells.Add(($name -replace '\|', ' '))
            $cells.Add((Format-Count $calls))
            $cells.Add($avgText)
            $cells.Add((Format-Count $cmdFailed[$name]))
            $cells.Add((Format-Count $cmdRejected[$name]))
            $rows.Add(@{ Cells = $cells.ToArray(); Color = $color })
        }
        Write-MTable '主节点合计的命令（按次数排序，前 20）' $columns $widths $rows
        if ($sortedCmds.Count -gt 20) { Write-C ('  ... 还有 ' + ($sortedCmds.Count - 20) + ' 种命令没有列出') DarkGray }
    }

    $bad = 0
    foreach ($item in $items) {
        if ($item.Ok) { continue }
        if ($bad -eq 0) {
            Write-Host ''
            Write-C '  以下节点的信息取不到:' Red
        }
        $bad++
        Write-C ('  × ' + $item.Node + ': ' + $item.Reason) Red
    }

    Write-Host ''
    Write-C '  近10秒新增: 两次取样（间隔 10 秒）之差，为 - 表示当前没有发生' DarkGray
    Write-C '  平均耗时 = 该命令的总耗时 ÷ 次数' DarkGray
    Write-C '  累计数在节点重启或执行 CONFIG RESETSTAT 后清零' DarkGray
    Pause-Script
}

# ============ 主菜单 ============
function Write-MenuItem([int]$Width, [int]$Shortcut, [string]$Label, [string]$Detail, [switch]$Paired) {
    Write-C '  ' -NoNewline
    Write-C ('[{0}]' -f $Shortcut) Cyan -NoNewline
    Write-C '  ' -NoNewline
    if ($Paired) {
        Write-C (Format-Cell $Label 16) White -NoNewline
        Write-C (Format-Cell ('  ' + $Detail) ($Width - 23)) Gray -NoNewline
    }
    elseif ($Width -ge 64 -and $Detail) {
        Write-C (Format-Cell $Label 16) White -NoNewline
        Write-Fit ('  ' + $Detail) Gray ($Width - 24)
    }
    else { Write-C $Label White }
}

function Invoke-MainMenu {
    $message = ''
    $tools = @('查询单个 Key', '搜索 Key', 'Redis 监控')
    $descriptions = @('类型、过期、大小和值', '关键词、类型和前缀', '健康状态、慢查询与错误')
    $sessionKeys = @(4, 5, 0)
    while ($true) {
        $width = Get-ConsoleWidth
        Clear-Screen
        Show-Header $width
        Write-Host ''
        $writeLabel = '开启写入'
        if ($script:AllowWrites) { $writeLabel = '恢复只读' }
        $sessionItems = @('连接配置', $writeLabel, '退出')
        $paired = $width -ge 90
        $left = $width
        if ($paired) {
            $left = 54
            Write-C (Format-Cell '  浏览和诊断' $left) Cyan -NoNewline
            Write-C '  会话' Cyan
        }
        else { Write-C '  浏览和诊断' Cyan }
        for ($i = 0; $i -lt $tools.Count; $i++) {
            Write-MenuItem $left ($i + 1) $tools[$i] $descriptions[$i] -Paired:$paired
            if ($paired) { Write-MenuItem ($width - $left) $sessionKeys[$i] $sessionItems[$i] }
        }
        if (-not $paired) {
            Write-Host ''
            Write-C '  会话' Cyan
            for ($i = 0; $i -lt $sessionItems.Count; $i++) {
                Write-MenuItem $width $sessionKeys[$i] $sessionItems[$i]
            }
        }
        $last = 5
        if ($script:RedisMode -eq 'standalone') {
            $indent = 0
            if ($paired) { $indent = $left }
            if ($indent) { Write-C (' ' * $indent) -NoNewline }
            Write-MenuItem ($width - $indent) 6 '切换 DB'
            $last = 6
        }
        Write-Host ''
        if ($message) { Write-C ('  ' + $message) Yellow }
        $message = ''
        $choice = Read-Line "  选择 [0–$last] > "
        if ($null -eq $choice) { return }
        $choice = $choice.Trim()

        if ($choice -eq '1') { Invoke-QueryKey }
        elseif ($choice -eq '2') { Invoke-KeyList }
        elseif ($choice -eq '3') { Invoke-Monitor }
        elseif ($choice -eq '4') { $null = Invoke-Login }
        elseif ($choice -eq '5') { Switch-WriteMode }
        elseif ($choice -eq '6') {
            if ($script:RedisMode -eq 'standalone') { Switch-Database }
            else { $message = '集群使用 DB 0。' }
        }
        elseif ($choice -eq '0') {
            Clear-Screen
            Write-C '  再见' Green
            return
        }
        else { $message = "请输入 0 到 $last。" }
    }
}

# ============ 入口 ============
$failed = $false
try {
    if ($Profile) {
        try {
            if ($HostName) { throw '连接名称和主机位置参数须分别使用。' }
            $settings = Read-ConnectionProfile (Get-ProfileFile $Profile)
            $failed = -not (Connect-SavedProfile $settings)
        }
        catch { Show-Error $_; $failed = $true }
    }
    elseif ($HostName) {
        if ($Port -lt 1) { $Port = 7000 }
        try {
            $settings = New-LoginProfile '' $HostName ([string]$Port) '' '0' '' ''
            $failed = -not (Connect-LoginProfile $settings (Convert-ToPlain $Password))
        }
        catch { Show-Error $_; $failed = $true }
    }
    elseif (-not (Invoke-Login)) { $failed = $true }

    if (-not $failed) { Invoke-MainMenu }
}
finally {
    Close-Connections
    # 启动时如果改过控制台编码，改回去
    if ($null -ne $script:OriginalOutputEncoding) {
        try { [Console]::OutputEncoding = $script:OriginalOutputEncoding } catch { }
    }
}

# 用 powershell -File 启动时（例如双击 redis-tui.cmd）用退出码报告失败；
# 在已经打开的 PowerShell 窗口里运行时脚本到此自然结束，不关掉用户的窗口
if ($failed -and ([Environment]::GetCommandLineArgs() -contains '-File')) { exit 1 }
