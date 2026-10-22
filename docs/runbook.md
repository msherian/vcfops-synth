# Runbook

## Running from the container

The image `ghcr.io/msherian/vcfops-synth` runs every command the script does. It reads `lab.json` from `/config` and keeps the inventory, rubrics and backfill progress in `/data`, so both are bind mounts. Nothing secret goes into the image or `lab.json`.

### Folders

```text
config/lab.json          from config/lab.example.json; set operations.fqdn
config/tiering.json      from config/tiering.example.json (import only)
data/rvtools.xlsx        the RVTools export (import only)
data/rubrics/            the rubrics captured from this lab (spike 0.5); seed and backfill need them
data/inventory.json      written by import
data/state.json          backfill progress, so a stopped run resumes
```

The rubrics and inventory hold real names, so they stay in `data/`, which is never committed. Copy `data/rubrics/` from the machine that captured them.

### Run as your own user

The image runs as a user with uid 999. On a Linux host it cannot write a `data/` folder owned by you, and `import` stops with `Access to the path '/data/inventory.json' is denied`. Pass your own uid and gid:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD/config:/config" -v "$PWD/data:/data" \
  ghcr.io/msherian/vcfops-synth plan
```

Docker Desktop on Windows and macOS maps bind-mount ownership itself. There, `--user` should not be needed, though this hasn't been tested yet.

### Sign in with the VCF installer credentials file

Mount the file read-only and point `VCFOPS_CREDENTIAL_FILE` at it. It supplies the VCF Operations host, account and password, so nothing else is needed:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD/config:/config" -v "$PWD/data:/data" \
  -v "$HOME/vcf-installer-creds.json:/run/secrets/vcf-creds.json:ro" \
  -e VCFOPS_CREDENTIAL_FILE=/run/secrets/vcf-creds.json \
  ghcr.io/msherian/vcfops-synth connect-test
```

- The container's user must be able to read the file. If it can't, sign-in stops with `cannot be read`; check the file's owner and mode.
- `config` prints the host it picked from the file, but never the password.
- Alternatives:
  - a password file (`-e VCFOPS_PASSWORD_FILE=/run/secrets/ops-pass` with that file mounted);
  - a Docker secret (`-e VCFOPS_SECRET_NAME=ops-pass`);
  - `VCFOPS_PASSWORD` in the environment, which leaves the password visible in `docker inspect`.

On PowerShell (Windows), replace `$PWD/...` with `${PWD}/...` and `$HOME` with `$env:USERPROFILE`. Write each `docker run` on one line, or end lines with a backtick instead of `\`.

### Before you start (testers)

Read these before pointing the image at a VCF Operations instance:

- **Use a lab, not production.** Seed creates about as many objects as the RVTools export holds, and content publishes groups, policies, alerts, views and reports. Views and dashboards cannot be deleted through the API.
- **The holder adapter instance.** Seed creates a VMWARE adapter instance called `vcfops-synth holder - do not start` (`seed.adapterInstance`) and puts the whole synthetic estate under it. It has a vCenter address that cannot resolve and a placeholder credential. **Never start it.** Starting it makes it look for its vCenter, and every object under it is marked not existing. It may show as not collecting; that is expected.
- **Not existing means deleted after 7 days.** Operations deletes objects that stay not existing once the Deleted Objects window in Global Settings passes (168 hours by default). Do not seed under a real vCenter adapter instance: when it restarts it marks every object its vCenter does not have as not existing, groups empty out, and a week later the objects are gone. Seed warns if the instance you name collects.
- **Expect retries on a small Operations.** Backfill keeps each post under `-MaxSamples` and halves it when Operations refuses it, retrying with growing waits. The summary lists objects that were refused, or answered but not stored; run backfill again to fill them in.
- **Clean up with reset.** `reset` reports only; `reset -Force` deletes the seeded objects (found by tag and identifier, never by name), and `-IncludeContent` also deletes the Synth- groups, policies, alerts, symptoms and super metrics. Views, dashboards and the holder instance stay; delete those in the UI.
- **Report problems** with the command, the summary lines and the Operations version. Leave out host names, object names and credentials.

### Seed and backfill

Check first with dry runs, then run the commands for real:

```bash
opts=(--rm --user "$(id -u):$(id -g)" -v "$PWD/config:/config" -v "$PWD/data:/data"
      -v "$HOME/vcf-installer-creds.json:/run/secrets/vcf-creds.json:ro"
      -e VCFOPS_CREDENTIAL_FILE=/run/secrets/vcf-creds.json)
img=ghcr.io/msherian/vcfops-synth

