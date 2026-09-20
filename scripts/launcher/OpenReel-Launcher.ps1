<#
.SYNOPSIS
    OpenReel Dev launcher: start, stop, build and check the local fork.

.DESCRIPTION
    With no action it opens a menu under a live status panel: which OpenReel is
    running, whether the MCP endpoint answers and identifies itself as OpenReel,
    how many tools it serves, whether this fork's two tools are among them, and
    whether upstream has moved past the tag the patch sits on.

    With an action it runs that action once and exits with its code.

.PARAMETER Action
    menu (default) | start | stop | restart | status | build | upstream | doctor
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'start', 'stop', 'restart', 'status', 'build', 'upstream', 'doctor')]
    [string] $Action = 'menu'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:Exe = Join-Path $script:Root 'apps\desktop\release\win-unpacked\OpenReel Dev.exe'
$script:Official = Join-Path $env:LOCALAPPDATA 'Programs\@openreeldesktop\OpenReel.exe'
$script:Endpoint = Join-Path $HOME '.openreel\mcp-endpoint.json'
$script:PatchBranch = 'feat/mcp-local-import'
$script:DevBranch = 'dev/openreel-dev'

# The two tools this fork exists for. Their absence means a stock build is up.
$script:ForkTools = @('import_media_from_path', 'list_overlays')

$esc = [char]27
$u = @{
    R   = "$esc[0m";    Label = "$esc[1;36m"; Sub  = "$esc[38;5;244m"
    Key = "$esc[1;33m"; Ok    = "$esc[32m";   Warn = "$esc[33m"
    Bad = "$esc[31m";   Dim   = "$esc[38;5;240m"
}

function Write-Stage { param([string] $Text) Write-Host "`n  $($u.Label)$Text$($u.R)" }
function Write-Ok    { param([string] $Text) Write-Host "  $($u.Ok)ok$($u.R)   $Text" }
function Write-Note  { param([string] $Text) Write-Host "  $($u.Warn)..$($u.R)   $Text" }
function Write-Bad   { param([string] $Text) Write-Host "  $($u.Bad)xx$($u.R)   $Text" }

function Read-Key {
    param([string] $Prompt)
    Write-Host $Prompt -NoNewline
    if ([Console]::IsInputRedirected) { return "$(Read-Host)".ToUpper() }
    $k = [Console]::ReadKey($true)
    Write-Host $k.KeyChar
    return "$($k.KeyChar)".ToUpper()
}

function Wait-AnyKey {
    Write-Host "`n  $($u.Dim)any key to continue$($u.R)" -NoNewline
    if (-not [Console]::IsInputRedirected) { [Console]::ReadKey($true) | Out-Null }
    Write-Host ''
}

# --- state --------------------------------------------------------------------

function Get-Running {
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'OpenReel*' -and $_.MainWindowTitle -ne '' })
    foreach ($p in $procs) {
        $path = try { $p.Path } catch { $null }
        if ($path) {
            return [pscustomobject]@{ Id = $p.Id; Path = $path; IsDev = ($path -eq $script:Exe) }
        }
    }
    return $null
}

