# oneICT customisation (Item 230): 'Datenresidenz Schweiz' view. The setting itself has no API; these tests cover
# how the Message Center measurement is classified, that a confirmation wins over the factory default, and that
# the JIT shortcut never lets a caller create a Global Administrator the JIT Admin page would refuse.

BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    ([PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')).GetMethod('Add').Invoke(
        $null, @('HttpStatusCode', [System.Net.HttpStatusCode]))
    class HttpResponseContext { [int]$StatusCode; [object]$Body }

    function Get-CippTable { param($tablename) @{ Context = 'ctx' } }
    function Get-CIPPAzDataTableEntity { param($Context, $Filter) }
    function Add-CIPPAzDataTableEntity { param($Context, $Entity, $OperationType, [switch]$Force) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $Sev, $LogData) }
    function Get-CippException { param($Exception) @{ NormalizedError = "$Exception" } }
    function Get-Tenants { param($TenantFilter, [switch]$IncludeErrors) }
    function New-GraphMultiTenantBulkRequest { param($TenantRequests, $AsApp, $Version) }
    function Test-CIPPAccess { param($Request) }
    function Invoke-ExecJITAdmin { param($Request, $TriggerMetadata) }

    . (Join-Path $BackendRoot 'Modules/CIPPCore/Public/oneICT/Get-CIPPDataResidencyStatus.ps1')
    . (Join-Path $BackendRoot 'Modules/CIPPCore/Public/oneICT/Update-CIPPDataResidencyMeasurement.ps1')
    . (Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Tenant/oneICT/Invoke-ListDataResidency.ps1')
    . (Join-Path $BackendRoot 'Modules/CIPPHTTP/Public/Entrypoints/HTTP Functions/Tenant/oneICT/Invoke-ExecDataResidency.ps1')

    function New-TestTenant($Name) {
        [pscustomobject]@{ customerId = "id-$Name"; defaultDomainName = "$Name.ch"; initialDomainName = "$Name.onmicrosoft.com"; displayName = $Name }
    }
    $script:Principal = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"userDetails":"tech@oneict.ch"}'))
    function New-ExecRequest($Body) {
        [pscustomobject]@{
            Params  = @{ CIPPEndpoint = 'ExecDataResidency' }
            Headers = @{ 'x-ms-client-principal' = $script:Principal }
            Body    = [pscustomobject]$Body
        }
    }
}

Describe 'Get-CIPPDataResidencyStatus' {
    It 'asks to activate a tenant that got MC1470878' {
        $Row = Get-CIPPDataResidencyStatus -Tenant (New-TestTenant 'a') -Record ([pscustomobject]@{ DefaultState = 'Off'; MessageCenterId = 'MC1470878' })
        $Row.Status | Should -Be 'AUS ab Werk'
        $Row.Severity | Should -Be 'error'
        $Row.NextStep | Should -Match '14.12.2026'
        $Row.Tenant | Should -Be 'a.ch'
    }

    It 'lets a recorded confirmation win over the factory default' {
        $Row = Get-CIPPDataResidencyStatus -Tenant (New-TestTenant 'a') -Record ([pscustomobject]@{ DefaultState = 'Off'; ConfirmedState = 'On'; ConfirmedBy = 'tech@oneict.ch' })
        $Row.Status | Should -Be 'AN (bestaetigt)'
        $Row.Severity | Should -Be 'success'
        $Row.FactoryDefault | Should -Be 'AUS ab Werk (MC1470878)'
    }

    It 'shows unmeasured tenants as not measured' {
        $Row = Get-CIPPDataResidencyStatus -Tenant (New-TestTenant 'a') -Record $null
        $Row.Status | Should -Be 'nicht gemessen'
        $Row.AdminCenterLink | Should -Not -Match 'login_hint'
    }

    It 'puts the JIT admin into the Admin Center link' {
        $Row = Get-CIPPDataResidencyStatus -Tenant (New-TestTenant 'a') -Record ([pscustomobject]@{ DefaultState = 'Off'; JITUser = 'oneict-dr-x@a.onmicrosoft.com' })
        $Row.AdminCenterLink | Should -Match 'login_hint=oneict-dr-x%40a.onmicrosoft.com#/Settings/OrganizationProfile'
    }
}

