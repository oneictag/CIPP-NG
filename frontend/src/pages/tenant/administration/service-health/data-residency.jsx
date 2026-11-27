// oneICT customisation (Item 230): Datenresidenz Schweiz.
// Microsoft setting "Store Microsoft 365 customer data in-country" (Admin Center > Settings > Org settings >
// Organization profile > Data location > Commitments). From 14.12.2026 the stored choice applies. Microsoft offers
// no API for it and only a Global Administrator may change it, so this page shows the measured factory default
// (Message Center MC1470878 / MC1470876), prepares a time-limited Global Administrator with a TAP, and records
// the state the technician confirmed in the Admin Center.
import { Alert, Button, Stack, Typography } from '@mui/material'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage'
import { CippInfoBar } from '../../../../components/CippCards/CippInfoBar'
import { CippApiDialog } from '../../../../components/CippComponents/CippApiDialog'
import { CippIcons } from '../../../../utils/icon-registry'
import { Layout as DashboardLayout } from '../../../../layouts/index'
import { TabbedLayout } from '../../../../layouts/TabbedLayout'
import { useSettings } from '../../../../hooks/use-settings'
import { useDialog } from '../../../../hooks/use-dialog'
import { ApiGetCall } from '../../../../api/ApiCall'
import { tenantScope } from '../../../../utils/tenant-selection'
import tabOptions from './tabOptions'

const DEADLINE = new Date('2026-12-14T00:00:00')
const QUERY_KEY = 'ListDataResidency'

const noteField = (required) => ({
  type: 'textField',
  name: 'Note',
  label: required
    ? 'Begruendung / Beleg (Pflicht, z.B. Kundenmail vom ...)'
    : 'Notiz / Beleg (z.B. Screenshot im Ticket #...)',
  ...(required ? { validators: { required: 'Bitte Begruendung angeben' } } : {}),
})

