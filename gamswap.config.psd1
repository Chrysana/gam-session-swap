@{
    # Folder holding one sub-folder per tenant (each is a full GAM config dir).
    # Point this at the secured share for real use. Relative paths resolve against this file.
    RepoPath    = '.\repo'

    # How many pre-session snapshots to keep per tenant.
    BackupCount = 3

    # Where per-session working copies live. Keep this on local disk. %VARS% are expanded.
    SessionRoot = '%LOCALAPPDATA%\gamswap\sessions'

    # Folder containing gam.exe; prepended to PATH in the GAM window if it isn't already there.
    GamDir      = 'C:\GAM7'
}
