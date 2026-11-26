function Invoke-ExecDataResidency {
    <#
    .FUNCTIONALITY
        Entrypoint,TenantGroup
    .ROLE
        Tenant.Administration.ReadWrite
    .DESCRIPTION
        oneICT customisation (Item 230): actions for the 'Datenresidenz Schweiz' view (setting "Store Microsoft 365 customer data in-country", deadline 14.12.2026). Action=Measure reads the Message Center posts MC1470878/MC1470876 and the tenant country for one tenant, a tenant group or AllTenants and stores the factory default; it changes nothing in the tenants. All other actions need a single tenant. Action=Confirm records the state a technician saw in the Admin Center (On/Off) with a note. Action=PrepareJIT creates a time-limited Global Administrator JIT admin with a Temporary Access Pass through ExecJITAdmin, because Microsoft only lets a Global Administrator change the setting and offers no API for it. Action=ClearConfirmation removes a recorded confirmation.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $Action = [string]($Request.Body.Action.value ?? $Request.Body.Action)
    # A tenant group comes in as Query.tenantFilter=AllTenants (router-normalised, scope already narrowed to the group)
    $TenantFilter = [string]($Request.Body.tenantFilter.value ?? $Request.Body.tenantFilter ?? $Request.Query.tenantFilter)
    $Table = Get-CIPPTable -tablename 'oneICTDataResidency'
    $CallingUser = try {
        ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Headers.'x-ms-client-principal')) | ConvertFrom-Json).userDetails
    } catch { [string]$Headers.'x-ms-client-principal-name' }

    $Respond = {
        param($StatusCode, $Results)
        [HttpResponseContext]@{ StatusCode = $StatusCode; Body = @{ Results = @($Results) } }
    }

    if ([string]::IsNullOrWhiteSpace($TenantFilter)) {
        return (& $Respond ([HttpStatusCode]::BadRequest) 'tenantFilter is required.')
    }
    if ($TenantFilter -eq 'AllTenants' -and $Action -ne 'Measure') {
        return (& $Respond ([HttpStatusCode]::BadRequest) "Action '$Action' changes one tenant at a time. Pick a single tenant.")
    }

    $Tenants = @(if ($TenantFilter -eq 'AllTenants') { Get-Tenants } else { Get-Tenants -TenantFilter $TenantFilter })
    if ($Tenants.Count -eq 0) {
        return (& $Respond ([HttpStatusCode]::NotFound) "Tenant $TenantFilter not found.")
    }

    try {
        switch ($Action) {
            'Measure' {
                $Measured = @(Update-CIPPDataResidencyMeasurement -Tenants $Tenants)
                $Summary = $Measured | Group-Object -Property DefaultState | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }
                Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Data residency measured for $($Measured.Count) tenant(s): $($Summary -join ', ')" -Sev 'Info'
                if ($Measured.Count -eq 1) {
                    $One = $Measured[0]
                    $Text = switch ($One.DefaultState) {
                        'Off' { 'MC1470878 found: setting is OFF by default - switch it on before 14.12.2026.' }
                        'On' { 'MC1470876 found: setting is ON by default - check it once in the Admin Center.' }
                        'None' { 'Neither post found: factory default unknown. Check the setting in the Admin Center.' }
                        default { "Could not measure: $($One.MeasureError)" }
                    }
                    return (& $Respond ([HttpStatusCode]::OK) "$($Tenants[0].displayName): $Text")
                }
                return (& $Respond ([HttpStatusCode]::OK) "Measured $($Measured.Count) tenants. $($Summary -join ', ')")
            }
            'Confirm' {
                $State = [string]($Request.Body.ConfirmedState.value ?? $Request.Body.ConfirmedState)
                if ($State -notin @('On', 'Off')) {
                    return (& $Respond ([HttpStatusCode]::BadRequest) 'ConfirmedState must be On or Off.')
                }
                $Tenant = $Tenants[0]
                $Note = [string]$Request.Body.Note
                if ($Note.Length -gt 1000) { $Note = $Note.Substring(0, 1000) }
                Add-CIPPAzDataTableEntity @Table -OperationType 'UpsertMerge' -Entity @{
                    PartitionKey      = 'Tenant'
                    RowKey            = [string]$Tenant.customerId
                    defaultDomainName = [string]$Tenant.defaultDomainName
                    displayName       = [string]$Tenant.displayName
                    ConfirmedState    = $State
                    ConfirmedBy       = [string]$CallingUser
                    ConfirmedAt       = (Get-Date).ToUniversalTime()
                    Note              = $Note
                }
                $Label = if ($State -eq 'On') { 'ON (data stored in the tenant geography)' } else { 'OFF (customer decision)' }
                Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -message "Data residency confirmed as $Label by $CallingUser. $Note" -Sev 'Info'
                return (& $Respond ([HttpStatusCode]::OK) "Recorded for $($Tenant.displayName): $Label.")
            }
            'ClearConfirmation' {
                $Tenant = $Tenants[0]
                Add-CIPPAzDataTableEntity @Table -OperationType 'UpsertMerge' -Entity @{
                    PartitionKey   = 'Tenant'
                    RowKey         = [string]$Tenant.customerId
                    ConfirmedState = ''
                    ConfirmedBy    = [string]$CallingUser
                    ConfirmedAt    = (Get-Date).ToUniversalTime()
                    Note           = 'Confirmation cleared'
                }
                Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -message "Data residency confirmation cleared by $CallingUser" -Sev 'Info'
                return (& $Respond ([HttpStatusCode]::OK) "Confirmation cleared for $($Tenant.displayName).")
            }
            'PrepareJIT' {
                $Tenant = $Tenants[0]
                $Hours = [int]($Request.Body.Hours ?? 4)
                if ($Hours -lt 1 -or $Hours -gt 8) { $Hours = 4 }
                $Domain = [string]($Tenant.initialDomainName ?? $Tenant.defaultDomainName)
                $Suffix = -join ((48..57) + (97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
                $Now = [DateTimeOffset]::UtcNow
                # Same body the JIT Admin page sends, so ExecJITAdmin applies the caller's JIT role template,
                # the maximum duration and any approval requirement exactly as it does in the UI.
                $JitBody = [pscustomobject]@{
                    tenantFilter     = [string]$Tenant.defaultDomainName
                    userAction       = 'create'
                    FirstName        = 'oneICT'
                    LastName         = 'Datenresidenz'
                    Username         = "oneict-dr-$Suffix"
                    Domain           = $Domain
                    usageLocation    = 'CH'
                    AdminRoles       = @([pscustomobject]@{ label = 'Global Administrator'; value = '62e90394-69f5-4237-9190-012177145e10' })
                    GroupMemberships = @()
                    StartDate        = [string]$Now.ToUnixTimeSeconds()
                    EndDate          = [string]$Now.AddHours($Hours).ToUnixTimeSeconds()
                    ExpireAction     = [pscustomobject]@{ label = 'Delete User'; value = 'DeleteUser' }
                    UseTAP           = $true
                    Reason           = 'Datenresidenz Schweiz: Store Microsoft 365 customer data in-country (Item 230)'
                    PostExecution    = @()
                }
                $JitRequest = [pscustomobject]@{
                    Params  = [pscustomobject]@{ CIPPEndpoint = 'ExecJITAdmin' }
                    Headers = $Headers
                    Body    = $JitBody
                    Query   = [pscustomobject]@{}
                }
                # This endpoint only needs Tenant.Administration.ReadWrite; creating a Global Administrator needs
                # what ExecJITAdmin needs (Identity.Role.ReadWrite, tenant access, role blocks). Check it the way
                # the router would, so this action never widens who can create a JIT admin.
                try {
                    $null = Test-CIPPAccess -Request $JitRequest
                } catch {
                    Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -message "Data residency JIT admin refused for $($CallingUser): $($_.Exception.Message)" -Sev 'Warning'
                    return (& $Respond ([HttpStatusCode]::Forbidden) "Not allowed to create a JIT admin: $($_.Exception.Message)")
                }
                $JitResponse = Invoke-ExecJITAdmin -Request $JitRequest -TriggerMetadata $TriggerMetadata
                $JitResults = @($JitResponse.Body.Results)
                $Upn = '{0}@{1}' -f $JitBody.Username, $Domain
                $Created = [int]$JitResponse.StatusCode -lt 300 -and ($JitResults | Where-Object { $_.resultText -like 'Created User:*' })
                if ($Created) {
                    # The account and its credentials exist now and are shown only once: a failure to remember the
                    # JIT admin here must not turn this into an error (a retry would create a second admin).
                    try {
                        Add-CIPPAzDataTableEntity @Table -OperationType 'UpsertMerge' -Entity @{
                            PartitionKey      = 'Tenant'
                            RowKey            = [string]$Tenant.customerId
                            defaultDomainName = [string]$Tenant.defaultDomainName
                            displayName       = [string]$Tenant.displayName
                            JITUser           = $Upn
                            JITExpires        = $Now.AddHours($Hours).UtcDateTime
                            JITCreatedBy      = [string]$CallingUser
                        }
                    } catch {
                        Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant.defaultDomainName -message "JIT admin $Upn created, but storing it for the data residency view failed: $($_.Exception.Message)" -Sev 'Warning'
                        $JitResults += "Warning: JIT admin $Upn was created, but the data residency view could not record it. Do not run this again; use the credentials above."
                    }
                    $Link = 'https://admin.cloud.microsoft/?login_hint={0}#/Settings/OrganizationProfile/:/Settings/L1/DataLocation' -f [uri]::EscapeDataString($Upn)
                    $HasTap = [bool]($JitResults | Where-Object { $_.resultText -like 'Temporary Access Pass:*' })
                    $SignIn = if ($HasTap) { 'with the Temporary Access Pass above' } else { 'with the password above (no TAP was created - see the messages above)' }
                    $JitResults += @{
                        resultText = "Next: open the Admin Center in a private window, sign in as $Upn $SignIn, Data location > Commitments > 'Store Microsoft 365 customer data in-country' = On, save, then use 'Bestaetigen: AN' here. The JIT admin is deleted after $Hours h."
                        copyField  = $Link
                        state      = 'info'
                    }
                }
                return ([HttpResponseContext]@{ StatusCode = $JitResponse.StatusCode; Body = @{ Results = $JitResults } })
            }
            default {
                return (& $Respond ([HttpStatusCode]::BadRequest) "Unknown Action '$Action'. Use Measure, Confirm, ClearConfirmation or PrepareJIT.")
            }
        }
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Data residency action $Action failed: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        return (& $Respond ([HttpStatusCode]::InternalServerError) "Failed: $($ErrorMessage.NormalizedError)")
    }
}