docker run "${opts[@]}" "$img" seed -DryRun
docker run "${opts[@]}" "$img" seed
docker run "${opts[@]}" "$img" backfill -DryRun
docker run "${opts[@]}" "$img" backfill -Concurrency 2
```

- **Resuming:** backfill saves its progress to `/data/state.json`. If the container stops, the same command resumes where it left off; `-Restart` starts afresh.
- **Long runs:** run detached (`-d --name synth-backfill` in place of `--rm`) and follow progress with `docker logs -f synth-backfill`.
- **Memory:** on a small host such as 8 GB, use `-Concurrency 2`. Also watch the first minutes with `docker stats`. On 15 October 2026 a backfill at concurrency 4 on the 8 GB jump host ran out of memory; the engine has streamed its requests since then.

### Content, live feed and scenarios

```bash
docker run "${opts[@]}" "$img" content -DryRun
docker run "${opts[@]}" "$img" content
docker run -d --name synth-feed --restart unless-stopped --user "$(id -u):$(id -g)" \
  -v "$PWD/config:/config" -v "$PWD/data:/data" \
  -v "$HOME/vcf-installer-creds.json:/run/secrets/vcf-creds.json:ro" \
  -e VCFOPS_CREDENTIAL_FILE=/run/secrets/vcf-creds.json "$img" feed
