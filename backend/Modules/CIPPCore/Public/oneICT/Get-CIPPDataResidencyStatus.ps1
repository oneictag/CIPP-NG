function Get-CIPPDataResidencyStatus {
    <#
    .SYNOPSIS
        Builds the 'Datenresidenz Schweiz' status row for one tenant (oneICT customisation, Item 230).
    .DESCRIPTION
        Microsoft added the tenant setting "Store Microsoft 365 customer data in-country" (Admin Center >
        Settings > Org settings > Organization profile > Data location > Commitments). From 14.12.2026 the stored
        choice applies. Microsoft documents no Graph, PowerShell or partner API for it, and only a Global
        Administrator may change it.

        What CIPP can read is which Message Center post the tenant received, which tells the factory default:
          MC1470878 = setting OFF by default (must be switched on before 14.12.2026)
          MC1470876 = setting ON by default (only check)
          neither   = factory default unknown (not eligible, ADR/Multi-Geo, or a tenant created after the posts;
                      Microsoft documents OFF as default for eligible new tenants) - check in the Admin Center
        The setting keeps data in the tenant's own geography (CH, DE, FR, NO or SE), so the country is shown too.
        The post shows the starting value, not today's value, so a confirmation recorded by a technician (after
        changing the setting in the Admin Center) takes precedence.

        Pure function: turns a stored measurement/confirmation row into the row the frontend shows.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Tenant,
        $Record
    )

    $Deadline = [datetime]'2026-12-14'
    $DefaultState = [string]$Record.DefaultState
    $ConfirmedState = [string]$Record.ConfirmedState

    $Default = switch ($DefaultState) {
        'Off' { 'AUS ab Werk (MC1470878)' }
        'On' { 'AN ab Werk (MC1470876)' }
        'None' { 'keine Meldung (unbekannt)' }
        'Error' { 'nicht messbar' }
        default { 'nicht gemessen' }
    }

    $Status, $Action, $Severity = if ($ConfirmedState -eq 'On') {
        'AN (bestaetigt)', 'erledigt', 'success'
    } elseif ($ConfirmedState -eq 'Off') {
        'AUS (bestaetigt, Kundenentscheid)', 'Kundenentscheid dokumentiert', 'info'
    } else {
        switch ($DefaultState) {
            'Off' { 'AUS ab Werk', 'aktivieren bis 14.12.2026', 'error' }
            'On' { 'AN ab Werk', 'im Admin Center kurz kontrollieren', 'warning' }
            'None' { 'keine Meldung', 'im Admin Center pruefen (Ausgangswert unbekannt)', 'warning' }
            'Error' { 'nicht messbar', 'Messfehler pruefen und erneut messen', 'warning' }
            default { 'nicht gemessen', "Aktion 'Status messen' ausfuehren", 'info' }
        }
    }

    $InitialDomain = [string]($Tenant.initialDomainName ?? $Tenant.defaultDomainName)
    [pscustomobject]@{
        Tenant              = [string]$Tenant.defaultDomainName
        displayName         = [string]$Tenant.displayName
        customerId          = [string]$Tenant.customerId
        initialDomainName   = $InitialDomain
        Status              = $Status
        Severity            = $Severity
        NextStep            = $Action
        FactoryDefault      = $Default
        Country             = [string]$Record.Country
        MessageCenterId     = [string]$Record.MessageCenterId
        MeasuredAt          = $Record.MeasuredAt
        MeasureError        = [string]$Record.MeasureError
        ConfirmedState      = $ConfirmedState
        ConfirmedBy         = [string]$Record.ConfirmedBy
        ConfirmedAt         = $Record.ConfirmedAt
        Note                = [string]$Record.Note
        JITUser             = [string]$Record.JITUser
        JITExpires          = $Record.JITExpires
        DaysToDeadline      = [int][Math]::Ceiling(($Deadline - (Get-Date).Date).TotalDays)
        AdminCenterLink     = $(if ($Record.JITUser) { 'https://admin.cloud.microsoft/?login_hint={0}#/Settings/OrganizationProfile/:/Settings/L1/DataLocation' -f [uri]::EscapeDataString([string]$Record.JITUser) } else { 'https://admin.cloud.microsoft/#/Settings/OrganizationProfile/:/Settings/L1/DataLocation' })
        PartnerAdminLink    = 'https://admin.microsoft.com/Partner/BeginClientSession.aspx?CTID={0}&CSDEST=o365admincenter' -f [uri]::EscapeDataString([string]$Tenant.customerId)
    }
}
