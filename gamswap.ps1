#Requires -Version 5.1
<#
.SYNOPSIS
  Swap between per-client GAM config directories.

.DESCRIPTION
  Each tenant is a full GAM config dir stored under RepoPath. Launching a tenant:
    1. takes a lock on it,
    2. copies it to a private local working folder (gamcache excluded, config_dir/cache_dir
       stripped from gam.cfg so GAM defaults them to the working folder),
    3. opens a new PowerShell window with GAMCFGDIR pointing at that copy,
    4. when the window closes, snapshots the repo copy, writes the working copy back if any
       file changed, prunes old snapshots, deletes the working folder and releases the lock.

.PARAMETER Tenant
  Launch this tenant directly instead of showing the menu.

.PARAMETER ChildCommand
  Test hook: run this command in the child window and exit, instead of an interactive session.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'gamswap.config.psd1'),
    [string]$Tenant,
    [string]$ChildCommand
)

$ErrorActionPreference = 'Stop'
$script:Cfg = $null

#region helpers
function Import-GamSwapConfig {
    param([string]$Path)
    $c = Import-PowerShellDataFile -Path $Path
    $base = Split-Path -Parent (Resolve-Path $Path).Path
    foreach ($k in 'RepoPath', 'SessionRoot') {
        $v = [Environment]::ExpandEnvironmentVariables($c[$k])
        if (-not [IO.Path]::IsPathRooted($v)) { $v = Join-Path $base $v }
        $c[$k] = [IO.Path]::GetFullPath($v)
    }
    if (-not $c.ContainsKey('BackupCount')) { $c.BackupCount = 3 }
    $script:Cfg = $c
}

function ConvertTo-SingleQuoted { param([string]$s) $s -replace "'", "''" }

function Copy-GamDir {
    # robocopy so gamcache can be skipped at any depth; exit codes < 8 are success.
    # *.lock / *.changed are skipped too: they are bookkeeping that belongs to a specific folder
    # (the tenant dir / a backup dir), never part of the auth files being copied around.
    param([string]$From, [string]$To)
    $null = robocopy $From $To /E /XD gamcache /XF *.lock *.changed /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From -> $To" }
    $global:LASTEXITCODE = 0
}