# The endpoint file names the port and a token that rotates every launch, so it
# is read fresh on each probe rather than cached.
function Get-Mcp {
    if (-not (Test-Path $script:Endpoint)) { return [pscustomobject]@{ State = 'no endpoint file yet' } }
    $cfg = Get-Content $script:Endpoint -Raw | ConvertFrom-Json
    $headers = @{ authorization = "Bearer $($cfg.token)" }
    $init = @{
        jsonrpc = '2.0'; id = 1; method = 'initialize'
        params  = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'launcher'; version = '1' } }
    } | ConvertTo-Json -Depth 6
    try {
        $hello = Invoke-RestMethod -Method Post -Uri $cfg.url -TimeoutSec 5 -ContentType 'application/json' -Headers $headers -Body $init
    } catch {
        return [pscustomobject]@{ State = 'unreachable'; Port = $cfg.port }
    }
    # Identity before trust: a stale endpoint file can name a port that
    # something else has taken since.
    if ($hello.result.serverInfo.name -ne 'openreel') {
        return [pscustomobject]@{ State = 'wrong server'; Port = $cfg.port; Who = "$($hello.result.serverInfo.name)" }
    }
    $list = Invoke-RestMethod -Method Post -Uri $cfg.url -TimeoutSec 15 -ContentType 'application/json' -Headers $headers `
        -Body (@{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} } | ConvertTo-Json -Depth 4)
    $names = @($list.result.tools | ForEach-Object { $_.name })
    $missing = @($script:ForkTools | Where-Object { $names -notcontains $_ })
    return [pscustomobject]@{
        State = 'up'; Port = $cfg.port; Version = "$($hello.result.serverInfo.version)"
        Tools = $names.Count; HasFork = ($missing.Count -eq 0)
    }
}

function Get-Git {
    Push-Location $script:Root
    try {
        $branch = "$(git branch --show-current)".Trim()
        $base = "$(git describe --tags --abbrev=0 "$script:PatchBranch^" 2>$null)".Trim()
        if ($LASTEXITCODE -ne 0) { $base = '' }
        $newest = "$(git tag -l --sort=-creatordate | Select-Object -First 1)".Trim()
        return [pscustomobject]@{ Branch = $branch; Base = $base; Newest = $newest }
    } finally { Pop-Location }
}

function Show-Panel {
    param([switch] $WithMenu)
    Clear-Host
    Write-Host ''
    Write-Host "  $($u.Sub) __  ___ $($u.R)"
    Write-Host "  $($u.Sub)|  \|  _|$($u.R)   $($u.Label)OpenReel Dev$($u.R)"
    Write-Host "  $($u.Sub)|__/|_|  $($u.R)   $($u.Sub)L A U N C H E R$($u.R)"
    Write-Host ''

    $proc = Get-Running
    if ($null -eq $proc) { Write-Note 'app        not running' }
    elseif ($proc.IsDev) { Write-Ok   "app        OpenReel Dev, pid $($proc.Id)" }
    else                 { Write-Bad  "app        the OFFICIAL build is running (pid $($proc.Id)) - stop it first" }

    $mcp = Get-Mcp
    if ($mcp.State -eq 'up') {
        Write-Ok "mcp        127.0.0.1:$($mcp.Port), $($mcp.Tools) tools, app v$($mcp.Version)"
        if ($mcp.HasFork) { Write-Ok  'fork tools import_media_from_path, list_overlays' }
        else              { Write-Bad 'fork tools MISSING - a stock OpenReel is answering' }
    }
    elseif ($mcp.State -eq 'unreachable')  { Write-Note "mcp        endpoint names port $($mcp.Port); nothing answers" }
    elseif ($mcp.State -eq 'wrong server') { Write-Bad  "mcp        port $($mcp.Port) answers as '$($mcp.Who)', not OpenReel" }
    else                                   { Write-Note "mcp        $($mcp.State)" }

    if (Test-Path $script:Exe) {
        Write-Ok "build      $((Get-Item $script:Exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
    } else { Write-Bad 'build      not built yet - run [4]' }

    $git = Get-Git
    $base = if ($git.Base) { $git.Base } else { '(no tag)' }
    Write-Host "  $($u.Dim)--$($u.R)   branch     $($git.Branch), patched onto $base"
    if ($git.Newest -and $git.Base -and $git.Newest -ne $git.Base) {
        Write-Note "upstream   $($git.Newest) is newer than $base - see [5]"
    }

    Write-Host "`n  $($u.Dim)$('-' * 64)$($u.R)"
    if ($WithMenu) {
        Write-Host ''
        Write-Host "   $($u.Key)[1]$($u.R) Start    $($u.Key)[2]$($u.R) Stop    $($u.Key)[3]$($u.R) Restart"
        Write-Host "   $($u.Key)[4]$($u.R) Build from source    $($u.Key)[5]$($u.R) Upstream    $($u.Key)[6]$($u.R) Doctor"
        Write-Host "   $($u.Key)[R]$($u.R) Refresh    $($u.Dim)[Q]$($u.R) Quit"
        Write-Host ''
    }
    try { $Host.UI.RawUI.WindowTitle = 'OpenReel Dev' } catch { }
}

# --- actions ------------------------------------------------------------------

