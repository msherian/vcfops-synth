# Runbook

## Phase 0 spikes (VCF Operations 9.1.1.0, Holodeck lab)

Run on 15 October 2026 against `ops-a.site-a.mars.local` (VCF Operations 9.1.1.0) from the lab utility server, with the toolset on branch `claude/phase-2-rvtools`. Every call below is relative to `https://<ops>/suite-api/` and uses an `OpsToken` from `connect-test`. Everything created was named `Synth-` and removed afterwards, except where noted.

| Spike | Question | Answer |
| --- | --- | --- |
| 0.0 | Can the toolset reach and sign in to Ops? | **Yes** |
| 0.1 | Can resources be created under the native `VMWARE` kind? | **Yes, but only through the vCenter adapter instance.** The custom `VcfOpsSynth` kind works through the adapter kind endpoint. |
| 0.2 | Do stats with 1, 7 and 30 days of history land and read back? | **Yes**, all three. Writes are asynchronous: expect 5 to 20 minutes before they read back. |
| 0.3 | Can super metrics, policies, views and dashboards be imported through the API? | **Super metrics: yes**, both direct and through content import. **Dashboards, views, policies: the content import endpoint accepts them, but import of hand-built items is not proven yet** (see 0.3 notes). |
| 0.4 | Does the importer run on a real RVTools export of `vc-mgmt-a`? | **Not run yet.** Waiting for an export. |

### 0.0 Connectivity

- `Test-NetConnection ops-a.site-a.mars.local -Port 443` succeeded.
- `pwsh ./bin/vcfops-synth.ps1 connect-test` printed `VCF Operations 9.1.1.0` and a token valid for about six hours. Exit code 0.
- Config: a local `config/lab.json` (gitignored) with `operations.fqdn` set to the lab FQDN and `skipCertificateCheck: true`, as Holodeck uses self-signed certificates. `VCFOPS_PASSWORD` is set in-process only.

### 0.1 Native versus custom adapter kind

| Call | Result |
| --- | --- |
| `POST api/resources/adapterkinds/VMWARE` | **400**, `apiErrorCode 1514`: "The Adapter Kind "VMWARE" specified is not of OPENAPI type." |
| `POST api/resources/adapterkinds/VcfOpsSynth` | **201**. The `VcfOpsSynth` kind did not exist beforehand and was created on first use with `adapterKindType: OPENAPI`. |
| `POST api/resources/adapters/{vCenter adapter instance id}` without `VMEntityName` | **422**, `apiErrorCode 1505`: "The resource identifiers "VMEntityName" are mandatory". |
| `POST api/resources/adapters/{vCenter adapter instance id}` with `VMEntityObjectID`, `VMEntityVCID` and `VMEntityName` | **201**. Read back as `VMWARE/VirtualMachine`, state `STARTED`, health GREY, owned by the `vc-mgmt-a` adapter instance. |

The vCenter adapter instance id comes from `GET api/adapters?adapterKindKey=VMWARE`. The identifier set comes from `GET api/adapterkinds/VMWARE/resourcekinds/VirtualMachine`.

Consequences for the design:

- Objects that must look native (so that built-in vSphere dashboards, views and policies apply to them) can be created under `VMWARE`, but only by attaching them to a real vCenter adapter instance. That adapter instance may treat them as stale because vCenter does not report them. How long they survive a collection cycle needs a longer soak before we rely on this path.
- The `VcfOpsSynth` custom kind is the safe default: it is self-contained and needs no adapter instance.

### 0.2 Historical stats

Pushes to `POST api/resources/stats/adapterkinds/VcfOpsSynth?disableAnalyticsProcessing=true`, body `resource-stat-content` with one `stat-contents` entry per key, 5-minute samples. Each push returned **200** in under five seconds.

| Key | History | Points | Read back via `GET api/resources/{id}/stats?statKey=...&begin=...` |
| --- | --- | --- | --- |
| `cpu|usage_average` | 1 day | 288 | 288 points, full range |
| `mem|usage_average` | 7 days | 2,016 | 2,016 points, full range |
| `synth|spike_metric` | 30 days | 8,640 in one call | 8,640 points, full range (2026-09-15 to 2026-10-15) |

Notes:

