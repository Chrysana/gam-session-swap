# gam-session-swap

Swap between per-client [GAM](https://github.com/GAM-team/GAM) (GAMADV-X / GAM7) configurations from one PowerShell menu — for admins who manage several Google Workspace tenants.

Each client's GAM config directory (`gam.cfg`, `oauth2.txt`, `oauth2service.json`, `client_secrets.json`, …) is stored in a central repository folder. Picking a client opens a **new PowerShell window** wired to a private working copy of that client's config. When you close the window, any changes to the auth files are written back, with a backup and an audit marker.

> **Status: proof of concept.** Windows only. Tested end to end against fake tenants (see [Tests](#tests)); try it on a non-critical tenant before relying on it.

## Why not just copy `~\.gam` around?

- Only one client at a time, and a crash can leave one client's credentials sitting in `~\.gam`.
- Nobody can tell who is using a client, and two people can overwrite each other's token refreshes.
- No rollback if someone breaks auth.

## How it works

1. **Lock** — a `<username>.<hostname>.lock` file appears in the client's folder, so anyone browsing the share can see who is working on it. Others are refused while it exists.
2. **Working copy** — the client folder is copied to a private local folder (`gamcache` excluded, ACL restricted to you).
3. **GAM window** — a new PowerShell window opens with `GAMCFGDIR` pointing at that copy and a banner telling you to close it when finished.
4. **On close** — file hashes are compared with the baseline. If nothing changed, nothing else happens. If something did:
   - the current repo copy is snapshotted to `_backups\<client>\<timestamp>\` (last *N* kept),
   - a `<username>.<hostname>.changed` file in that backup records who was working when it changed, when, and which files (names only),
   - the working copy is swapped in via renames, so there's never a moment without a good copy.
5. The working copy is deleted and the lock removed. The menu window stays open.

If a window or machine dies mid-session, the next launch of that client detects the dead lock and recovers the working copy first (the `.changed` marker names the original user).

### A GAM gotcha this tool handles

`GAMCFGDIR` only tells GAM where to find `gam.cfg`. If that file contains an absolute `config_dir` (and `cache_dir`), GAM resolves the credential files relative to *that* instead, silently ignoring your working copy. The tool strips those two lines on import and on every working copy so GAM derives them from `GAMCFGDIR`.

## Requirements

- Windows, PowerShell 5.1+ (PowerShell 7 recommended). Uses `robocopy` and `icacls`.
- [GAM7](https://github.com/GAM-team/GAM) already set up for each client (this tool manages config directories; it does not run GAM's setup for you).

## Quick start

```powershell
# 1. Edit gamswap.config.psd1 — at minimum point RepoPath somewhere sensible (see Security)
# 2. Run the menu
.\gamswap.ps1

# Import an existing GAM config as a client:  I  ->  name  ->  source folder (default ~\.gam)
# Launch a client:                            type its number
# Launch directly, no menu:                   .\gamswap.ps1 -Tenant Acme
```

Menu: `[number]` launch · `[I]` import · `[R]` restore a backup (lists who replaced each one) · `[U]` clear a lock · `[Q]` quit.

## Configuration (`gamswap.config.psd1`)

| Key | Meaning |
|---|---|
| `RepoPath` | Folder with one subfolder per client. Relative paths resolve against the config file. Point at a secured share for team use. |
| `BackupCount` | Snapshots kept per client (default 3). |
| `SessionRoot` | Where working copies live. Keep on local disk. `%VARS%` expanded. |
| `GamDir` | Folder containing `gam.exe`; prepended to `PATH` in the GAM window if missing. |

### Repository layout

```
<RepoPath>\
  Acme\                           one client = a full GAM config dir
    gam.cfg  oauth2.txt  oauth2service.json  client_secrets.json
    alice.WORKSTATION1.lock       present only while someone is working
  _backups\Acme\20261008-150858-349\
    ...the copy that was replaced...
    alice.WORKSTATION1.changed    who/when/what replaced it
  _staging\                       transient, used during write-back
```

## Security notes

- Client folders contain live credentials, including a service-account private key. **Never commit them** — `.gitignore` excludes `repo/` and common GAM credential filenames as a safety net.
- For team use, put `RepoPath` on a share and restrict each client folder with NTFS/share permissions (e.g. per-client AD groups). The tenant menu only lists folders the user can read.
- Locks and markers are advisory: anyone with write access to a client folder can create or delete them. They prevent mistakes, not misuse.
- Working copies are ACL-restricted to the current user and deleted on exit (or on recovery after a crash).

## Known limitations

- If the menu window is closed while a GAM window is still open, the sync happens at the next launch of that client (and only once the GAM window is gone).
- A lock held by another machine is never auto-treated as stale; use `[U]` after confirming nobody is running a session.
- No audit log beyond the backup markers, no read-only mode, no lock heartbeat yet.
- Credentials are not encrypted at rest beyond filesystem permissions.

## Tests

```powershell
pwsh -File tests\Test-GamSwap.ps1
```

Drives the real script (menu, launch, locking, write-back, pruning, crash recovery, restore) against a fake tenant in a temp folder. It never touches a real GAM config. Exits non-zero on failure.

## License

MIT — see [LICENSE](LICENSE).