docker run "${opts[@]}" "$img" scenario -Start S1
docker run "${opts[@]}" "$img" scenario -Stop all
```

- `feed` pushes a point every five minutes until stopped and keeps its place in `/data/state.json`, so a restarted container never pushes a point twice. Between pushes it is quiet; that is not a hang.
- A running feed picks up scenario changes on its next cycle.

### Clean up

```bash
docker run "${opts[@]}" "$img" reset                          # report only
docker run "${opts[@]}" "$img" reset -Force -IncludeContent
docker rm -f synth-feed
```

### Name resolution

The container has to resolve the VCF Operations host name. If the lab's DNS is only known to the host, pass `--dns <lab DNS server>`, or `--add-host <fqdn>:<address>`. When the name doesn't resolve, sign-in fails with `Name or service not known (<fqdn>:443)`.

### Tested

On 16 October 2026, an image built from main (df50e90) was tested with the invented fixture in `tests/fixtures/rvtools-4x`. It was built locally without ImportExcel, so only CSV import was covered:
- the `version`, `config`, `import` (CSV), `plan` and `connect-test` commands ran;
- the `--user` fix and the credentials-file mount behaved as described above.

Not tested yet:
- running the image against the lab;
- Docker Desktop on Windows.


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
| 0.4 | Importer on a real RVTools export of vc-mgmt-a | Yes, after a fix for empty sheets; networks, virtual disks and folders are not imported yet |
| 0.5 | Synthetic objects identical to a real one (rubric) | Yes for stat keys and properties; collection status still differs |
| 0.6 | A synthetic vCenter tree with VMs under synthetic parents | Yes; relationships survive vCenter collection |

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

Export: RVTools 4.7.1.4 command line on the jump host, `RVTools.exe -u administrator@vsphere.local -p _RVToolsV3PWD<DPAPI blob> -s vc-mgmt-a.site-a.mars.local -c ExportAll2xlsx -d <data folder> -f rvtools-vc-mgmt-a.xlsx`. The password is encrypted with DPAPI for the current user, as `RVToolsPasswordEncryption.ps1` does, so it never appears in clear on a command line. The export (27 sheets, 131 KB) stays in the gitignored `data/` folder.

Import: `pwsh ./bin/vcfops-synth.ps1 import data/rvtools-vc-mgmt-a.xlsx` first failed with `Cannot bind argument to parameter 'Header' because it is null`. The `vSnapshot` sheet has a header row and no data, because vc-mgmt-a has no snapshots, and the xlsx reader returned null headers for it. Fixed in `Read-SynthRvtoolsSheet` (commit "Read xlsx tabs that have a header row but no data", on the Phase 2 branch). After the fix:

```
15 VMs (15 powered on) on 4 hosts in 1 cluster, 1 datastore, 1 datacenter
Tiers: Bronze 15
Profiles: business-hours 15
Source: xlsx, RVTools 4.7.1.4, anonymised
Skipped 4 row(s): 4 template.
```

All 92 Pester tests pass with the fix.

Gaps against the new requirement that the synthetic estate mirrors the import, networks included. The export holds these sheets, but the inventory model does not use them yet:

- `vNetwork` (VM network adapters and their port groups), `dvSwitch`, `dvPort`, `vSwitch` and `vPort` (switches and port groups), and `vSC_VMK` (host VMkernel ports): needed for synthetic networks and the VM to port group links.
- `vDisk` (virtual disks): needed to expand the per-disk metrics (`virtualDisk:scsiX:Y|...`) in each VM's rubric. `vPartition`, which is imported, holds guest file systems, not virtual disks.
- `vNIC` and `vHBA` (host adapters), `vRP` (resource pools) and the VM folder column of `vInfo`.

Phase 3 extends the importer with these before seeding.

### 0.5 Rubrics: synthetic objects that match real ones

Requirement: every synthetic object carries exactly the metrics and properties of a real object of the same kind. The rubric for each kind is captured from a real object in the lab.

Capture, per kind: `GET /api/resources?adapterKind=VMWARE&resourceKind={kind}` to pick a live object under the vc-mgmt-a adapter instance, then `GET /api/resources/{id}/statkeys`, `GET /api/resources/stats/latest?resourceId={id}` and `GET /api/resources/{id}/properties`. The rubric files hold real names and values, so they live in `data/rubrics/` (gitignored) and are captured per lab, never committed.

| Kind | Rubric source | Stat keys | Properties |
|---|---|---|---|
| VirtualMachine | auto-platform-a-nn4ks | 657 | 399 |
| HostSystem | esx-03a | 249 | 115 |
| ClusterComputeResource | cluster-mgmt-01a | 237 | 39 |
| Datastore | vsan-mgmt-01a | 60 | 20 |
| Datacenter | dc-mgmt-a | 150 | 8 |
| VMFolder | Discovered virtual machine | 15 | 8 |
| DistributedVirtualPortgroup | vsan-vds02-mgmt-01a | 20 | 26 |
| VmwareDistributedVirtualSwitch | vds02-mgmt-01a | 45 | 9 |

The Datastore rubric is a vSAN datastore, which has no `datastore|totalReadLatency_average` or `datastore|totalWriteLatency_average`. VMFS and NFS datastores have both and the Datastore latency alert reads them, so the seed adds them to every synthetic datastore, valued from the LiveOptics latency of the VMs on it (weighted by their IOPS).

About 300 of the VM's stat keys and most of its properties are per instance (`virtualDisk:scsi0:N|...`, NICs, guest file systems). So a synthetic VM's rubric has to be expanded from its own disk and NIC counts (from RVTools), not copied blindly from one reference VM.

Test: created `Synth-spike05-vm01` as `VMWARE/VirtualMachine` under the vc-mgmt-a adapter instance (`POST /api/resources/adapters/{id}`, all six VM identifiers, the real vCenter's `VMEntityVCID`). Then pushed all 657 stat keys (`POST /api/resources/{id}/stats`, `stat-content`) and all 399 properties (`POST /api/resources/{id}/properties`, `property-content`, numbers as `data` and strings as `values`, with the reference VM's name and id replaced). After one collection cycle:

- Stat keys: 657 on both, **none missing, none extra**.
- Properties: 399 on both, **none missing, none extra, no values differing** (apart from the substituted name).
- Operations computed health (100, GREEN), risk, efficiency and workload badges for it, as for a real VM.

Still different from a real VM:

1. **Collection status.** A live real VM shows `STARTED/DATA_RECEIVING` from its vCenter adapter. The synthetic VM shows `NONE` from the vCenter adapter and `DATA_RECEIVING` from the "VCF Operations API" adapter instance, because that is where pushed data arrives. The UI shows this as a collection state, and it cannot be changed through the API.
2. **Relationships.** A real VM has a host, datastore, folder and port group as parents; the synthetic VM had none. Decided: the toolset builds a fully synthetic tree from the RVTools import, and real lab objects serve only as rubrics. Proven in 0.6.
3. **Freshness.** One pushed sample makes the keys exist, but the values go stale unless a live feed (Phase 6) keeps pushing every collection cycle.

Note on the reference VM: auto-platform-a-nn4ks went `NOT_EXISTING` at 17:08 UTC during the test, because the VCF Automation platform replaced that node VM. The rubric was captured before that, but the toolset should pick its rubric source from objects in `STARTED/DATA_RECEIVING` state and capture again when the source disappears.

### 0.6 A synthetic tree under the vCenter adapter instance

Created, under the vc-mgmt-a adapter instance and each filled from its rubric: `Synth-spike06-dc` (Datacenter), `Synth-spike06-cl` (ClusterComputeResource), `Synth-spike06-esx01` (HostSystem, with `isPingEnabled`), `Synth-spike06-ds01` (Datastore, with `DataStrorePath`, spelt that way in the identifier) and `Synth-spike06-pg01` (DistributedVirtualPortgroup). Identifiers: `VMEntityObjectID` in the vCenter style (`host-90601`, `domain-c90601` and so on), the real vCenter's `VMEntityVCID`, and `VMEntityName`.

Linked with `POST /api/resources/{parentId}/relationships/children`, body `{"uuids":["<childId>"]}`, which returns 204: datacenter > cluster > host > VM, datacenter > datastore, host > datastore, datastore > VM, port group > VM.

After two vCenter collection cycles (13 minutes):

- Every link was still there (`GET /api/resources/{id}/relationships/parents` and `/children`). The vCenter adapter does not remove relationships it did not create.
- All six objects were `STARTED` and GREEN.
- Operations also placed the synthetic datastore in its own `vSAN Datastores` group, as it does for real vSAN datastores, so derived membership works from the pushed properties.
- Stat keys: cluster 235 of 237 and host 245 of 249. The missing ones are text-valued metrics (`configuration|dasConfig|ha_cluster_error`, `health|reports|hostd|state` and similar), whose latest value has no number. They have to be pushed with `values` instead of `data`. Phase 3 handles them.

### Left behind

Kept on purpose for an overnight soak (does the vCenter adapter leave them alone?), then removed with `DELETE /api/resources/{id}`: `Synth-spike05-vm01` and the six `Synth-spike06-*` objects.

These two could not be removed through the API and are still in the lab:

- View `Synth-spike03-view` (Views, delete in the UI)
- Dashboard `Synth-spike03-dash` (Dashboards, delete in the UI)

The `VcfOpsSynth` adapter kind also stays, with no objects in it.
