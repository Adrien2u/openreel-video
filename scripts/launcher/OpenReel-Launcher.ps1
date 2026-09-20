<#
.SYNOPSIS
    OpenReel Dev launcher: start, stop, build and check the local fork.

.DESCRIPTION
    With no action it opens a menu under a live panel: which OpenReel is
    running and for how long, whether the MCP endpoint answers and identifies
    itself as OpenReel, how many tools it serves and which project is open,
    whether this fork's two tools are among them, when the build was made, and
    whether upstream has moved past the tag the patch sits on.

    The app's own stdout and stderr are redirected to logs rather than inherited,
    so Electron chatter cannot land on top of this menu. [L] tails them.

    With an action it runs that action once and exits with its code.

.PARAMETER Action
    menu (default) | start | stop | restart | status | build | upstream | doctor | logs
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'start', 'stop', 'restart', 'status', 'build', 'upstream', 'doctor', 'logs')]
    [string] $Action = 'menu',
    # start only: capture the app's stdout/stderr to %TEMP% instead of detaching.
    [switch] $Logged
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'openreel-lib.ps1')
Initialize-Ansi

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:Exe = Join-Path $script:Root 'apps\desktop\release\win-unpacked\OpenReel Dev.exe'
$script:Official = Join-Path $env:LOCALAPPDATA 'Programs\@openreeldesktop\OpenReel.exe'
$script:Endpoint = Join-Path $HOME '.openreel\mcp-endpoint.json'
$script:OutLog = Join-Path $env:TEMP 'openreel-dev.out.log'
$script:ErrLog = Join-Path $env:TEMP 'openreel-dev.err.log'
$script:PatchBranch = 'feat/mcp-local-import'
$script:DevBranch = 'dev/openreel-dev'

# The two tools this fork exists for. Their absence means a stock build is up.
$script:ForkTools = @('import_media_from_path', 'list_overlays')

# --- state --------------------------------------------------------------------

function Get-App {
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'OpenReel*' -and $_.MainWindowTitle -ne '' })
    foreach ($p in $procs) {
        $path = try { $p.Path } catch { $null }
        if (-not $path) { continue }
        return [pscustomobject]@{
            Id = $p.Id; IsDev = ($path -eq $script:Exe)
            Uptime = (Get-Date) - $p.StartTime
        }
    }
    return $null
}

