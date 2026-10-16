Stock dashboards from a VCF Operations 9.1.1 content export, sanitised. Each is a `dashboard/dashboard.json` as found inside an export's `dashboards/<owner>` zip.

- `view-widget/`: vSphere/vCenter Appliance Availability, whose View widgets show a list view inside a dashboard.
- `scoreboard-widget/`: Environment Summary, with Scoreboard and View widgets.

Tokens that replace values local to one Operations instance:

| Token | Was |
|---|---|
| `{{OWNER_ID}}` | the exporting user's id |
| `{{RESOURCE_ID}}` | a resource UUID, or the number in `resource:id:<n>_::_` |
| `{{RESOURCE_KIND_ID}}` | the number in `resourceKind:id:<n>_::_`, a resource kind's local id, not a resource |
| `{{RESOURCE_NAME}}` | a `resourceName` value, such as an Operations cluster's instance name |
| `{{HOST}}` | a host name |

Ids of the dashboards, their widgets and stock views are kept.
