function Update-CIPPDataResidencyMeasurement {
    <#
    .SYNOPSIS
        Measures the 'Datenresidenz Schweiz' factory default for tenants and stores it (oneICT customisation, Item 230).
    .DESCRIPTION
        Reads the two Message Center posts per tenant in one Graph $batch per tenant, tenants concurrently
        (New-GraphMultiTenantBulkRequest, delegated GDAP token - ServiceMessage.Read.All is delegated only in the
        CIPP SAM app). Writes DefaultState/MessageCenterId/MeasuredAt into table oneICTDataResidency and leaves
        a technician's confirmation untouched. Returns one summary object per tenant.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][object[]]$Tenants
    )

    $Posts = [ordered]@{ off = 'MC1470878'; on = 'MC1470876' }
    $TenantRequests = foreach ($Tenant in $Tenants) {
        @{
            TenantFilter = [string]$Tenant.defaultDomainName
            Requests     = @(
                foreach ($Key in $Posts.Keys) {
                    @{ id = $Key; method = 'GET'; url = "/admin/serviceAnnouncement/messages/$($Posts[$Key])?`$select=id,title,lastModifiedDateTime" }
                }
                # The setting exists for CH, DE, FR, NO and SE; the country shows which geography 'in-country' means
                @{ id = 'org'; method = 'GET'; url = '/organization?$select=countryLetterCode' }
            )
        }
    }
    $Sent = @(New-GraphMultiTenantBulkRequest -TenantRequests @($TenantRequests) -AsApp $false -Version 'v1.0')

    $Table = Get-CIPPTable -tablename 'oneICTDataResidency'
    $Now = (Get-Date).ToUniversalTime()
    $ByDomain = @{}
    foreach ($Tenant in $Tenants) { $ByDomain[[string]$Tenant.defaultDomainName] = $Tenant }

    foreach ($TenantResult in $Sent) {
        $Tenant = $ByDomain[[string]$TenantResult.TenantFilter]
        if (-not $Tenant) { continue }
        $Answered = @{}
        foreach ($Response in $TenantResult.Responses) { $Answered[[string]$Response.id] = $Response }

        $Status = @{}
        foreach ($Key in $Posts.Keys) { $Status[$Key] = if ($Answered.ContainsKey($Key)) { [int]$Answered[$Key].status } else { 0 } }
        $Country = if ([int]$Answered['org'].status -eq 200) { [string]@($Answered['org'].body.value)[0].countryLetterCode } else { '' }

        # Only a complete answer classifies: 200 = post exists, 404 = post absent. Anything else (403, 429, no
        # response) leaves the factory default unknown, so a half-failed batch is never stored as 'on by default'.
        $Unclear = @($Posts.Keys | Where-Object { $Status[$_] -ne 200 -and $Status[$_] -ne 404 })
        $DefaultState, $MessageCenterId, $MeasureError = if ($TenantResult.Error) {
            'Error', '', ([string]$TenantResult.Error).Substring(0, [Math]::Min(500, ([string]$TenantResult.Error).Length))
        } elseif ($Status.off -eq 200) {
            # MC1470878 decides even if the other post is unclear or also present. A tenant that already switched
            # the setting on still only has MC1470878; the technician's confirmation decides.
            'Off', $Posts.off, ''
        } elseif ($Unclear.Count -gt 0) {
            $First = $Answered[$Unclear[0]]
            $Message = if ($First) { 'HTTP {0} for {1}: {2}' -f $First.status, $Posts[$Unclear[0]], ($First.body.error.message ?? '') } else { "No response for $($Posts[$Unclear[0]]) in the batch reply" }
            'Error', '', $Message
        } elseif ($Status.on -eq 200) {
            'On', $Posts.on, ''
        } else {
            'None', '', ''
        }

        $Entity = @{
            PartitionKey      = 'Tenant'
            RowKey            = [string]$Tenant.customerId
            defaultDomainName = [string]$Tenant.defaultDomainName
            displayName       = [string]$Tenant.displayName
            DefaultState      = [string]$DefaultState
            MessageCenterId   = [string]$MessageCenterId
            MeasureError      = [string]$MeasureError
            Country           = $Country
            MeasuredAt        = $Now
        }
        if ($PSCmdlet.ShouldProcess($Tenant.defaultDomainName, 'Store data residency measurement')) {
            # -OperationType UpsertMerge keeps ConfirmedState/ConfirmedBy/JITUser written by ExecDataResidency
            Add-CIPPAzDataTableEntity @Table -Entity $Entity -OperationType 'UpsertMerge'
        }
        [pscustomobject]$Entity
    }
}