function Set-GamCfgPortable {
    # Drop the absolute config_dir / cache_dir lines so GAM derives them from GAMCFGDIR.
    param([string]$Dir)
    $cfg = Join-Path $Dir 'gam.cfg'
    if (-not (Test-Path $cfg)) { return }
    $lines = [IO.File]::ReadAllLines($cfg) | Where-Object { $_ -notmatch '^\s*(config_dir|cache_dir)\s*=' }
    [IO.File]::WriteAllLines($cfg, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
}

function Get-Manifest {
    param([string]$Dir)
    $m = @{}
    $root = (Resolve-Path $Dir).Path.TrimEnd('\')
    Get-ChildItem $Dir -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\gamcache\\' -and $_.Extension -notin '.lock', '.changed' } |
        ForEach-Object { $m[$_.FullName.Substring($root.Length + 1)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    $m
}

function Test-ManifestEqual {
    param($A, $B)
    if ($A.Count -ne $B.Count) { return $false }
    foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $A[$k] -ne $B[$k]) { return $false } }
    $true
}

function Protect-Dir {
    # Working copies hold live credentials: restrict to the current user.
    param([string]$Dir)
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $null = icacls $Dir /inheritance:r /grant:r "${me}:(OI)(CI)F" 2>&1
        $global:LASTEXITCODE = 0
    } catch { Write-Warning "Could not restrict ACL on $Dir : $_" }
}

function Get-AdminEmail {
    param([string]$Dir)
    $cfg = Join-Path $Dir 'gam.cfg'
    if (-not (Test-Path $cfg)) { return '' }
    $hit = Select-String -Path $cfg -Pattern '^\s*admin_email\s*=\s*(.*?)\s*$' | Select-Object -First 1
    if ($hit) { $hit.Matches[0].Groups[1].Value } else { '' }
}
#endregion

#region locks
# A lock is a <username>.<hostname>.lock file inside the tenant's own folder, so anyone browsing
# the share can see who is working on it. Its JSON body carries the details.
function Get-LockFiles {
    param([string]$T)
    $d = Join-Path $script:Cfg.RepoPath $T
    if (Test-Path $d) { @(Get-ChildItem $d -Filter '*.lock' -File -Force) } else { @() }
}

function Get-OwnLockPath {
    param([string]$T)
    $n = "$env:USERNAME.$env:COMPUTERNAME.lock" -replace '[\\/:*?"<>|]', '_'
    Join-Path (Join-Path $script:Cfg.RepoPath $T) $n
}

function Read-LockFile {
    param([string]$Path)
    $lock = $null
    try { $lock = Get-Content $Path -Raw | ConvertFrom-Json } catch { }
    # PowerShell 7 turns ISO timestamps in JSON into [datetime]; keep them as stable ISO strings.
    if ($lock -and $lock.Started -is [datetime]) { $lock.Started = $lock.Started.ToString('s') }
    $lock
}

function Get-Lock {
    param([string]$T)
    $f = Get-LockFiles $T | Select-Object -First 1
    if (-not $f) { return }
    $lock = Read-LockFile $f.FullName
    if ($lock) { return $lock }
    # Unreadable lock: still treat as held, owner taken from the file name, never auto-stale.
    [pscustomobject]@{ Tenant = $T; User = $f.BaseName; Machine = '?'; Started = '?'; SessionDir = ''; Procs = @() }
}

function New-Lock {
    param([string]$T, [string]$SessionDir)
    if (Get-LockFiles $T) { return $false }
    $p = Get-OwnLockPath $T
    $self = Get-Process -Id $PID
    $body = @{
        Tenant     = $T
        User       = "$env:USERDOMAIN\$env:USERNAME"
        Machine    = $env:COMPUTERNAME
        Started    = (Get-Date).ToString('s')
        SessionDir = $SessionDir
        Procs      = @(@{ Id = $self.Id; Start = $self.StartTime.Ticks })
    } | ConvertTo-Json -Depth 4
    try {
        $fs = [IO.File]::Open($p, 'CreateNew', 'Write', 'None')   # fails if it already exists
    } catch { return $false }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
    # Different names can't exclude each other atomically, so re-check: if anyone else's lock
    # appeared meanwhile, both sides back off (safe; worst case is a retry).
    if (@(Get-LockFiles $T | Where-Object { $_.FullName -ne $p })) {
        Remove-Item $p -Force -ErrorAction SilentlyContinue
        return $false
    }
    $true
}

function Update-LockProcs {
    param([string]$T, [object[]]$Procs)
    $p = Get-OwnLockPath $T
    $lock = Read-LockFile $p
    $lock.Procs = @($Procs)
    $lock | ConvertTo-Json -Depth 4 | Set-Content $p -Encoding UTF8
}

function Remove-Lock {
    # Own lock by default; -All also clears other people's (stale recovery / manual unlock).
    param([string]$T, [switch]$All)
    if ($All) { Get-LockFiles $T | Remove-Item -Force -ErrorAction SilentlyContinue }
    else { Remove-Item (Get-OwnLockPath $T) -Force -ErrorAction SilentlyContinue }
}

function Test-LockStale {
    # Only provably stale if it's ours (same machine) and none of its processes are still alive.
    param($Lock)
    if ($Lock.Machine -ne $env:COMPUTERNAME) { return $false }
    foreach ($pr in @($Lock.Procs)) {
        $p = Get-Process -Id $pr.Id -ErrorAction SilentlyContinue
        if ($p -and $p.StartTime.Ticks -eq [int64]$pr.Start) { return $false }
    }
    $true
}
#endregion

#region repo operations
function Get-TenantNames {
    if (-not (Test-Path $script:Cfg.RepoPath)) { return @() }
    @(Get-ChildItem $script:Cfg.RepoPath -Directory | Where-Object { $_.Name -notlike '_*' } | Sort-Object Name | ForEach-Object Name)
}

function Get-ManifestDiff {
    param($Base, $Now)
    $d = @()
    foreach ($k in ($Now.Keys | Sort-Object)) {
        if (-not $Base.ContainsKey($k)) { $d += "added: $k" } elseif ($Base[$k] -ne $Now[$k]) { $d += "modified: $k" }
    }
    foreach ($k in ($Base.Keys | Sort-Object)) { if (-not $Now.ContainsKey($k)) { $d += "removed: $k" } }
    $d
}

function Write-ChangeMarker {
    # <username>.<hostname>.changed inside a backup folder: who was working on the tenant when the
    # live copy was replaced (this backup is the copy that got replaced). Names only, no contents.
    param([string]$Dir, [string]$Action, [string[]]$Files, $Lock)
    $user = if ($Lock -and $Lock.User) { [string]$Lock.User } else { "$env:USERDOMAIN\$env:USERNAME" }
    $machine = if ($Lock -and $Lock.Machine -and $Lock.Machine -ne '?') { [string]$Lock.Machine } else { $env:COMPUTERNAME }
    $name = ("{0}.{1}.changed" -f ($user -replace '^.*\\', ''), $machine) -replace '[\\/:*?"<>|]', '_'
    @{
        Note           = 'This backup is the copy that was REPLACED by the change below.'
        Action         = $Action
        User           = $user
        Machine        = $machine
        SessionStarted = if ($Lock) { [string]$Lock.Started } else { '' }
        ChangedAt      = (Get-Date).ToString('s')
        Files          = @($Files)
    } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Dir $name) -Encoding UTF8
}

