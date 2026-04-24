# -----------------------------------------------------------------------------
# Thin wrapper over System.DirectoryServices.DirectorySearcher so we don't
# need the ActiveDirectory RSAT module. Ships with .NET; runs anywhere
# that can reach a DC.
#
# Exposes:
#   Search-DirectoryUser      → [pscustomobject]{ Sam, IsDisabled } per user
#   Search-DirectoryComputer  → [pscustomobject]{ Name } per enabled host
# -----------------------------------------------------------------------------

function Get-DefaultNamingContext {
    <#
        Returns the current forest's default naming context by reading
        RootDSE on the nearest DC. Used when no -SearchBase is given.
    #>
    [CmdletBinding()]
    param()

    Write-Debug 'Search-Directory → binding to RootDSE for default naming context'
    $rootDse = [ADSI]'LDAP://RootDSE'
    return [string]$rootDse.defaultNamingContext
}

function Convert-DnToLdapUri {
    <#
        Turns an AD distinguished name into the LDAP:// URI that ADSI expects.
        The DN is passed straight through — callers must provide already-
        escaped DNs (e.g. OUs containing '#' already use '\#').
    #>
    param([string]$DistinguishedName)

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        throw 'DistinguishedName cannot be empty.'
    }

    return "LDAP://$DistinguishedName"
}

function Test-UacDisabled {
    <#
        Returns $true if the userAccountControl value has the
        ACCOUNTDISABLE bit (0x0002) set.
    #>
    param([int]$Uac)
    return (($Uac -band 0x2) -ne 0)
}

function Search-DirectoryUser {
    <#
    .SYNOPSIS
        Returns one object per user under a given OU DN, carrying the
        SAM account name and an IsDisabled flag.

    .DESCRIPTION
        Uses DirectorySearcher with objectCategory=person + objectClass=user.
        Paging is enabled via PageSize so domains with 1000+ users return
        everything, not just the first page.

        The IsDisabled flag is derived from the ACCOUNTDISABLE bit (0x0002)
        of userAccountControl. Disabled accounts are INCLUDED in results —
        disabling an account does not tear down its existing Kerberos
        session, so finding sessions for disabled users is a valuable
        signal (offboarding gaps, incident response, license reclamation).

    .EXAMPLE
        Search-DirectoryUser -SearchBase 'OU=Staff,DC=example,DC=com'

    .OUTPUTS
        [pscustomobject] with properties:
            Sam         [string]   SAM account name
            IsDisabled  [bool]     true when ACCOUNTDISABLE is set
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SearchBase
    )

    $root     = $null
    $searcher = $null

    try {
        $root = New-Object System.DirectoryServices.DirectoryEntry (Convert-DnToLdapUri $SearchBase)

        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot  = $root
        $searcher.Filter      = '(&(objectCategory=person)(objectClass=user))'
        $searcher.PageSize    = 1000
        $searcher.SearchScope = 'Subtree'
        foreach ($prop in 'sAMAccountName', 'userAccountControl') {
            [void]$searcher.PropertiesToLoad.Add($prop)
        }

        Write-Debug "Search-DirectoryUser → searching $SearchBase"

        $results = $searcher.FindAll()
        try {
            foreach ($entry in $results) {
                $samRaw = $entry.Properties['samaccountname']
                if (-not $samRaw -or $samRaw.Count -eq 0 -or -not $samRaw[0]) { continue }

                $uacRaw = $entry.Properties['useraccountcontrol']
                $uac = if ($uacRaw -and $uacRaw.Count -gt 0) { [int]$uacRaw[0] } else { 0 }

                [pscustomobject]@{
                    Sam        = [string]$samRaw[0]
                    IsDisabled = Test-UacDisabled -Uac $uac
                }
            }
        } finally {
            $results.Dispose()
        }
    } catch [System.Runtime.InteropServices.COMException] {
        throw "LDAP query failed against '$SearchBase': $($_.Exception.Message). (Is the DN correct and the DC reachable?)"
    } finally {
        if ($searcher) { $searcher.Dispose() }
        if ($root)     { $root.Dispose() }
    }
}

function Search-DirectoryComputer {
    <#
    .SYNOPSIS
        Returns [pscustomobject]{ Name } for every enabled computer object
        matching an optional LDAP filter.

    .DESCRIPTION
        Wraps the user-supplied filter with objectCategory=computer and
        filters out disabled accounts using the ACCOUNTDISABLE bit (0x2)
        of userAccountControl.

        Default is no extra filter — all enabled domain-joined computers.
        Use -Filter to narrow (e.g. servers only).

    .PARAMETER Filter
        Optional LDAP filter fragment that will be AND-ed with
        objectCategory=computer.

    .PARAMETER SearchBase
        OU DN to search under. Defaults to the forest's default naming
        context (read from RootDSE).

    .EXAMPLE
        Search-DirectoryComputer -Filter '(operatingSystem=*Windows*Server*)'

    .EXAMPLE
        Search-DirectoryComputer    # every enabled computer in the domain
    #>
    [CmdletBinding()]
    param(
        [string]$Filter,
        [string]$SearchBase
    )

    if (-not $SearchBase) {
        $SearchBase = Get-DefaultNamingContext
        Write-Debug "Search-DirectoryComputer → defaulting SearchBase to $SearchBase"
    }

    $ldapFilter = switch ([string]::IsNullOrWhiteSpace($Filter)) {
        $true  { '(objectCategory=computer)' }
        $false { "(&(objectCategory=computer)$Filter)" }
    }

    Write-Debug "Search-DirectoryComputer → filter=$ldapFilter base=$SearchBase"

    $root     = $null
    $searcher = $null

    try {
        $root = New-Object System.DirectoryServices.DirectoryEntry (Convert-DnToLdapUri $SearchBase)

        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot  = $root
        $searcher.Filter      = $ldapFilter
        $searcher.PageSize    = 1000
        $searcher.SearchScope = 'Subtree'
        foreach ($prop in 'name', 'userAccountControl') {
            [void]$searcher.PropertiesToLoad.Add($prop)
        }

        $results = $searcher.FindAll()
        try {
            foreach ($entry in $results) {
                $uacRaw = $entry.Properties['useraccountcontrol']
                $uac    = if ($uacRaw -and $uacRaw.Count -gt 0) { [int]$uacRaw[0] } else { 0 }

                if (Test-UacDisabled -Uac $uac) { continue }

                $nameRaw = $entry.Properties['name']
                if (-not $nameRaw -or $nameRaw.Count -eq 0) { continue }

                [pscustomobject]@{ Name = [string]$nameRaw[0] }
            }
        } finally {
            $results.Dispose()
        }
    } catch [System.Runtime.InteropServices.COMException] {
        throw "LDAP computer query failed: $($_.Exception.Message). (Is this host domain-joined and the DC reachable?)"
    } finally {
        if ($searcher) { $searcher.Dispose() }
        if ($root)     { $root.Dispose() }
    }
}