Describe 'Update-CIPPDataResidencyMeasurement' {
    BeforeEach {
        Mock New-GraphMultiTenantBulkRequest {
            foreach ($Item in $TenantRequests) {
                $Responses = switch ($Item.TenantFilter) {
                    'off.ch' { @(@{ id = 'off'; status = 200 }, @{ id = 'on'; status = 404 }) }
                    'on.ch' { @(@{ id = 'off'; status = 404 }, @{ id = 'on'; status = 200 }) }
                    'none.ch' { @(@{ id = 'off'; status = 404 }, @{ id = 'on'; status = 404 }) }
                    'denied.ch' { @(@{ id = 'off'; status = 403; body = @{ error = @{ message = 'Forbidden' } } }, @{ id = 'on'; status = 403 }) }
                    'half.ch' { @(@{ id = 'off'; status = 429 }, @{ id = 'on'; status = 200 }) }
                    'missing.ch' { @(@{ id = 'on'; status = 200 }) }
                    'de.ch' { @(@{ id = 'off'; status = 200 }, @{ id = 'on'; status = 404 }, @{ id = 'org'; status = 200; body = @{ value = @(@{ countryLetterCode = 'DE' }) } }) }
                    default { @() }
                }
                [pscustomobject]@{ TenantFilter = $Item.TenantFilter; Responses = $Responses; Error = $(if ($Item.TenantFilter -eq 'ca.ch') { 'AADSTS53003 blocked by Conditional Access' }) }
            }
        }
        Mock Add-CIPPAzDataTableEntity {}
    }

    It 'classifies each tenant from its Message Center posts' {
        $Result = Update-CIPPDataResidencyMeasurement -Tenants @('off', 'on', 'none', 'denied', 'ca' | ForEach-Object { New-TestTenant $_ })
        ($Result | Where-Object defaultDomainName -EQ 'off.ch').DefaultState | Should -Be 'Off'
        ($Result | Where-Object defaultDomainName -EQ 'on.ch').DefaultState | Should -Be 'On'
        ($Result | Where-Object defaultDomainName -EQ 'none.ch').DefaultState | Should -Be 'None'
        ($Result | Where-Object defaultDomainName -EQ 'denied.ch').DefaultState | Should -Be 'Error'
        ($Result | Where-Object defaultDomainName -EQ 'denied.ch').MeasureError | Should -Match '403'
        ($Result | Where-Object defaultDomainName -EQ 'ca.ch').MeasureError | Should -Match 'Conditional Access'
    }

    It 'never stores a half-failed batch as on by default' {
        $Result = Update-CIPPDataResidencyMeasurement -Tenants @('half', 'missing' | ForEach-Object { New-TestTenant $_ })
        ($Result | Where-Object defaultDomainName -EQ 'half.ch').DefaultState | Should -Be 'Error'
        ($Result | Where-Object defaultDomainName -EQ 'half.ch').MeasureError | Should -Match '429 for MC1470878'
        ($Result | Where-Object defaultDomainName -EQ 'missing.ch').DefaultState | Should -Be 'Error'
    }

    It 'stores the tenant country, since in-country means the tenant geography' {
        $Result = Update-CIPPDataResidencyMeasurement -Tenants @(New-TestTenant 'de')
        $Result.Country | Should -Be 'DE'
        Should -Invoke New-GraphMultiTenantBulkRequest -Times 1 -ParameterFilter { $TenantRequests[0].Requests.url -contains '/organization?$select=countryLetterCode' }
    }

    It 'uses the delegated token and merges, so confirmations survive a new measurement' {
        $null = Update-CIPPDataResidencyMeasurement -Tenants @(New-TestTenant 'off')
        Should -Invoke New-GraphMultiTenantBulkRequest -Times 1 -ParameterFilter { $AsApp -eq $false -and $Version -eq 'v1.0' }
        Should -Invoke Add-CIPPAzDataTableEntity -Times 1 -ParameterFilter { $OperationType -eq 'UpsertMerge' -and -not $Entity.ContainsKey('ConfirmedState') }
    }
}

Describe 'Invoke-ListDataResidency' {
    It 'refuses a request without tenantFilter instead of listing every tenant' {
        Mock Get-Tenants { @(New-TestTenant 'a') }
        $Response = Invoke-ListDataResidency -Request ([pscustomobject]@{ Query = @{} })
        $Response.StatusCode | Should -Be 400
        Should -Invoke Get-Tenants -Times 0
    }

    It 'lists every tenant, the ones needing action first' {
        Mock Get-Tenants { @(New-TestTenant 'zeta'; New-TestTenant 'alpha'; New-TestTenant 'beta') }
        Mock Get-CIPPAzDataTableEntity {
            @([pscustomobject]@{ RowKey = 'id-zeta'; DefaultState = 'Off' }, [pscustomobject]@{ RowKey = 'id-alpha'; DefaultState = 'Off'; ConfirmedState = 'On' })
        }
        $Response = Invoke-ListDataResidency -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'AllTenants' } })
        $Response.StatusCode | Should -Be 200
        $Response.Body.Count | Should -Be 3
        $Response.Body[0].Tenant | Should -Be 'zeta.ch'
        ($Response.Body | Where-Object Tenant -EQ 'beta.ch').Status | Should -Be 'nicht gemessen'
    }
}