function Get-ChangeMarker {
    param([string]$Dir)
    $f = Get-ChildItem $Dir -Filter '*.changed' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { } }
}

function Backup-Tenant {
    param([string]$T, [string]$Action = 'write-back', [string[]]$Files = @(), $Lock)
    $src = Join-Path $script:Cfg.RepoPath $T
    $root = Join-Path (Join-Path $script:Cfg.RepoPath '_backups') $T
    $dest = Join-Path $root (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $null = New-Item -ItemType Directory -Force -Path $dest
    Copy-GamDir $src $dest
    Write-ChangeMarker $dest $Action $Files $Lock
    @(Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -Skip $script:Cfg.BackupCount) |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force }
    $dest
}

function Publish-ToRepo {
    # Snapshot the current repo copy, then swap the new one in via renames so there is never a
    # moment with no good copy.
    param([string]$T, [string]$WorkDir, [string[]]$Files = @(), $Lock)
    $repoDir = Join-Path $script:Cfg.RepoPath $T
    $stage = Join-Path (Join-Path $script:Cfg.RepoPath '_staging') ("$T-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path $stage
    $backup = Backup-Tenant $T 'write-back' $Files $Lock
    Copy-GamDir $WorkDir $stage
    Get-LockFiles $T | Copy-Item -Destination $stage      # lock must survive the folder swap
    if (-not (Test-ManifestEqual (Get-Manifest $WorkDir) (Get-Manifest $stage))) {
        throw "Staged copy for '$T' does not match the working copy; repo left untouched."
    }
    $old = "$stage.old"
    Move-Item $repoDir $old
    try { Move-Item $stage $repoDir } catch { Move-Item $old $repoDir; throw }
    Remove-Item $old -Recurse -Force
    Write-Host "  Auth files changed - repo updated. Previous copy: $backup" -ForegroundColor Green
}

function Complete-Session {
    param([string]$T, [string]$SessionDir)
    $work = Join-Path $SessionDir 'gam'
    $baseFile = Join-Path $SessionDir 'baseline.clixml'
    if ((Test-Path $work) -and (Test-Path $baseFile)) {
        $base = Import-Clixml $baseFile
        $now = Get-Manifest $work
        if (Test-ManifestEqual $base $now) {
            Write-Host '  No auth file changes - repo copy left as is.' -ForegroundColor DarkGray
        } else {
            # The lock still on the tenant is this session's (or, when recovering, the crashed one's),
            # so it names who was actually working when the change happened.
            Publish-ToRepo $T $work (Get-ManifestDiff $base $now) (Get-Lock $T)
        }
    }
    if (Test-Path $SessionDir) { Remove-Item $SessionDir -Recurse -Force }
}

function Start-TenantSession {
    param([string]$T)
    $repoDir = Join-Path $script:Cfg.RepoPath $T
    if (-not (Test-Path $repoDir)) { Write-Warning "No such tenant: $T"; return }

    $lock = Get-Lock $T
    if ($lock) {
        if (Test-LockStale $lock) {
            Write-Warning "Recovering an interrupted session for '$T' (started $($lock.Started))."
            if ($lock.SessionDir) { Complete-Session $T $lock.SessionDir }
            Remove-Lock $T -All
        } else {
            Write-Warning "'$T' is in use by $($lock.User) on $($lock.Machine) since $($lock.Started)."
            return
        }
    }

    $session = Join-Path $script:Cfg.SessionRoot ("$T-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    if (-not (New-Lock $T $session)) { Write-Warning "'$T' was just locked by someone else."; return }

    try {
        $null = New-Item -ItemType Directory -Force -Path $session
        Protect-Dir $session
        $work = Join-Path $session 'gam'
        Copy-GamDir $repoDir $work
        # gamcache isn't copied, but GAM validates its default cache_dir (<GAMCFGDIR>\gamcache) exists.
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $work 'gamcache')
        Set-GamCfgPortable $work
        Get-Manifest $work | Export-Clixml (Join-Path $session 'baseline.clixml')

        $admin = Get-AdminEmail $work
        $q = { param($s) ConvertTo-SingleQuoted $s }
        $boot = @(
            "`$env:GAMCFGDIR = '$(& $q $work)'"
            "`$Host.UI.RawUI.WindowTitle = 'GAM - $(& $q $T)'"
            "if ('$(& $q $script:Cfg.GamDir)' -and (Test-Path '$(& $q $script:Cfg.GamDir)') -and (`$env:Path -notlike '*$(& $q $script:Cfg.GamDir)*')) { `$env:Path = '$(& $q $script:Cfg.GamDir);' + `$env:Path }"
            "Write-Host ('=' * 72) -ForegroundColor Yellow"
            "Write-Host ' GAM SESSION: $(& $q $T)  ($(& $q $admin))' -ForegroundColor Yellow"
            "Write-Host ' This is a temporary working copy of the auth files.' -ForegroundColor Yellow"
            "Write-Host ' CLOSE THIS WINDOW when finished - changes are synced back on close.' -ForegroundColor Yellow"
            "Write-Host ' Do not close the gamswap menu window while this one is open.' -ForegroundColor Yellow"
            "Write-Host ('=' * 72) -ForegroundColor Yellow"
        )
        if ($ChildCommand) { $boot += $ChildCommand; $boot += 'exit' }
        $launch = Join-Path $session 'launch.ps1'
        Set-Content $launch -Value $boot -Encoding UTF8

        $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        $pargs = @('-NoLogo') + $(if (-not $ChildCommand) { '-NoExit' }) + @('-ExecutionPolicy', 'Bypass', '-File', "`"$launch`"")
        $proc = Start-Process $exe -ArgumentList $pargs -PassThru
        $self = Get-Process -Id $PID
        Update-LockProcs $T @(@{ Id = $self.Id; Start = $self.StartTime.Ticks }, @{ Id = $proc.Id; Start = $proc.StartTime.Ticks })

        Write-Host "GAM window opened for '$T'. Waiting for it to close..." -ForegroundColor Cyan
        $proc.WaitForExit()
        Write-Host "GAM window closed. Syncing '$T'..." -ForegroundColor Cyan
        Complete-Session $T $session
    } catch {
        Write-Warning "Session for '$T' failed: $_"
        Write-Warning "Working copy kept at $session; it will be recovered the next time '$T' is launched."
        Update-LockProcs $T @()      # no live processes => treated as stale and recovered next launch
        return
    }
    Remove-Lock $T
    Write-Host "Done with '$T'." -ForegroundColor Green
}

function Add-Tenant {
    param([string]$Name, [string]$Source)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]*$' -or $Name -like '_*') { Write-Warning 'Invalid name (letters, digits, . _ - and spaces; must not start with _).'; return }
    if (-not (Test-Path (Join-Path $Source 'gam.cfg'))) { Write-Warning "No gam.cfg in $Source"; return }
    $dest = Join-Path $script:Cfg.RepoPath $Name
    if (Test-Path $dest) { Write-Warning "Tenant '$Name' already exists."; return }
    $null = New-Item -ItemType Directory -Force -Path $dest
    Copy-GamDir $Source $dest
    Set-GamCfgPortable $dest
    Write-Host "Imported '$Name' ($(Get-AdminEmail $dest))." -ForegroundColor Green
}

function Restore-Tenant {
    param([string]$T)
    if (Get-Lock $T) { Write-Warning "'$T' is locked; can't restore."; return }
    $root = Join-Path (Join-Path $script:Cfg.RepoPath '_backups') $T
    $snaps = @(if (Test-Path $root) { Get-ChildItem $root -Directory | Sort-Object Name -Descending })
    if (-not $snaps) { Write-Warning "No backups for '$T'."; return }
    for ($i = 0; $i -lt $snaps.Count; $i++) {
        $m = Get-ChangeMarker $snaps[$i].FullName
        $who = if ($m) { "  replaced by $($m.User)@$($m.Machine) ($($m.Action)) at $($m.ChangedAt)" } else { '' }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $snaps[$i].Name, $who)
    }
    $pick = Read-Host 'Restore which backup (number, blank to cancel)'
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $snaps.Count) { return }
    if (-not (New-Lock $T '')) { Write-Warning "'$T' was just locked."; return }
    try {
        $chosen = $snaps[[int]$pick - 1].FullName
        $repoDir = Join-Path $script:Cfg.RepoPath $T
        $stage = Join-Path (Join-Path $script:Cfg.RepoPath '_staging') ("$T-restore-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $stage
        Copy-GamDir $chosen $stage
        Get-LockFiles $T | Copy-Item -Destination $stage  # lock must survive the folder swap
        # keep what we're replacing, in case this was a mistake
        $null = Backup-Tenant $T 'restore' @("restored from backup $($snaps[[int]$pick - 1].Name)") (Get-Lock $T)
        Move-Item $repoDir "$stage.old"
        Move-Item $stage $repoDir
        Remove-Item "$stage.old" -Recurse -Force
        Write-Host "Restored '$T' from $($snaps[[int]$pick - 1].Name)." -ForegroundColor Green
    } finally { Remove-Lock $T }
}
#endregion

#region menu
function Show-Menu {
    while ($true) {
        $names = @(Get-TenantNames)     # @() keeps a single tenant an array ($names[0] would be its first letter)
        Write-Host ''
        Write-Host 'GAM tenants' -ForegroundColor Cyan
        for ($i = 0; $i -lt $names.Count; $i++) {
            $d = Join-Path $script:Cfg.RepoPath $names[$i]
            $lk = Get-Lock $names[$i]
            $status = if (-not $lk) { '' } elseif (Test-LockStale $lk) { '  [interrupted - will recover]' } else { "  [in use: $($lk.User)@$($lk.Machine)]" }
            Write-Host ("  [{0}] {1,-24} {2}{3}" -f ($i + 1), $names[$i], (Get-AdminEmail $d), $status)
        }
        if (-not $names) { Write-Host '  (none - use I to import one)' -ForegroundColor DarkGray }
        Write-Host '  [I] Import   [R] Restore backup   [U] Clear a lock   [Q] Quit'
        $c = Read-Host 'Select'
        switch -Regex ($c) {
            '^\d+$' {
                if ([int]$c -ge 1 -and [int]$c -le $names.Count) { Start-TenantSession $names[[int]$c - 1] }
            }
            '^[Ii]$' {
                $n = Read-Host 'Name for this tenant'
                $s = Read-Host "Source GAM config folder [$env:USERPROFILE\.gam]"
                if (-not $s) { $s = Join-Path $env:USERPROFILE '.gam' }
                Add-Tenant $n $s
            }
            '^[Rr]$' {
                $n = Read-Host 'Tenant name to restore'
                if ($names -contains $n) { Restore-Tenant $n }
            }
            '^[Uu]$' {
                $n = Read-Host 'Tenant name whose lock to clear'
                if ($names -contains $n -and (Get-Lock $n)) {
                    if ((Read-Host "Only do this if you are sure no session is running. Type YES") -ceq 'YES') { Remove-Lock $n -All }
                }
            }
            '^[Qq]$' { return }
        }
    }
}
#endregion

if ($MyInvocation.InvocationName -ne '.') {
    Import-GamSwapConfig $ConfigPath
    $null = New-Item -ItemType Directory -Force -Path $script:Cfg.RepoPath
    if ($Tenant) { Start-TenantSession $Tenant } else { Show-Menu }
}
