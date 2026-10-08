# Windows-only (uses robocopy / icacls). Runs the whole tool against a fake tenant in a temp
# folder; nothing here touches a real GAM config.
#   Usage:  pwsh -File tests\Test-GamSwap.ps1        (exit code 1 if any check fails)
$ErrorActionPreference = 'Stop'
$script = (Resolve-Path (Join-Path $PSScriptRoot '..\gamswap.ps1')).Path
$t = Join-Path ([IO.Path]::GetTempPath()) ('gamswap-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $t | Out-Null

@"
@{
    RepoPath = '$t\repo'
    BackupCount = 3
    SessionRoot = '$t\sessions'
    GamDir = ''
}
"@ | Set-Content "$t\test.config.psd1"

# fake source GAM dir
$src = "$t\fakegam"
New-Item -ItemType Directory "$src\gamcache" | Out-Null
"[DEFAULT]`nadmin_email = admin@acme.test`nconfig_dir = C:\Users\nobody\.gam`ncache_dir = C:\Users\nobody\.gam\gamcache`noauth2_txt = oauth2.txt" | Set-Content "$src\gam.cfg"
'token-v1' | Set-Content "$src\oauth2.txt"
'{"key":"x"}' | Set-Content "$src\oauth2service.json"
'cache' | Set-Content "$src\gamcache\junk.bin"

. $script -ConfigPath "$t\test.config.psd1"
Import-GamSwapConfig "$t\test.config.psd1"
$ok = 0; $bad = 0
function Check($name, $cond) { if ($cond) { $script:ok++; Write-Host "PASS $name" -ForegroundColor Green } else { $script:bad++; Write-Host "FAIL $name" -ForegroundColor Red } }

# 1 import
Add-Tenant 'acme' $src
$r = "$t\repo\acme"
Check 'import copies files' ((Test-Path "$r\oauth2.txt") -and (Test-Path "$r\oauth2service.json"))
Check 'import excludes gamcache' (-not (Test-Path "$r\gamcache"))
Check 'import strips config_dir/cache_dir' (-not (Select-String "$r\gam.cfg" -Pattern '^(config_dir|cache_dir)'))
Check 'admin_email read' ((Get-AdminEmail $r) -eq 'admin@acme.test')
Check 'tenant listed' ((Get-TenantNames) -contains 'acme')

# drive the real menu with scripted input (shadow Read-Host); a single tenant guards against the
# one-item-array unwrap bug where $names[0] became the first letter of the name
$script:inputs = [System.Collections.Queue]::new(@('1', 'q'))
function Read-Host { param($Prompt) $script:inputs.Dequeue() }
$ChildCommand = "'launched' | Set-Content '$t\menu-launch.txt'"
$menuOut = Show-Menu *>&1 | Out-String
Remove-Item Function:\Read-Host
Check 'menu lists full tenant name, not first letter' ($menuOut -match '\[1\] acme\s')
Check 'menu choice 1 launches the single tenant' (Test-Path "$t\menu-launch.txt")

# 2 unchanged session
$ChildCommand = "`$env:GAMCFGDIR | Set-Content '$t\gamcfgdir.txt'; (Test-Path `"`$env:GAMCFGDIR\gam.cfg`").ToString() | Add-Content '$t\gamcfgdir.txt'; (Get-ChildItem '$r' -Filter *.lock | ForEach-Object Name) | Set-Content '$t\lockname.txt'; (Test-Path `"`$env:GAMCFGDIR\*.lock`").ToString() | Set-Content '$t\lock-in-work.txt'; (Test-Path `"`$env:GAMCFGDIR\gamcache`" -PathType Container).ToString() | Set-Content '$t\gamcache-in-work.txt'"
Start-TenantSession 'acme'
Check 'working copy has an (empty) gamcache dir so GAM does not warn Invalid Path' ((Get-Content "$t\gamcache-in-work.txt") -eq 'True')
Check 'empty gamcache dir is not treated as a change / not written to repo' (-not (Test-Path "$r\gamcache"))
Check 'lock file visible in tenant dir DURING session, named user.host.lock' ((Get-Content "$t\lockname.txt") -eq "$env:USERNAME.$env:COMPUTERNAME.lock")
Check 'lock not copied into working copy' ((Get-Content "$t\lock-in-work.txt") -eq 'False')
Check 'lock file DELETED after window closes' (-not (Get-ChildItem $r -Filter *.lock))
$seen = (Get-Content "$t\gamcfgdir.txt")[0]
Check 'child window saw GAMCFGDIR in session dir' ($seen -like "$t\sessions\acme-*\gam")
Check 'child saw gam.cfg there' ((Get-Content "$t\gamcfgdir.txt")[1] -eq 'True')
Check 'no backup when unchanged' (-not (Test-Path "$t\repo\_backups\acme"))
Check 'session dir removed' (-not (Test-Path "$t\sessions") -or -not (Get-ChildItem "$t\sessions"))
Check 'lock released' (-not (Get-Lock 'acme'))

# 3 changed session
$ChildCommand = "Add-Content `"`$env:GAMCFGDIR\oauth2.txt`" 'token-v2'"
Start-TenantSession 'acme'
Check 'lock deleted after a session that wrote changes back' (-not (Get-ChildItem $r -Filter *.lock))
Check 'repo got updated token' ((Get-Content "$r\oauth2.txt" -Raw) -match 'token-v2')
Check 'one backup made' (@(Get-ChildItem "$t\repo\_backups\acme").Count -eq 1)
$bk = (Get-ChildItem "$t\repo\_backups\acme")[0].FullName
Check 'backup content is v1' (((Get-Content "$bk\oauth2.txt" -Raw) -match 'token-v1') -and -not ((Get-Content "$bk\oauth2.txt" -Raw) -match 'token-v2'))
$mk = Get-ChildItem $bk -Filter *.changed
Check 'backup has a user.host.changed marker' (($mk.Count -eq 1) -and ($mk.Name -eq "$env:USERNAME.$env:COMPUTERNAME.changed"))
$mj = Get-Content $mk.FullName -Raw | ConvertFrom-Json
Check 'marker records who/where/action' (($mj.User -eq "$env:USERDOMAIN\$env:USERNAME") -and ($mj.Machine -eq $env:COMPUTERNAME) -and ($mj.Action -eq 'write-back'))
Check 'marker records session start from lock (ISO, on disk)' ((Get-Content $mk.FullName -Raw) -match '"SessionStarted":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d"')
Check 'marker lists changed file by name' (@($mj.Files) -contains 'modified: oauth2.txt')
Check 'marker does not leak into live copy' (-not (Get-ChildItem $r -Filter *.changed -Recurse))
Check 'marker is not counted as a change (manifest ignores it)' (-not (Get-Manifest $bk).ContainsKey("$env:USERNAME.$env:COMPUTERNAME.changed"))
Check 'repo gam.cfg still stripped' (-not (Select-String "$r\gam.cfg" -Pattern '^(config_dir|cache_dir)'))
Check 'no staging leftovers' (-not (Test-Path "$t\repo\_staging") -or -not (Get-ChildItem "$t\repo\_staging"))

# 4 pruning
foreach ($i in 3..7) {
    $ChildCommand = "Add-Content `"`$env:GAMCFGDIR\oauth2.txt`" 'token-v$i'"
    Start-Sleep -Milliseconds 20
    Start-TenantSession 'acme'
}
Check 'backups pruned to 3' (@(Get-ChildItem "$t\repo\_backups\acme").Count -eq 3)

# 5 lock held by someone else
@{ Tenant = 'acme'; User = 'CORP\bob'; Machine = 'OTHERBOX'; Started = '2026-10-08T09:00:00'; SessionDir = ''; Procs = @() } |
    ConvertTo-Json | Set-Content "$r\bob.OTHERBOX.lock"
$before = (Get-Content "$r\oauth2.txt" -Raw)
$ChildCommand = "Add-Content `"`$env:GAMCFGDIR\oauth2.txt`" 'should-not-happen'"
Start-TenantSession 'acme' 3>$null
Check 'foreign lock refuses launch' ((Get-Content "$r\oauth2.txt" -Raw) -eq $before)
Check 'foreign lock is left alone by the refused launch' (Test-Path "$r\bob.OTHERBOX.lock")
Check 'foreign lock is not "stale" (other machine)' (-not (Test-LockStale (Get-Lock 'acme')))
Check 'New-Lock refuses while a lock exists' (-not (New-Lock 'acme' ''))
Remove-Lock 'acme' -All
Check 'Remove-Lock -All clears foreign lock' (-not (Get-ChildItem $r -Filter *.lock))

# 5b lock survives the folder swap on write-back, and does not leak into backups
Check 'New-Lock succeeds when free' (New-Lock 'acme' '')
Check 'second New-Lock by same user/host refused' (-not (New-Lock 'acme' ''))
$sw = "$t\swaptest"; Copy-GamDir $r "$sw\gam"; New-Item -ItemType Directory $sw -Force | Out-Null
Add-Content "$sw\gam\oauth2.txt" 'swap-change'
Publish-ToRepo 'acme' "$sw\gam" | Out-Null
Check 'lock still present after swap' (Test-Path (Get-OwnLockPath 'acme'))
Check 'no .lock in any backup' (-not (Get-ChildItem "$t\repo\_backups\acme" -Recurse -Filter *.lock))
Remove-Lock 'acme'
Check 'own Remove-Lock deletes it' (-not (Get-ChildItem $r -Filter *.lock))

# 6 crash recovery: lock + leftover session dir with a changed file, no live pids
$sess = "$t\sessions\acme-crashed"
New-Item -ItemType Directory $sess | Out-Null
Copy-GamDir $r "$sess\gam"
Get-Manifest "$sess\gam" | Export-Clixml "$sess\baseline.clixml"
Add-Content "$sess\gam\oauth2.txt" 'token-from-crashed-session'
New-Lock 'acme' $sess | Out-Null
Update-LockProcs 'acme' @(@{ Id = 999999; Start = 1 })
# make the crashed session belong to someone else on this machine (terminal-server style)
$lp = Get-OwnLockPath 'acme'; $lj = Get-Content $lp -Raw | ConvertFrom-Json; $lj.User = 'CORP\carol'
$lj | ConvertTo-Json -Depth 4 | Set-Content $lp
Check 'lock detected stale' (Test-LockStale (Get-Lock 'acme'))
$ChildCommand = "'ok' | Set-Content '$t\after-recover.txt'"
Start-TenantSession 'acme' 3>$null
Check 'crashed changes recovered into repo' ((Get-Content "$r\oauth2.txt" -Raw) -match 'token-from-crashed-session')
Check 'crashed session dir cleaned' (-not (Test-Path $sess))
$newest = Get-ChildItem "$t\repo\_backups\acme" -Directory | Sort-Object Name -Descending | Select-Object -First 1
$cm = Get-ChildItem $newest.FullName -Filter *.changed
Check 'recovery marker names the crashed session owner, not the recoverer' ($cm.Name -eq "carol.$env:COMPUTERNAME.changed")
Check 'launch proceeded after recovery' (Test-Path "$t\after-recover.txt")
Check 'no lock left after recovery + launch' (-not (Get-ChildItem $r -Filter *.lock))

# 7 restore: newest backup comes back, restore itself is recorded, markers never enter the live copy
$newest = Get-ChildItem "$t\repo\_backups\acme" -Directory | Sort-Object Name -Descending | Select-Object -First 1
$want = Get-Content "$newest\oauth2.txt" -Raw
$script:inputs = [System.Collections.Queue]::new(@('1'))
function Read-Host { param($Prompt) $script:inputs.Dequeue() }
$restoreOut = Restore-Tenant 'acme' *>&1 | Out-String
Remove-Item Function:\Read-Host
Check 'restore listing shows who replaced each backup' ($restoreOut -match 'replaced by .+@.+ \(write-back\)')
Check 'restore put the chosen backup back' ((Get-Content "$r\oauth2.txt" -Raw) -eq $want)
Check 'no .changed leaked into live copy via restore' (-not (Get-ChildItem $r -Filter *.changed -Recurse))
$rb = Get-ChildItem "$t\repo\_backups\acme" -Directory | Sort-Object Name -Descending | Select-Object -First 1
$rm = Get-ChildItem $rb.FullName -Filter *.changed | Get-Content -Raw | ConvertFrom-Json
Check 'restore itself recorded (action=restore, names source backup)' (($rm.Action -eq 'restore') -and ((@($rm.Files) -join ' ') -match $newest.Name))
Check 'no lock left after restore' (-not (Get-ChildItem $r -Filter *.lock))

Write-Host "`n$ok passed, $bad failed"
Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
if ($bad) { exit 1 }