Describe 'Invoke-ExecDataResidency' {
    BeforeEach {
        Mock Get-Tenants { @(New-TestTenant 'kunde') }
        Mock Add-CIPPAzDataTableEntity {}
        Mock Invoke-ExecJITAdmin {
            [HttpResponseContext]@{ StatusCode = 200; Body = @{ Results = @(@{ resultText = "Created User: $($Request.Body.Username)@$($Request.Body.Domain)"; copyField = 'x'; state = 'success' }) } }
        }
    }

    It 'refuses changes for all tenants at once' {
        $Response = Invoke-ExecDataResidency -Request (New-ExecRequest @{ Action = 'Confirm'; tenantFilter = 'AllTenants'; ConfirmedState = 'On' })
        $Response.StatusCode | Should -Be 400
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0
    }

    It 'records a confirmation with the calling technician' {
        $Response = Invoke-ExecDataResidency -Request (New-ExecRequest @{ Action = 'Confirm'; tenantFilter = 'kunde.ch'; ConfirmedState = @{ value = 'On' }; Note = 'Screenshot im Ticket' })
        $Response.StatusCode | Should -Be 200
        Should -Invoke Add-CIPPAzDataTableEntity -Times 1 -ParameterFilter { $Entity.ConfirmedState -eq 'On' -and $Entity.ConfirmedBy -eq 'tech@oneict.ch' -and $Entity.RowKey -eq 'id-kunde' }
    }

    It 'measures a tenant group from the router-normalised query' {
        Mock Update-CIPPDataResidencyMeasurement { foreach ($T in $Tenants) { [pscustomobject]@{ defaultDomainName = $T.defaultDomainName; DefaultState = 'Off' } } }
        $Request = New-ExecRequest @{ Action = 'Measure' }
        $Request | Add-Member -NotePropertyName Query -NotePropertyValue @{ tenantFilter = 'AllTenants'; tenantGroup = 'g1' }
        $Response = Invoke-ExecDataResidency -Request $Request
        $Response.StatusCode | Should -Be 200
        Should -Invoke Get-Tenants -Times 1 -ParameterFilter { -not $TenantFilter }
    }

    It 'rejects an unknown confirmed state' {
        $Response = Invoke-ExecDataResidency -Request (New-ExecRequest @{ Action = 'Confirm'; tenantFilter = 'kunde.ch'; ConfirmedState = 'Maybe' })
        $Response.StatusCode | Should -Be 400
    }

    It 'does not create a JIT admin when the caller may not use ExecJITAdmin' {
        Mock Test-CIPPAccess { throw 'Access to this CIPP API endpoint is not allowed, you do not have the required permission: Identity.Role.ReadWrite' }
        $Response = Invoke-ExecDataResidency -Request (New-ExecRequest @{ Action = 'PrepareJIT'; tenantFilter = 'kunde.ch' })
        $Response.StatusCode | Should -Be 403
        Should -Invoke Invoke-ExecJITAdmin -Times 0
        Should -Invoke Add-CIPPAzDataTableEntity -Times 0
    }

    It 'creates a time-limited Global Administrator with TAP and remembers it' {
        Mock Test-CIPPAccess { $true }
        $Response = Invoke-ExecDataResidency -Request (New-ExecRequest @{ Action = 'PrepareJIT'; tenantFilter = 'kunde.ch'; Hours = 4 })
        $Response.StatusCode | Should -Be 200
        Should -Invoke Test-CIPPAccess -Times 1 -ParameterFilter { $Request.Params.CIPPEndpoint -eq 'ExecJITAdmin' -and $Request.Body.tenantFilter -eq 'kunde.ch' }
        Should -Invoke Invoke-ExecJITAdmin -Times 1 -ParameterFilter {
            $Request.Body.AdminRoles[0].value -eq '62e90394-69f5-4237-9190-012177145e10' -and
            $Request.Body.UseTAP -eq $true -and
            $Request.Body.ExpireAction.value -eq 'DeleteUser' -and
            $Request.Body.Domain -eq 'kunde.onmicrosoft.com' -and
            ([int64]$Request.Body.EndDate - [int64]$Request.Body.StartDate) -eq 14400
        }
        Should -Invoke Add-CIPPAzDataTableEntity -Times 1 -ParameterFilter { $Entity.JITUser -like 'oneict-dr-*@kunde.onmicrosoft.com' }
        ($Response.Body.Results | Where-Object { $_.state -eq 'info' }).copyField | Should -Match 'login_hint=oneict-dr-'
    }

    It 'keeps the one-time credentials when recording the JIT admin fails' {
        Mock Test-CIPPAccess { $true }
        Mock Add-CIPPAzDataTableEntity { throw 'storage unavailable' }
        $Response = Invoke-ExecDataResidency -Request (New-ExecRequest @{ Action = 'PrepareJIT'; tenantFilter = 'kunde.ch' })
        $Response.StatusCode | Should -Be 200
        ($Response.Body.Results | Where-Object { $_.resultText -like 'Created User:*' }) | Should -Not -BeNullOrEmpty
        ($Response.Body.Results | Where-Object { $_ -is [string] -and $_ -like 'Warning:*' }) | Should -Not -BeNullOrEmpty
    }

    It 'does not point to a TAP that was not created' {
        Mock Test-CIPPAccess { $true }
        $Response = Invoke-ExecDataResidency -Request (New-ExecRequest @{ Action = 'PrepareJIT'; tenantFilter = 'kunde.ch' })
        ($Response.Body.Results | Where-Object { $_.state -eq 'info' }).resultText | Should -Match 'no TAP was created'
    }
}
