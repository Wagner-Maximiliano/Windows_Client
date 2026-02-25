# Auto-add the primary (most recently used) DOMAIN user profile as local admin, by SID.
# No AD / LDAP queries. Uses local profile data only.

$ErrorActionPreference = "Stop"

# Resolve local Administrators group name via SID (works on non-English OS)
$adminsGroup = (Get-LocalGroup -SID "S-1-5-32-544").Name

# Registry path to track last assigned admin SID (so we can remove if it changes)
$regPath = "HKLM:\SOFTWARE\Company\PrimaryUserLocalAdmin"
New-Item -Path $regPath -Force | Out-Null
$prevSid = (Get-ItemProperty -Path $regPath -Name "AssignedSid" -ErrorAction SilentlyContinue).AssignedSid

# Collect local user profiles
$profiles = Get-CimInstance Win32_UserProfile |
    Where-Object {
        $_.Special -eq $false -and
        $_.LocalPath -like "C:\Users\*" -and
        $_.SID -match '^S-1-5-21-'  # domain/AD user SID pattern (and domain-joined local users)
    }

if (-not $profiles) { return }

# Exclude local machine accounts by checking if a local account exists with same SID (rare but safe)
# Also exclude built-in / service-ish profile folders just in case
$profiles = $profiles | Where-Object {
    $_.LocalPath -notmatch '\\(Default|Default User|Public|All Users|Administrator)$'
}

# Pick the most recently used profile
$primary = $profiles | Sort-Object -Property LastUseTime -Descending | Select-Object -First 1
if (-not $primary -or -not $primary.SID) { return }

$primarySid = $primary.SID

# Get current Admins (SID list)
$currentAdminSids = @()
try {
    $currentAdminSids = Get-LocalGroupMember -Group $adminsGroup -ErrorAction Stop |
        ForEach-Object { $_.SID.Value }
} catch {
    # If Get-LocalGroupMember fails in some edge cases, just proceed to add attempt below
}

# If primary already admin, just update registry and exit
if ($currentAdminSids -contains $primarySid) {
    Set-ItemProperty -Path $regPath -Name "AssignedSid" -Value $primarySid -Force
    return
}

# Remove previously assigned SID if different (prevents users becoming admin on machines they no longer "own")
if ($prevSid -and $prevSid -ne $primarySid) {
    try { Remove-LocalGroupMember -Group $adminsGroup -Member $prevSid -ErrorAction Stop } catch {}
}

# Add primary user by SID (no need to resolve DOMAIN\user)
Add-LocalGroupMember -Group $adminsGroup -Member $primarySid

# Persist what we assigned
Set-ItemProperty -Path $regPath -Name "AssignedSid" -Value $primarySid -Force