function Invoke-Start {
    Write-Stage 'Start'
    if (-not (Test-Path $script:Exe)) { Write-Bad "not built: $script:Exe"; return 1 }
    $proc = Get-Running
    if ($proc -and $proc.IsDev) { Write-Ok "already running, pid $($proc.Id)"; return 0 }
    if ($proc) {
        Write-Bad "the official build is running (pid $($proc.Id))."
        Write-Host "       Both write $($script:Endpoint), so only one may run. Stop it first."
        return 1
    }
    Start-Process $script:Exe
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
    if (Get-Running) { Write-Bad 'stop OpenReel first: the exe is locked while it runs'; return 1 }
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
        Write-Host "  $($u.Dim)$($step.Name)...$($u.R)"
        & $bash -lc $step.Cmd
        if ($LASTEXITCODE -ne 0) { Write-Bad "$($step.Name) failed"; return $LASTEXITCODE }
    }
    Write-Ok "built: $script:Exe"
    return 0
}

function Invoke-Upstream {
    Write-Stage 'Upstream'
    Push-Location $script:Root
    try {
        git fetch --quiet upstream --tags 2>&1 | Out-Null
        $git = Get-Git
        $base = if ($git.Base) { $git.Base } else { '(no tag)' }
        Write-Host "  patched onto  $($u.Label)$base$($u.R)"
        Write-Host "  newest tags   $((git tag -l --sort=-creatordate | Select-Object -First 5) -join ', ')"
        if ($git.Base) {
            $ahead = "$(git rev-list --count "$($git.Base)..upstream/main" 2>$null)".Trim()
            if ($LASTEXITCODE -eq 0 -and $ahead) {
                Write-Host "  upstream main $($u.Warn)$ahead$($u.R) commit(s) past that tag"
            }
        }
        Write-Host ''
        Write-Host "  $($u.Dim)This fork is three commits: the two MCP tools, the main-process path"
        Write-Host "  checks, and the dev identity. Rebase when a release carries something you"
        Write-Host "  actually want - not on every push upstream:$($u.R)"
        Write-Host "    git rebase --onto <newtag> $base $script:PatchBranch"
        Write-Host "    git rebase $script:PatchBranch $script:DevBranch"
        Write-Host "    pnpm --filter @openreel/agent test"
        Write-Host "  $($u.Dim)then [4] Build, and push/pull one story to prove the round trip.$($u.R)"
        return 0
    } finally { Pop-Location }
}

function Invoke-Doctor {
    Write-Stage 'Doctor'
    if (Test-Path $script:Exe) { Write-Ok "dev build   $script:Exe" }
    else { Write-Bad 'dev build   missing - run [4] Build' }
    if (Test-Path $script:Official) { Write-Note "official    $script:Official (never run both)" }
    if (Test-Path $script:Endpoint) { Write-Ok "endpoint    $script:Endpoint" }
    else { Write-Note 'endpoint    not written yet - the app writes it on launch' }
    $data = Join-Path $env:APPDATA '@openreel\desktop-dev'
    if (Test-Path $data) { Write-Ok "userData    $data" }
    else { Write-Note "userData    $data (created on first run)" }
    foreach ($tool in @('pnpm', 'node', 'git')) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) { Write-Ok ("{0,-11} {1}" -f $tool, $cmd.Source) } else { Write-Bad "$tool  not on PATH" }
    }
    return 0
}

function Invoke-Action {
    param([string] $Name)
    switch ($Name) {
        'start'    { return (Invoke-Start) }
        'stop'     { return (Invoke-Stop) }
        'restart'  { (Invoke-Stop) | Out-Null; Start-Sleep -Seconds 2; return (Invoke-Start) }
        'build'    { return (Invoke-Build) }
        'upstream' { return (Invoke-Upstream) }
        'doctor'   { return (Invoke-Doctor) }
        'status'   { Show-Panel; return 0 }
    }
    return 0
}

if ($Action -ne 'menu') { exit (Invoke-Action $Action) }

while ($true) {
    Show-Panel -WithMenu
    switch (Read-Key "  $($u.Key)Select: $($u.R)") {
        '1' { (Invoke-Action 'start')    | Out-Null; Wait-AnyKey }
        '2' { (Invoke-Action 'stop')     | Out-Null; Wait-AnyKey }
        '3' { (Invoke-Action 'restart')  | Out-Null; Wait-AnyKey }
        '4' { (Invoke-Action 'build')    | Out-Null; Wait-AnyKey }
        '5' { (Invoke-Action 'upstream') | Out-Null; Wait-AnyKey }
        '6' { (Invoke-Action 'doctor')   | Out-Null; Wait-AnyKey }
        'R' { }
        'Q' { exit 0 }
        ''  { if ([Console]::IsInputRedirected) { exit 0 } }
    }
}
