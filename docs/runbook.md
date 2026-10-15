# Runbook

## Phase 0 spikes (VCF Operations 9.1.1.0, Holodeck 9.1)

Run on 15 October 2026 against the Holodeck lab (`ops-a.site-a.mars.local`, signed in as the local `admin`), from a Windows Server jump host with PowerShell 7.6. All paths below are under `/suite-api`. Everything created was named `Synth-` and removed afterwards, except the two items listed under "Left behind".

| Spike | Question | Answer |
|---|---|---|
| Set-up | Can the toolset sign in? | Yes |
| 0.1 | Objects under the native `VMWARE` adapter kind? | Yes, but only through a vCenter adapter instance |
| 0.1 | Objects under a custom kind (`VcfOpsSynth`)? | Yes |
| 0.2 | Back-dated history (1, 7 and 30 days)? | Yes |
| 0.2 | Practical batch size | At least 518,400 samples (9.7 MB) per call |
| 0.3 | Super metrics through the API? | Yes |
| 0.3 | Policies through the API? | Yes |
| 0.3 | Views through the API? | Import yes; list unsupported only; no delete |
| 0.3 | Dashboards through the API? | Import yes; no list or delete |
| 0.4 | Importer on a real RVTools export of vc-mgmt-a | Not run yet; waiting for an export |

### Set-up

`Test-NetConnection ops-a.site-a.mars.local -Port 443` succeeded, then `pwsh ./bin/vcfops-synth.ps1 connect-test` printed `VCF Operations: VCF Operations 9.1.1.0`. The local `config/lab.json` (gitignored) sets `operations.fqdn` and `skipCertificateCheck: true`, because Holodeck certificates are self-signed. The password comes from `VCFOPS_PASSWORD`, set in the process only.

### 0.1 Native or custom adapter kind

- `POST /api/resources/adapterkinds/VMWARE` returns **400**, `The Adapter Kind "VMWARE" specified is not of OPENAPI type.` (apiErrorCode 1514). That endpoint only takes OPENAPI kinds.
- `POST /api/resources/adapters/{adapterInstanceId}` with the vCenter adapter instance of vc-mgmt-a returns **201** and creates a `VMWARE/VirtualMachine` object. `VMEntityName`, `VMEntityObjectID` and `VMEntityVCID` are mandatory: leaving `VMEntityName` out gives 422 (apiErrorCode 1505). The test used a made-up `VMEntityVCID`, so it could not clash with a real VM. The object read back with `GET /api/resources/{id}` as `resourceState: STARTED` under that adapter instance. It was still there after about 45 minutes of collection cycles, took a pushed stat through `POST /api/resources/{id}/stats`, and Operations began computing badges for it (health, risk, efficiency, compliance).
- `POST /api/resources/adapterkinds/VcfOpsSynth` returns **201** with no set-up beforehand. The first call created the adapter kind itself (`GET /api/adapterkinds/VcfOpsSynth` gives `adapterKindType: OPENAPI`) and the `VirtualMachine` resource kind under it. A single uniqueness identifier (`SynthId`) is enough.

Decision for Phase 3: the custom kind stays the default. It needs no adapter instance and cannot interfere with real vCenter collection. Native `VMWARE` objects are possible, so content that only works on vCenter kinds (out-of-the-box dashboards, rightsizing) could get a few objects created under the vCenter adapter instance. Doing that needs care, because those objects sit beside the real inventory.

Clean-up: `DELETE /api/resources/{id}` returns 204 for both kinds. The `VcfOpsSynth` adapter kind itself cannot be removed through the API (`DELETE /api/adapterkinds/VcfOpsSynth` returns 405). It stays as an empty kind, which Phase 3 reuses.

### 0.2 Back-dated history and batch size

`POST /api/resources/stats/adapterkinds/VcfOpsSynth?disableAnalyticsProcessing=true` with a `resource-stat-content` body (one entry per object, each with `stat-contents` of `statKey`, `timestamps` in epoch milliseconds, and `data`):

| Push | Samples | Result | Read back with `GET /api/resources/{id}/stats` |
|---|---|---|---|
| 1 day at 5 minutes | 288 | 200 | Yes |
| 7 days at 5 minutes | 2,016 | 200 | 2,016 points, first point 7 days back |
| 14 days at 5 minutes | 4,032 | 200 | 4,032 points |
| 30 days at 5 minutes | 8,640 | 200 | 8,640 points, first point 30 days back |
| One day that ended 29 days ago only | 288 | 200 | 288 points at the right dates |
| 10 metrics x 30 days in one call | 86,400 (1.6 MB) | 200 in 0.8 s | All 10 metrics, 8,640 points each |
| 30 metrics x 30 days in one call | 259,200 (4.9 MB) | 200 in 0.4 s | All 30, 8,640 points each |
| 60 metrics x 30 days in one call | 518,400 (9.7 MB) | 200 in 2.0 s | All 60, 8,640 points each |

Notes:

