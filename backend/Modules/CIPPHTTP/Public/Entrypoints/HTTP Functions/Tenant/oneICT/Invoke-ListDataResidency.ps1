function Invoke-ListDataResidency {
    <#
    .FUNCTIONALITY
        Entrypoint,TenantGroup
    .ROLE
        Tenant.Administration.Read
    .DESCRIPTION
        oneICT customisation (Item 230): lists per tenant the status of the Microsoft 365 setting "Store Microsoft 365 customer data in-country" (Datenresidenz Schweiz, deadline 14.12.2026). The status combines the stored Message Center measurement (MC1470878 = off by default, MC1470876 = on by default) with the confirmation a technician records after switching the setting in the Admin Center. Reads only the oneICTDataResidency table; run ExecDataResidency Action=Measure to refresh.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $TenantFilter = $Request.Query.tenantFilter

    # No filter must not turn into an implicit all-tenants list: roles that block AllTenants are only enforced
    # when AllTenants is named. Tenant groups arrive here already normalised to tenantFilter=AllTenants.
    if ([string]::IsNullOrWhiteSpace($TenantFilter)) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = 'tenantFilter is required.'
            })
    }

    try {
        # Get-Tenants applies the caller's tenant scope and the tenant group for AllTenants
        $Tenants = if ($TenantFilter -eq 'AllTenants') {
            @(Get-Tenants)
        } else {
            @(Get-Tenants -TenantFilter $TenantFilter)
        }
        if ($TenantFilter -ne 'AllTenants' -and $Tenants.Count -eq 0) {
            throw "Tenant $TenantFilter not found"
        }

        $Table = Get-CIPPTable -tablename 'oneICTDataResidency'
        $Records = @{}
        foreach ($Row in @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'Tenant'")) {
            $Records[[string]$Row.RowKey] = $Row
        }

        $Results = foreach ($Tenant in $Tenants) {
            Get-CIPPDataResidencyStatus -Tenant $Tenant -Record $Records[[string]$Tenant.customerId]
        }
        $Results = @($Results | Sort-Object -Property @{ Expression = {
                    switch ($_.Severity) { 'error' { 0 } 'warning' { 1 } 'info' { 2 } default { 3 } }
                }
            }, displayName)
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $StatusCode = [HttpStatusCode]::InternalServerError
        $Results = "Failed to list data residency status: $($_.Exception.Message)"
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @($Results)
        })
}