# The endpoint file names the port and a token that rotates every launch, so it
# is read fresh on each probe rather than cached.
function Get-Mcp {
    if (-not (Test-Path $script:Endpoint)) { return [pscustomobject]@{ State = 'none' } }
    $cfg = Get-Content $script:Endpoint -Raw | ConvertFrom-Json
    $headers = @{ authorization = "Bearer $($cfg.token)" }
    $call = {
        param($id, $method, $params)
        Invoke-RestMethod -Method Post -Uri $cfg.url -TimeoutSec 15 -ContentType 'application/json' -Headers $headers `
            -Body (@{ jsonrpc = '2.0'; id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 8)
    }
    try {
        $hello = & $call 1 'initialize' @{ protocolVersion = '2025-06-18'; capabilities = @{}
            clientInfo = @{ name = 'launcher'; version = '1' } }
    } catch {
        return [pscustomobject]@{ State = 'down'; Port = $cfg.port }
    }
    # Identity before trust: a stale endpoint file can name a port that
    # something else has taken since.
    if ($hello.result.serverInfo.name -ne 'openreel') {
        return [pscustomobject]@{ State = 'other'; Port = $cfg.port; Who = "$($hello.result.serverInfo.name)" }
    }
    $names = @((& $call 2 'tools/list' @{}).result.tools | ForEach-Object { $_.name })
    $project = ''
    try {
        $text = "$((& $call 3 'tools/call' @{ name = 'get_editor_state'; arguments = @{} }).result.content[0].text)"
        if ($text -match '"name":\s*"([^"]+)"') { $project = $Matches[1] }
    } catch { }
    return [pscustomobject]@{
        State = 'up'; Port = $cfg.port; Version = "$($hello.result.serverInfo.version)"
        Tools = $names.Count; Project = $project
        Missing = @($script:ForkTools | Where-Object { $names -notcontains $_ })
    }
}

function Get-Git {
    Push-Location $script:Root
    try {
        $branch = "$(git branch --show-current)".Trim()
        $base = "$(git describe --tags --abbrev=0 "$script:PatchBranch^" 2>$null)".Trim()
        if ($LASTEXITCODE -ne 0) { $base = '' }
        $ahead = ''
        if ($base) {
            $n = "$(git rev-list --count "$base..upstream/main" 2>$null)".Trim()
            if ($LASTEXITCODE -eq 0) { $ahead = $n }
        }
        return [pscustomobject]@{ Branch = $branch; Base = $base; Ahead = $ahead }
    } finally { Pop-Location }
}

# --- panel --------------------------------------------------------------------

function Write-Header {
    $u = $script:Ui
    $art = @(
        '  ___  ____  ',
        ' / _ \|  _ \ ',
        '| | | | |_) |',
        '| |_| |  _ < ',
        ' \___/|_| \_\'
    )
    $side = @(
        '',
        "$($u.Label)OpenReel Dev$($u.R)",
        "$($u.Sub)L A U N C H E R$($u.R)",
        "$($u.Dim)a patched build, beside the official one$($u.R)",
        "$($u.Dim)one OpenReel at a time$($u.R)"
    )
    Write-PanelRule
    for ($i = 0; $i -lt $art.Count; $i++) {
        Write-PanelRow "   $($u.Title)$($art[$i])$($u.R)    $($side[$i])"
    }
    Write-PanelRule
}

function Write-StatusRows {
    $u = $script:Ui

    $app = Get-App
    if ($null -eq $app) { $badge = Format-Badge 'off' 'Off'; $text = "$($u.Dim)not running$($u.R)" }
    elseif ($app.IsDev) { $badge = Format-Badge 'ON' 'On';   $text = "pid $($app.Id)  $($u.Dim)up $(Format-Uptime $app.Uptime)$($u.R)" }
    else { $badge = Format-Badge 'BUSY' 'Off'; $text = "$($u.Off)the OFFICIAL build$($u.R) pid $($app.Id) $($u.Dim)- stop it first$($u.R)" }
    Write-PanelRow "  $($u.Label)App$($u.R)       $badge  $text"

    $mcp = Get-Mcp
    switch ($mcp.State) {
        'up' {
            $badge = Format-Badge 'ON' 'On'
            $text = ":$($mcp.Port)  $($u.Dim)$($mcp.Tools) tools  v$($mcp.Version)$($u.R)"
        }
        'down'  { $badge = Format-Badge 'WAIT' 'Warn'; $text = "$($u.Dim)endpoint names :$($mcp.Port), nothing answers yet$($u.R)" }
        'other' { $badge = Format-Badge 'BUSY' 'Off';  $text = "$($u.Off)port :$($mcp.Port) answers as '$($mcp.Who)'$($u.R)" }
        default { $badge = Format-Badge 'off' 'Off';   $text = "$($u.Dim)no endpoint file - the app writes it on launch$($u.R)" }
    }
    Write-PanelRow "  $($u.Label)MCP$($u.R)       $badge  $text"

    if ($mcp.State -eq 'up') {
        if ($mcp.Missing.Count) { $badge = Format-Badge 'GONE' 'Off'; $text = "$($u.Off)a stock OpenReel is answering$($u.R) $($u.Dim)($($mcp.Missing -join ', '))$($u.R)" }
        else { $badge = Format-Badge 'ok' 'On'; $text = "$($u.Dim)import_media_from_path  list_overlays$($u.R)" }
        Write-PanelRow "  $($u.Label)Fork$($u.R)      $badge  $text"
        $open = if ($mcp.Project) { $mcp.Project } else { "$($u.Dim)none open$($u.R)" }
        Write-PanelRow "  $($u.Label)Project$($u.R)   $(Format-Badge '  -' 'Dim')  $open"
    }

    if (Test-Path $script:Exe) {
        $badge = Format-Badge 'ok' 'On'
        $text = "$((Get-Item $script:Exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
    } else { $badge = Format-Badge 'none' 'Off'; $text = "$($u.Off)not built$($u.R) $($u.Dim)- run [4]$($u.R)" }
    $git = Get-Git
    Write-PanelRow "  $($u.Label)Build$($u.R)     $badge  $text  $($u.Dim)on $($git.Branch)$($u.R)"

    $base = if ($git.Base) { $git.Base } else { '(no tag)' }
    if ($git.Ahead -and $git.Ahead -ne '0') {
        $badge = Format-Badge 'NEW' 'Warn'
        $text = "on $base  $($u.Warn)$($git.Ahead) behind upstream main$($u.R)"
    } else {
        $badge = Format-Badge 'ok' 'On'
        $text = "on $base  $($u.Dim)level with upstream$($u.R)"
    }
    Write-PanelRow "  $($u.Label)Upstream$($u.R)  $badge  $text"
}

function Write-MenuKeys {
    $u = $script:Ui
    $k = { param($key, $label) "$($u.Key)[$key]$($u.R) $($u.Label)$($label.PadRight(16))$($u.R)" }
    Write-Host ''
    Write-Host "   $(& $k '1' 'Start')$(& $k '2' 'Stop')$(& $k '3' 'Restart')"
    Write-Host "   $(& $k '4' 'Build')$(& $k '5' 'Upstream')$(& $k '6' 'Doctor')"
    Write-Host "   $(& $k 'L' 'Logs')$(& $k 'R' 'Refresh')$($u.Off)[Q]$($u.R) $($u.Label)Quit$($u.R)"
    Write-Host ''
}

function Show-Panel {
    param([switch] $WithMenu)
    Clear-Host
    Write-Host ''
    Write-Header
    try { Write-StatusRows }
    catch { Write-PanelRow "  $($script:Ui.Off)status probe failed: $($_.Exception.Message)$($script:Ui.R)" }
    Write-PanelRule
    if ($WithMenu) { Write-MenuKeys }
    try { $Host.UI.RawUI.WindowTitle = 'OpenReel Dev' } catch { }
}

# --- actions ------------------------------------------------------------------

function Invoke-Start {
    param([switch] $Logged)
    Write-Stage 'Start'
    if (-not (Test-Path $script:Exe)) { Write-Bad "not built: $script:Exe"; return 1 }
    $app = Get-App
    if ($app -and $app.IsDev) { Write-Ok "already running, pid $($app.Id)"; return 0 }
    if ($app) {
        Write-Bad "the official build is running (pid $($app.Id))."
        Write-Host "        Both write $($script:Endpoint), so only one may run."
        return 1
    }
    if ($Logged) {
        # Capture for a debugging session. The launcher keeps the write handles
        # open until the app exits, so a piped or scripted run of this action
        # blocks - which is why it is not the default.
        Start-Process -FilePath $script:Exe -RedirectStandardOutput $script:OutLog -RedirectStandardError $script:ErrLog
        Write-Ok 'launched, output captured'
        Write-Host "        $($script:Ui.Dim)$($script:OutLog)$($script:Ui.R)"
        return 0
    }
    # Detached through `start`, so the app inherits no handle from this console:
    # nothing it writes can land on top of the menu, and this action returns at
    # once even when piped.
    # cmd's `start` takes a window title first; '""' is an empty one, and the
    # quoted path follows. Built without escapes: PowerShell quoting inside an
    # argument list is a reliable way to pass the wrong string.
    $quoted = '"' + $script:Exe + '"'
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'start', '""', $quoted -WindowStyle Hidden
    Write-Ok 'launched'
    return 0
}

function Invoke-Stop {
    Write-Stage 'Stop'
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'OpenReel*' })
    if ($procs.Count -eq 0) { Write-Note 'nothing running'; return 0 }
    # Ask the window to close rather than killing it: a kill loses an unsaved
    # project, and OpenReel prompts before it quits.
    foreach ($p in $procs) { try { $p.CloseMainWindow() | Out-Null } catch { } }
    Start-Sleep -Seconds 3
    $left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'OpenReel*' })
    if ($left.Count) { Write-Note "$($left.Count) process(es) still up - it may be asking to save" }
    else { Write-Ok 'stopped' }
    return 0
}

function Invoke-Build {
    Write-Stage 'Build from source'
    $git = Get-Git
    if ($git.Branch -ne $script:DevBranch) {
        Write-Bad "on '$($git.Branch)'. The dev identity - own appId, own userData - is on $script:DevBranch."
        return 1
    }
    if (Get-App) { Write-Bad 'stop OpenReel first: the exe is locked while it runs'; return 1 }
    # apps/desktop's build:renderer is written with POSIX env syntax
    # (OPENREEL_DESKTOP=1 pnpm ...), which cmd cannot run, so the three steps run
    # through Git Bash here rather than through `pnpm run pack`.
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not (Test-Path $bash)) { Write-Bad "Git Bash not found at $bash"; return 1 }
    $unix = "$(& $bash -lc "cygpath -u '$script:Root'")".Trim()
    $steps = @(
        @{ Name = 'renderer';  Cmd = "cd '$unix' && OPENREEL_DESKTOP=1 pnpm --filter @openreel/web build" }
        @{ Name = 'main';      Cmd = "cd '$unix/apps/desktop' && pnpm run build:main" }
        @{ Name = 'packaging'; Cmd = "cd '$unix/apps/desktop' && npx electron-builder --dir" }
    )
    foreach ($step in $steps) {
        Write-Host "  $($script:Ui.Dim)$($step.Name)...$($script:Ui.R)"
        & $bash -lc $step.Cmd
        if ($LASTEXITCODE -ne 0) { Write-Bad "$($step.Name) failed"; return $LASTEXITCODE }
    }
    Write-Ok "built: $script:Exe"
    return 0
}

function Invoke-Upstream {
    Write-Stage 'Upstream'
    $u = $script:Ui
    Push-Location $script:Root
    try {
        git fetch --quiet upstream --tags 2>&1 | Out-Null
        $git = Get-Git
        $base = if ($git.Base) { $git.Base } else { '(no tag)' }
        Write-Host "  patched onto  $($u.Label)$base$($u.R)"
        Write-Host "  newest tags   $((git tag -l --sort=-creatordate | Select-Object -First 5) -join ', ')"
        if ($git.Ahead) { Write-Host "  upstream main $($u.Warn)$($git.Ahead)$($u.R) commit(s) past that tag" }
        Write-Host ''
        Write-Host "  $($u.Dim)This fork is three commits: the two MCP tools, the main-process path"
        Write-Host "  checks, and the dev identity. Rebase when a release carries something you"
        Write-Host "  actually want - not on every push upstream:$($u.R)"
        Write-Host "    git rebase --onto <newtag> $base $script:PatchBranch"
        Write-Host "    git rebase $script:PatchBranch $script:DevBranch"
        Write-Host "    pnpm --filter @openreel/agent test"
        Write-Host "  $($u.Dim)then [4] Build, and push/pull one story to prove the round trip.$($u.R)"
        Write-Host "  $($u.Dim)PR: https://github.com/Augani/openreel-video/pull/107$($u.R)"
        return 0
    } finally { Pop-Location }
}

function Show-LogTail {
    param([string] $Path, [int] $Lines = 40)
    Write-Stage $Path
    if (-not (Test-Path $Path)) { Write-Note 'no such log yet'; return }
    $tail = @(Get-Content $Path -Tail $Lines)
    if (-not $tail.Count) { Write-Note 'empty'; return }
    foreach ($line in $tail) {
        $color = if ($line -match 'error|fail|exception|ENOENT|denied') { 'Red' } else { 'Gray' }
        Write-Host "  $line" -ForegroundColor $color
    }
}

function Invoke-Logs {
    $u = $script:Ui
    while ($true) {
        Clear-Host
        Write-Stage 'Logs'
        Write-Host "   $($u.Key)[1]$($u.R) app errors    $($u.Dim)$($script:ErrLog)$($u.R)"
        Write-Host "   $($u.Key)[2]$($u.R) app output    $($u.Dim)$($script:OutLog)$($u.R)"
        Write-Host "   $($u.Dim)      both fill only when started with: OpenReel-Launcher.cmd start -Logged$($u.R)"
        Write-Host "   $($u.Key)[3]$($u.R) mcp endpoint  $($u.Dim)$($script:Endpoint)$($u.R)"
        Write-Host "   $($u.Off)[B]$($u.R) back"
        Write-Host ''
        switch (Read-Key "  $($u.Key)Select: $($u.R)") {
            '1' { Show-LogTail $script:ErrLog; Wait-AnyKey }
            '2' { Show-LogTail $script:OutLog; Wait-AnyKey }
            '3' {
                Write-Stage 'MCP endpoint'
                if (Test-Path $script:Endpoint) {
                    # The token is a live credential; the port is the useful part.
                    $cfg = Get-Content $script:Endpoint -Raw | ConvertFrom-Json
                    Write-Host "  url   $($cfg.url)"
                    Write-Host "  port  $($cfg.port)"
                    Write-Host "  token $($u.Dim)(hidden)$($u.R)"
                } else { Write-Note 'not written yet' }
                Wait-AnyKey
            }
            'B' { return 0 }
            ''  { if ([Console]::IsInputRedirected) { return 0 } }
        }
    }
}

function Invoke-Doctor {
    Write-Stage 'Doctor'
    if (Test-Path $script:Exe) { Write-Ok "dev build   $script:Exe" }
    else { Write-Bad 'dev build   missing - run [4] Build' }
    if (Test-Path $script:Official) { Write-Note "official    $script:Official $($script:Ui.Dim)(never run both)$($script:Ui.R)" }
    if (Test-Path $script:Endpoint) { Write-Ok "endpoint    $script:Endpoint" }
    else { Write-Note 'endpoint    not written yet - the app writes it on launch' }
    $data = Join-Path $env:APPDATA '@openreel\desktop-dev'
    if (Test-Path $data) { Write-Ok "userData    $data" }
    else { Write-Note "userData    $data $($script:Ui.Dim)(created on first run)$($script:Ui.R)" }
    foreach ($tool in @('pnpm', 'node', 'git')) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) { Write-Ok ("{0,-11} {1}" -f $tool, $cmd.Source) } else { Write-Bad "$tool  not on PATH" }
    }
    return 0
}

function Invoke-Action {
    param([string] $Name)
    switch ($Name) {
        'start'    { return (Invoke-Start -Logged:$Logged) }
        'stop'     { return (Invoke-Stop) }
        'restart'  { (Invoke-Stop) | Out-Null; Start-Sleep -Seconds 2; return (Invoke-Start) }
        'build'    { return (Invoke-Build) }
        'upstream' { return (Invoke-Upstream) }
        'doctor'   { return (Invoke-Doctor) }
        'logs'     { return (Invoke-Logs) }
        'status'   { Show-Panel; return 0 }
    }
    return 0
}

if ($Action -ne 'menu') { exit (Invoke-Action $Action) }

while ($true) {
    Show-Panel -WithMenu
    switch (Read-Key "  $($script:Ui.Key)Select: $($script:Ui.R)") {
        '1' { (Invoke-Action 'start')    | Out-Null; Wait-AnyKey }
        '2' { (Invoke-Action 'stop')     | Out-Null; Wait-AnyKey }
        '3' { (Invoke-Action 'restart')  | Out-Null; Wait-AnyKey }
        '4' { (Invoke-Action 'build')    | Out-Null; Wait-AnyKey }
        '5' { (Invoke-Action 'upstream') | Out-Null; Wait-AnyKey }
        '6' { (Invoke-Action 'doctor')   | Out-Null; Wait-AnyKey }
        'L' { (Invoke-Action 'logs')     | Out-Null }
        'R' { }
        'Q' { exit 0 }
        ''  { if ([Console]::IsInputRedirected) { exit 0 } }
    }
}