- **Writes are queued.** A 200 means accepted, not stored. The 1-day and 7-day series read back within about 10 minutes, the 30-day series after about 14 minutes, and the follow-up pushes after about 17. Stat keys show up in `GET api/resources/{id}/statkeys` before their points do. The toolset should push, then verify by polling, rather than reading back straight away.
- **Batch size.** 8,640 points for one key in one call was accepted and stored in full, so batching by time is not needed at this scale. A follow-up test pushed 30 days as five 7-day chunks (8,640 points read back), a 14-day single push (4,032) and a 1-day push dated 29 to 30 days back (288). All three read back in full about 17 minutes after the push, so chunking and single calls behave the same and data a month old is kept. The toolset should cap one call at about 10,000 points per key (the largest size tested) and allow up to 20 minutes for verification.
- `GET api/resources/stats/latest` shows only the newest sample of each key. It is not a check that history landed.
- Not tested: pushing stats onto the `VMWARE` object through `POST api/resources/{id}/stats`.

### 0.3 Content: super metrics, policies, views, dashboards

Endpoints on 9.1:

| Endpoint | Result |
| --- | --- |
| `GET api/policies` | 200, lists 18 policies |
| `GET api/supermetrics` | 200 |
| `GET/POST api/content/operations/export`, `GET api/content/operations/export/zip` | 200 / 202. Asynchronous. Poll until `state` is `FINISHED`, then download the zip. |
| `GET/POST api/content/operations/import` (multipart, field `contentFile`, `?force=true`) | 200 / 202. Asynchronous. Poll until `state` is `FINISHED`. `operationSummaries` gives imported, skipped and failed counts per content type. |
| `internal/views`, `internal/dashboards` | 403 for the admin user without the internal API header. Not used. |

Content types the export accepts (from the 400 for an unknown type): `VIEW_DEFINITIONS, REPORT_DEFINITIONS, DASHBOARDS, REPORT_SCHEDULES, CUSTOM_METRICGROUPS, POLICIES, ALERT_DEFINITIONS, SYMPTOM_DEFINITIONS, ... CUSTOM_GROUPS, SUPER_METRICS, ...`. Request body: `{"scope":"CUSTOM"|"ALL","contentTypes":[...]}`.

Super metrics, **yes**:

1. `POST api/supermetrics` with `name: Synth-spike03-sm` and a formula over `VcfOpsSynth/VirtualMachine mem|usage_average` returned **201**.
2. Exported with `contentTypes: ["SUPER_METRICS"]`. The zip holds `configuration.json`, `supermetrics.json` (keyed by id) and a `*.v1` file containing the owner's user id.
3. Deleted the super metric (`DELETE api/supermetrics/{id}` returned 204, then GET returned 404), imported the zip, and the summary showed `SUPER_METRICS imported 1`. The super metric came back with the same id.
4. Edited the zip by hand (new id and name, `Synth-spike03-sm-authored`), then re-zipped and imported it: **imported 1**. Ops kept the name but assigned its own id, so the toolset must look content up by name after import, not by the id it wrote.

Dashboards, views and policies, **not proven yet**:

- An `ALL` export of `DASHBOARDS, VIEW_DEFINITIONS, POLICIES` finished in about a minute and showed the layout the toolset would need to generate:
  - `policies.xml`: `PolicyContent/Policies/Policy` elements keyed by `key`, with `parentPolicy`.
  - `views.zip`: `content.xml` plus `resources/content*.properties`.
  - `dashboards/{owner user id}`: an inner zip containing `dashboard/dashboard.json`, with a `dashboards` array, and `dashboard/resources/*.properties`.
  - `dashboardsharings/{owner user id}`, `usermappings.json`, `configuration.json`, with counts per type.
- A hand-built bundle with one cloned `Synth-` policy (new `key`) went through import with `POLICIES skipped 1`. The cloned dashboard in that bundle was empty because of a script bug, so the `DASHBOARDS` count was 0. The corrected run was not done in this session. The next step is to rebuild the bundle with one dashboard and one policy, import it, and check the reason for the skip in `operationSummaries[].infoMessages`.

### 0.4 RVTools import

Not run. Needs an RVTools export of `vc-mgmt-a`. Then:

```
pwsh ./bin/vcfops-synth.ps1 import <export.xlsx or CSV folder>
```

### Clean-up

Test objects created during the spikes: resources `Synth-spike01-vm-custom` (`VcfOpsSynth`) and `Synth-spike01-vm-native` (`VMWARE`, under the `vc-mgmt-a` adapter instance), and super metrics `Synth-spike03-sm` and `Synth-spike03-sm-authored`. Remove them with `DELETE api/resources/{id}` and `DELETE api/supermetrics/{id}`. Find them by name with `GET api/resources?name=Synth-` and `GET api/supermetrics?name=Synth-`.