const Page = () => {
  const { currentTenant } = useSettings()
  const measureDialog = useDialog()

  const data = ApiGetCall({
    url: '/api/ListDataResidency',
    data: { ...tenantScope(currentTenant) },
    // Own key: the table caches this URL in a paginated shape under its queryKey
    queryKey: `${QUERY_KEY}-counts-${currentTenant}`,
    waiting: !!currentTenant,
  })
  const rows = Array.isArray(data.data) ? data.data : []
  const daysLeft = Math.max(0, Math.ceil((DEADLINE - new Date()) / 86400000))
  const count = (fn) => rows.filter(fn).length

  const actions = [
    {
      label: 'Status messen (Message Center)',
      type: 'POST',
      url: '/api/ExecDataResidency',
      data: { Action: '!Measure' },
      icon: <CippIcons.Sync />,
      relatedQueryKeys: [`${QUERY_KEY}*`],
      confirmText:
        'Message Center (MC1470878 / MC1470876) fuer [displayName] lesen und den Ausgangswert speichern? Es wird nichts im Tenant geaendert.',
      multiPost: false,
    },
    {
      label: 'Admin Center oeffnen (Datenspeicherort)',
      link: '[AdminCenterLink]',
      external: true,
      icon: <CippIcons.OpenInNew />,
      multiPost: false,
    },
    {
      label: 'Admin Center als Partner (GDAP, nur ansehen)',
      link: '[PartnerAdminLink]',
      external: true,
      icon: <CippIcons.Visibility />,
      multiPost: false,
    },
    {
      label: 'JIT-Admin (Global Admin) + TAP anlegen',
      type: 'POST',
      url: '/api/ExecDataResidency',
      data: { Action: '!PrepareJIT' },
      fields: [
        {
          type: 'autoComplete',
          name: 'Hours',
          label: 'Gueltigkeit (leer = 4 Stunden)',
          multiple: false,
          creatable: false,
          options: [
            { label: '2 Stunden', value: 2 },
            { label: '4 Stunden (empfohlen)', value: 4 },
            { label: '8 Stunden', value: 8 },
          ],
        },
      ],
      // One JIT admin per selected tenant; an array is sent as one request per row.
      customDataformatter: (row, action, formData) => {
        const toBody = (r) => ({
          tenantFilter: r.Tenant,
          Action: 'PrepareJIT',
          Hours: formData?.Hours?.value ?? 4,
        })
        return Array.isArray(row) ? row.map(toBody) : toBody(row)
      },
      icon: <CippIcons.AdminPanelSettings />,
      confirmText:
        'In [displayName] einen befristeten Global Administrator (oneict-dr-...) mit Temporary Access Pass anlegen? Microsoft erlaubt die Einstellung nur einem Global Administrator und bietet keine API dafuer. Der Benutzer wird nach Ablauf automatisch geloescht. Danach im privaten Fenster mit dem TAP anmelden, Datenspeicherort > Zusagen > "Store Microsoft 365 customer data in-country" einschalten, speichern und hier "Bestaetigen: AN" waehlen.',
      condition: (row) => row.ConfirmedState !== 'On',
      relatedQueryKeys: [`${QUERY_KEY}*`],
      multiPost: false,
    },
    {
      label: 'Bestaetigen: AN (im Admin Center gesetzt)',
      type: 'POST',
      url: '/api/ExecDataResidency',
      data: { Action: '!Confirm', ConfirmedState: '!On' },
      fields: [noteField(false)],
      icon: <CippIcons.CheckCircle />,
      confirmText:
        'Bestaetigen, dass bei [displayName] im Admin Center "Store Microsoft 365 customer data in-country" eingeschaltet und gespeichert ist?',
      condition: (row) => row.ConfirmedState !== 'On',
      relatedQueryKeys: [`${QUERY_KEY}*`],
      multiPost: false,
    },
    {
      label: 'Bestaetigen: AUS (Kundenentscheid)',
      type: 'POST',
      url: '/api/ExecDataResidency',
      data: { Action: '!Confirm', ConfirmedState: '!Off' },
      fields: [noteField(true)],
      icon: <CippIcons.Block />,
      confirmText:
        'Festhalten, dass [displayName] die Einstellung bewusst AUS laesst (Daten duerfen im EU Data Boundary liegen; ein spaeterer Rueckzug ins Land dauert ca. 6 Monate)?',
      condition: (row) => row.ConfirmedState !== 'Off',
      relatedQueryKeys: [`${QUERY_KEY}*`],
      multiPost: false,
    },
    {
      label: 'Bestaetigung zuruecksetzen',
      type: 'POST',
      url: '/api/ExecDataResidency',
      data: { Action: '!ClearConfirmation' },
      icon: <CippIcons.Undo />,
      confirmText: 'Die gespeicherte Bestaetigung fuer [displayName] entfernen?',
      condition: (row) => !!row.ConfirmedState,
      relatedQueryKeys: [`${QUERY_KEY}*`],
      multiPost: false,
    },
  ]

  return (
    <>
      <CippTablePage
        title="Datenresidenz Schweiz"
        apiUrl="/api/ListDataResidency"
        queryKey={`${QUERY_KEY}-${currentTenant}`}
        actions={actions}
        simpleColumns={[
          'displayName',
          'Tenant',
          'Country',
          'Status',
          'NextStep',
          'FactoryDefault',
          'ConfirmedBy',
          'ConfirmedAt',
          'Note',
          'MeasuredAt',
          'JITUser',
          'JITExpires',
        ]}
        filters={[
          {
            filterName: 'Offen: AUS ab Werk',
            value: [{ id: 'Status', value: 'AUS ab Werk' }],
            type: 'column',
          },
          {
            filterName: 'Kontrollieren: AN ab Werk',
            value: [{ id: 'Status', value: 'AN ab Werk' }],
            type: 'column',
          },
          {
            filterName: 'Keine Meldung',
            value: [{ id: 'Status', value: 'keine Meldung' }],
            type: 'column',
          },
          {
            filterName: 'Bestaetigt AN',
            value: [{ id: 'ConfirmedState', value: 'On' }],
            type: 'column',
          },
        ]}
        offCanvas={{
          extendedInfoFields: [
            'displayName',
            'Tenant',
            'Status',
            'NextStep',
            'FactoryDefault',
            'Country',
            'MessageCenterId',
            'MeasuredAt',
            'MeasureError',
            'ConfirmedState',
            'ConfirmedBy',
            'ConfirmedAt',
            'Note',
            'JITUser',
            'JITExpires',
          ],
          actions,
        }}
        cardButton={
          <Button
            variant="contained"
            size="small"
            startIcon={<CippIcons.Sync />}
            onClick={measureDialog.handleOpen}
          >
            Status messen
          </Button>
        }
        tableFilter={
          <Stack spacing={2}>
            <Alert severity={daysLeft <= 7 ? 'error' : 'warning'}>
              <Typography variant="body2">
                <strong>Store Microsoft 365 customer data in-country</strong> - Stichtag{' '}
                <strong>14.12.2026</strong> (noch {daysLeft} Tage). Ist die Einstellung dann AUS,
                darf Microsoft Exchange-, SharePoint-, OneDrive-, Teams- und Copilot-Daten im EU
                Data Boundary statt im Land des Tenants (Spalte Land, bei uns CH) speichern. Aendern
                darf nur ein Global Administrator, eine API gibt es nicht: Status hier messen,
                JIT-Admin mit TAP anlegen, im Admin Center einschalten und hier bestaetigen. Die
                Message-Center- Meldung zeigt nur den Ausgangswert, nicht den heutigen Stand.
              </Typography>
            </Alert>
            <CippInfoBar
              data={[
                {
                  name: 'AUS ab Werk, offen',
                  data: count((r) => r.Status === 'AUS ab Werk'),
                  icon: <CippIcons.Error />,
                  color: 'error',
                },
                {
                  name: 'AN ab Werk, kontrollieren',
                  data: count((r) => r.Status === 'AN ab Werk'),
                  icon: <CippIcons.Warning />,
                  color: 'warning',
                },
                {
                  name: 'Bestaetigt AN',
                  data: count((r) => r.ConfirmedState === 'On'),
                  icon: <CippIcons.CheckCircle />,
                  color: 'success',
                },
                {
                  name: 'Keine Meldung / nicht gemessen',
                  data: count((r) =>
                    ['keine Meldung', 'nicht gemessen', 'nicht messbar'].includes(r.Status)
                  ),
                  icon: <CippIcons.Info />,
                  color: 'primary',
                },
              ]}
              isFetching={data.isFetching}
            />
          </Stack>
        }
      />
      <CippApiDialog
        createDialog={measureDialog}
        title="Status messen"
        api={{
          url: '/api/ExecDataResidency',
          type: 'POST',
          data: { Action: '!Measure' },
          confirmText:
            'Message Center (MC1470878 / MC1470876) und Land fuer die gewaehlten Tenants lesen und den Ausgangswert speichern? Es wird nichts in den Tenants geaendert. Bei allen Tenants dauert das ca. 1 Minute.',
          relatedQueryKeys: [`${QUERY_KEY}*`],
        }}
        row={{}}
      />
    </>
  )
}

Page.getLayout = (page) => (
  <DashboardLayout tenantGroupSupport={true} allTenantsSupport={true}>
    <TabbedLayout tabOptions={tabOptions}>{page}</TabbedLayout>
  </DashboardLayout>
)

export default Page
