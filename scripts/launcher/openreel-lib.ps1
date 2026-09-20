# ============================================================================
#  Shared console furniture for the OpenReel Dev launcher.
#
#  Same panel grammar as the other launchers on this machine: a framed box of a
#  fixed width, one labelled row per fact, a badge carrying the state, and
#  detail in dim text after it. Colour is ANSI, enabled only after the console
#  is put into virtual-terminal mode, and skipped entirely under NO_COLOR.
# ============================================================================

Set-StrictMode -Version 2.0

$script:Ui = @{}
$script:PanelWidth = 72

function Initialize-Ansi {
    $names = 'R', 'Frame', 'Title', 'Sub', 'Key', 'Label', 'Dim', 'On', 'Off', 'Warn'
    foreach ($n in $names) { $script:Ui[$n] = '' }
    if ($env:NO_COLOR) { return }

    try {
        if (-not ('OpenReel.ConsoleMode' -as [type])) {
            Add-Type -Namespace 'OpenReel' -Name 'ConsoleMode' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@
        }
        $handle = [OpenReel.ConsoleMode]::GetStdHandle(-11)
        $mode = [uint32]0
        if (-not [OpenReel.ConsoleMode]::GetConsoleMode($handle, [ref] $mode)) { return }
        # 4 = ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (-not [OpenReel.ConsoleMode]::SetConsoleMode($handle, ($mode -bor 4))) { return }
    }
    catch { return }

    $e = [char]27
    $script:Ui.R     = "$e[0m"
    $script:Ui.Frame = "$e[38;5;73m"     # slate teal, the frame only
    $script:Ui.Title = "$e[1;38;5;80m"   # the wordmark
    $script:Ui.Sub   = "$e[38;5;108m"
    $script:Ui.Key   = "$e[1;38;5;80m"
    $script:Ui.Label = "$e[1;97m"
    $script:Ui.Dim   = "$e[38;5;245m"
    $script:Ui.On    = "$e[1;38;5;46m"
    $script:Ui.Off   = "$e[1;38;5;160m"
    $script:Ui.Warn  = "$e[1;38;5;220m"
}

# Pad to the panel width by VISIBLE length: colour codes occupy no columns, so
# measuring the raw string would leave every coloured row short.
function Write-PanelRow {
    param([string] $Text = '', [int] $Width = $script:PanelWidth)
    $visible = ($Text -replace "$([char]27)\[[0-9;]*m", '').Length
    $pad = ' ' * [Math]::Max(0, $Width - $visible)
    Write-Host " $($script:Ui.Frame)|$($script:Ui.R)$Text$pad$($script:Ui.Frame)|$($script:Ui.R)"
}

function Write-PanelRule {
    param([int] $Width = $script:PanelWidth)
    Write-Host " $($script:Ui.Frame)+$('-' * $Width)+$($script:Ui.R)"
}

# A fixed-width badge, so every row's detail text starts at one column.
function Format-Badge {
    param([string] $Text, [string] $Color)
    return "$($script:Ui[$Color])[$($Text.PadLeft(4).Substring(0, 4))]$($script:Ui.R)"
}

function Write-Stage { param([string] $Text) Write-Host "`n  $($script:Ui.Label)$Text$($script:Ui.R)" }
function Write-Ok    { param([string] $Text) Write-Host "  $($script:Ui.On)ok$($script:Ui.R)    $Text" }
function Write-Note  { param([string] $Text) Write-Host "  $($script:Ui.Warn)..$($script:Ui.R)    $Text" }
function Write-Bad   { param([string] $Text) Write-Host "  $($script:Ui.Off)xx$($script:Ui.R)    $Text" }

# One keypress, upper-cased. Falls back to a typed line when input is
# redirected: RawUI.ReadKey blocks forever there rather than throwing.
function Read-Key {
    param([string] $Prompt = '')
    if ($Prompt) { Write-Host $Prompt -NoNewline }
    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
        Write-Host ''
        if ($null -eq $line) { return '' }
        return "$line".Trim().ToUpper()
    }
    $k = [Console]::ReadKey($true)
    Write-Host $k.KeyChar
    return "$($k.KeyChar)".ToUpper()
}

function Wait-AnyKey {
    Write-Host "`n  $($script:Ui.Dim)any key to continue$($script:Ui.R)" -NoNewline
    if (-not [Console]::IsInputRedirected) { [Console]::ReadKey($true) | Out-Null }
    Write-Host ''
}

function Format-Uptime {
    param($Span)
    if ($null -eq $Span) { return '' }
    if ($Span.TotalDays -ge 1)  { return '{0}d {1}h' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours }
    if ($Span.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes }
    return '{0}m' -f [int][Math]::Floor($Span.TotalMinutes)
}