- Ingestion is queued. A 200 means "accepted", not "stored". In the first runs, the 1-day and 7-day series read back after about 10 minutes and the 30-day series after about 14; the chunked tests after about 17. Stat keys appear in `GET /api/resources/{id}/statkeys` before their points do. The backfill should push, then poll a sample of objects for up to 20 minutes, not trust the response alone.
- Chunking makes no difference: 30 days sent as five 7-day pushes read back the same as one 30-day push.
- `GET /api/resources/stats/latest` returns only the newest sample per key, so it does not show whether history landed.
- No size limit was reached at 9.7 MB per call. For Phase 4, start at about 5 MB (roughly 250,000 samples) per call: it is well inside what worked and keeps a retry cheap. The existing 429/5xx backoff in `Invoke-SynthOpsRequest` covers throttling.
- The read-back query takes `begin`, `rollUpType=AVG`, `intervalType=MINUTES` and `intervalQuantifier=5`.

### 0.3 Content through the API

| Content | List | Create or import | Remove |
|---|---|---|---|
| Super metrics | `GET /api/supermetrics` | `POST /api/supermetrics` (JSON: name, formula, description), 201. Also through a content import bundle with `supermetrics.json`: an exported super metric was deleted and imported back (`SUPER_METRICS imported 1`), and a hand-edited copy with a new name imported too | `DELETE /api/supermetrics/{id}`, 204 |
| Policies | `GET /api/policies` | `POST /api/policies/import?forceImport=false`, multipart field `policy`, a zip holding `exportedPolicies.xml` (as made by `GET /api/policies/export?id={id}`), 200 | `DELETE /api/policies/{id}`, 204 |
| Views | `GET /internal/viewdefinitions` (unsupported: needs header `X-Ops-API-use-unsupported: true`) | `POST /api/content/operations/import` bundle with `views.zip` holding `content.xml`, reported `VIEW_DEFINITIONS: imported 1` | None found (405 on the forms tried); delete in the UI |
| Dashboards | None found (`/api/dashboards` and `/internal/dashboards` are 404) | `POST /api/content/operations/import` bundle with `dashboards/{ownerUserId}` (a zip holding `dashboard/dashboard.json` and `dashboard/resources/resources.properties`), reported `DASHBOARDS: imported 1` | None found; delete in the UI |

What made imports work:

- **Policy files.** Edit `exportedPolicies.xml` as text (new `key`, new `name`) and zip it. Saving it again through `System.Xml.XmlDocument` gave `Invalid policy content format` (500), even with the content unchanged. A plain `.xml` upload gives `Invalid file format` (400). The export includes the parent policy; with `forceImport=false` an existing parent is reported under `skippedPolicies` and left alone, so the child can be created safely.
- **Content bundles.** The zip root holds `configuration.json` (`{"type":"CUSTOM","views":1}` or `{"type":"CUSTOM","dashboards":1,"dashboardsByOwner":[{"owner":"<userId>","count":1}]}`), `usermappings.json` and the `<id>L.v1` marker file from a real export, plus the content folders. Start from `POST /api/content/operations/export` (then `GET /api/content/operations/export/zip`) and trim it. A dashboard zip without `dashboard/dashboard.json` is accepted but imports 0, with no error. `dashboard.json` keeps its top-level `entries` and `uuid` beside the `dashboards` array.
- **Import status.** The import is asynchronous (202). Poll `GET /api/content/operations/import` until `state` is `FINISHED` and read `operationSummaries` for imported, skipped and failed counts.
- **Ids.** Operations assigned its own id to the imported view and to the hand-edited super metric, ignoring the ids in the files, so look content up by name after an import.
- **Export.** `POST /api/content/operations/export` takes `{"scope":"CUSTOM"|"ALL","contentTypes":[...]}`. Types include `VIEW_DEFINITIONS`, `REPORT_DEFINITIONS`, `DASHBOARDS`, `REPORT_SCHEDULES`, `CUSTOM_METRICGROUPS`, `POLICIES`, `ALERT_DEFINITIONS`, `SYMPTOM_DEFINITIONS`, `CUSTOM_GROUPS` and `SUPER_METRICS`. An `ALL` export of dashboards, views and policies took about a minute.
- **Internal API.** `/internal/...` calls need the `X-Ops-API-use-unsupported: true` header; without it they are refused.

Decision for Phase 5 to 7: groups, super metrics and policies can be fully managed through the API, including reset. Views and dashboards can be pushed through content import but not listed or removed through a supported API. So `reset` must either leave them, overwrite them by name with `force=true` on the next import, or tell the user to delete the `Synth-` items in the UI.

### 0.4 RVTools import on vc-mgmt-a

Not run yet. Needs an RVTools export of vc-mgmt-a; the run will be `pwsh ./bin/vcfops-synth.ps1 import <export.xlsx>`.

### Left behind

These two could not be removed through the API and are still in the lab:

- View `Synth-spike03-view` (Views, delete in the UI)
- Dashboard `Synth-spike03-dash` (Dashboards, delete in the UI)

The `VcfOpsSynth` adapter kind also stays, with no objects in it.
