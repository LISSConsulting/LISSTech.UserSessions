# LISSTech.UserSessions — profile snippet
# -----------------------------------------------------------------------------
# Copy the relevant block into your PowerShell profile ($PROFILE) to set
# persistent defaults for Show-UserSession and Find-UserSession without
# hard-coding client-specific values into the module itself.
#
# To edit your profile:
#   if (-not (Test-Path $PROFILE)) { New-Item $PROFILE -ItemType File -Force }
#   notepad $PROFILE
#
# After editing, reload:
#   . $PROFILE
# -----------------------------------------------------------------------------

# --- Example: client-specific OU defaults --------------------------------------
# Uncomment and adjust the OUs for your environment.

# $clientOUs = @(
#     'OU=Admin Accounts,OU=MyClient,DC=example,DC=com'
#     'OU=Standard Users,OU=MyClient,DC=example,DC=com'
# )
# $PSDefaultParameterValues['Show-UserSession:UserSearchBase'] = $clientOUs
# $PSDefaultParameterValues['Find-UserSession:UserSearchBase'] = $clientOUs

# --- Example: restrict scans to Windows Servers only -------------------------
# $PSDefaultParameterValues['Show-UserSession:ComputerLdapFilter'] = '(operatingSystem=*Windows*Server*)'
# $PSDefaultParameterValues['Find-UserSession:ComputerLdapFilter'] = '(operatingSystem=*Windows*Server*)'

# --- Example: crank up throttle on a beefy workstation -----------------------
# $PSDefaultParameterValues['Show-UserSession:ThrottleLimit'] = 64
# $PSDefaultParameterValues['Find-UserSession:ThrottleLimit'] = 64
