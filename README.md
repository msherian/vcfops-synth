# vcfops-synth

Builds a convincing VCF 9.1 Operations Day-2 demo from a customer's RVTools export. It recreates that estate as objects in VCF Operations, pushes believable history and live metrics for them through the Suite API, and publishes custom groups, tiered policies, symptoms, alerts and dashboards as code. Where data cannot be injected through the API, an optional live-load mode drives UPSA and small load VMs in the lab instead.

Everything ships as one Docker image, published to `ghcr.io/msherian/vcfops-synth`. The design plan, scenario catalogue and build order are in [docs/design.md](docs/design.md).

## Status

The current release is **v0.1.1** (`ghcr.io/msherian/vcfops-synth:0.1.1`, or `:0.1` to follow patch releases; `latest` tracks `main`). Phases 0 to 8 are done: the image, CLI and Suite API sign-in, the RVTools and LiveOptics importer, seeding the estate into VCF Operations, 30 days of backfilled history, groups and tiered policies, the live feed and scenarios, symptoms, alerts, super metrics, views, reports and dashboards, and a reset that leaves nothing behind. Only Phase 9, the optional live-load mode, is still to come; its command stops with exit code 3 and names the phase. Lab results and what they taught us are under [Results in the lab](#results-in-the-lab), and what is still open under [Known gaps](#known-gaps).

| Command | What it does | Phase |
|---|---|---|
| `help`, `version` | Usage and versions | 1 |
| `config` | Validates `lab.json` and prints the merged settings | 1 |
| `connect-test` | Signs in to VCF Operations and prints its version | 1 |
| `plan` | Dry run: what each stage would do | 1 |
| `import` | RVTools export to inventory model | 2 |
| `seed` | Create the estate in VCF Operations under a holder adapter instance of its own | 3 |
| `reset` | Remove the objects seed created (and, with `-IncludeContent`, the toolset's content) | 8 |
| `backfill` | Push generated history for every numeric metric | 4 |
| `content` | Custom groups, tier policies, symptoms, alerts, super metrics, list views, reports and dashboards | 5 to 7 |
| `feed` | Live point every interval with analytics on, carrying on from the backfill | 6 |
| `scenario` | Start, stop and list scenario overlays (S1 to S4, S8) | 6 |
| `live-load` | Optional UPSA and load VMs | to come (9) |

## Quick start

```bash
mkdir -p config data
cp config/lab.example.json config/lab.json      # then set operations.fqdn for your lab
export VCFOPS_PASSWORD='...'                     # never stored in lab.json

docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/config:/config" -v "$PWD/data:/data" -e VCFOPS_PASSWORD \
  ghcr.io/msherian/vcfops-synth:0.1.1 config
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/config:/config" -v "$PWD/data:/data" -e VCFOPS_PASSWORD \
  ghcr.io/msherian/vcfops-synth:0.1.1 connect-test
```

Then import an RVTools export (xlsx, or a folder of its CSV files) into the inventory model:

```bash
cp config/tiering.example.json config/tiering.json   # then edit the rules for this estate
cp ~/Downloads/RVTools_export_all.xlsx data/rvtools.xlsx

docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/config:/config" -v "$PWD/data:/data" ghcr.io/msherian/vcfops-synth:0.1.1 import
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/config:/config" -v "$PWD/data:/data" ghcr.io/msherian/vcfops-synth:0.1.1 plan
```

`--user` lets the container write to a `data/` folder you own on a Linux host. Signing in with the VCF installer credentials file, seeding and backfilling from the container, and resuming a stopped run are in [docs/runbook.md](docs/runbook.md#running-from-the-container).

The FQDN in `lab.example.json` is a placeholder in Holodeck's `site-a.vcf.lab` domain; use the name of your VCF Operations instance.

## Configuration

`lab.json` holds everything except the password. Values it leaves out take the defaults in `src/VcfOpsSynth/Private/ConfigDefaults.ps1`.

| Setting | Default | Meaning |
|---|---|---|
| `operations.fqdn` | (required) | VCF Operations host name, no scheme |
| `operations.username` / `authSource` | `admin` / `LOCAL` | Account used for the Suite API |
| `operations.skipCertificateCheck` | `false` | Set `true` for Holodeck's self-signed certificates |
| `adapterKind.key` | `VcfOpsSynth` | Push adapter kind the synthetic objects live under |
| `prefix` | `Synth-` | Prefix on content the toolset creates (groups, policies, dashboards). Seeded objects keep their inventory names; they are found by tag and identifier |
| `timeZone` | `Europe/Dublin` | IANA zone for business-hours patterns |
| `intervalMinutes` | `5` | Sample interval for history and the live feed |
| `backfillDays` | `30` | Days of history to push |
| `paths.inventory` | `/data/inventory.json` | Where `import` writes the inventory model |
| `import.source` | `/data/rvtools.xlsx` | RVTools xlsx, or a folder of RVTools CSV files |
| `import.tiering` | `/config/tiering.json` | Tiering rules; without them every VM is Bronze |
| `import.anonymise` | `true` | Replace names with pseudonyms; `-NoAnonymise` (or `VCFOPS_SYNTH_NO_ANONYMISE=true`) overrides it for one run |
| `liveLoad.*` | off, 6 VMs, 2 UPSA pairs | Optional live-load mode and its caps |

Overrides for one run, as parameters or environment variables: `-Fqdn`/`VCFOPS_FQDN`, `-Username`/`VCFOPS_USERNAME`, `-AuthSource`/`VCFOPS_AUTHSOURCE` and `-ConfigPath`/`VCFOPS_SYNTH_CONFIG` (path to `lab.json`). The password is never stored in `lab.json`: it comes from `-Password`/`VCFOPS_PASSWORD`, `-PasswordFile`/`VCFOPS_PASSWORD_FILE`, `-SecretName`/`VCFOPS_SECRET_NAME` for a Docker secret (`/run/secrets/<name>`), or `-CredentialFile`/`VCFOPS_CREDENTIAL_FILE`, the VCF installer credentials file, which also gives the host and account. Any parameter wins over every variable. Among parameters, and again among variables, a single value (`-Fqdn`, `-Username`, a password) beats the credentials file, and the password beats the file, which beats the secret. See [Parameters and environment variables](#parameters-and-environment-variables).

## Importing RVTools

`import` reads vInfo and vHost (required) and vCPU, vMemory, vDisk, vPartition, vNetwork, vSnapshot, vTools, vRP, vCluster, vHBA, vNIC, vSwitch, vPort, dvSwitch, dvPort, vSC_VMK, vDatastore and vMetaData when present. It accepts the xlsx export or the CSV export (`RVTools -c ExportAll2csv`, files named `RVTools_tab<tab>.csv`, comma or semicolon separated), and both RVTools 3.x (`MB`) and 4.x (`MiB`) column names. The column map is `src/VcfOpsSynth/Private/RvtoolsColumns.ps1`.

The inventory model (schema version 3) holds the whole estate the toolset recreates as synthetic objects: datacenters, clusters, hosts, datastores, standard and distributed switches, networks (port groups), resource pools, folders and VMs. It carries placement (VM to host, datastores, folder, resource pool and networks; host to switches), sizing, configuration (virtual disks, network adapters, guest OS, hardware version, Tools status, snapshots; host NICs, HBAs and VMkernel adapters) and baselines from RVTools' single usage sample: VM CPU and active memory percent, guest disk use, host CPU and memory percent, and datastore use. IP addresses, DNS names, MAC addresses and WWNs are never read. Templates and SRM placeholders are skipped, and rows that cannot be used are listed by tab and row number in `report.skipped`, so one bad row never stops an import.

### Tiering rules

`tiering.json` gives each VM a tier (Gold, Silver or Bronze), an application and a workload profile (steady, business-hours, batch, bursty, idle or saturated). Rules run in order against the real values from the export; for each of tier, application and profile, the first matching rule that sets it wins. A rule matches when every regular expression in its `match` block matches, ignoring case. Match fields are `name`, `cluster`, `host`, `datacenter`, `folder`, `resourcePool`, `annotation`, `guestOs`, `powerState`, and `attribute:<column>` for any other vInfo column, such as a vCenter custom attribute.

```json
{ "match": { "cluster": "^PROD", "annotation": "tier ?1|critical" }, "tier": "Gold" }
```

VMs no rule profiles are profiled from their usage: idle under 5% CPU and 10% active memory, saturated from 80% CPU or 85% active memory, business-hours otherwise, and off when powered off. The thresholds are under `profiles` in the same file. See `config/tiering.example.json`.

## Parameters and environment variables

The CLI takes PowerShell parameters after the command, and every parameter can also come from an environment variable, which suits `docker run -e` and scheduled containers. A parameter on the command line wins over its variable, which wins over `lab.json`. Switches take `true`/`false`, `yes`/`no`, `on`/`off` or `1`/`0` in a variable. Variables for other commands are ignored; a parameter a command does not take, an unknown argument or a bad value stops with exit code 2.

| Parameter | Variable | Commands | Meaning |
|---|---|---|---|
| (first argument) | `VCFOPS_SYNTH_COMMAND` | all | The command; default `help` |
| `-ConfigPath` | `VCFOPS_SYNTH_CONFIG` | all | `lab.json`; default `/config/lab.json` |
| `-Source` (or second argument) | `VCFOPS_SYNTH_SOURCE` | import | RVTools xlsx or CSV folder; default `import.source` |
| `-Output` | `VCFOPS_SYNTH_OUTPUT` | import | Inventory model to write; default `paths.inventory` |
| `-Tiering` | `VCFOPS_SYNTH_TIERING` | import | Tiering rules; default `import.tiering` |
| `-Performance` | `VCFOPS_SYNTH_PERFORMANCE` | import | LiveOptics VMware workbook; default `import.performance` |
| `-NoAnonymise` | `VCFOPS_SYNTH_NO_ANONYMISE` | import | Keep real names |
| `-Adapter` | `VCFOPS_SYNTH_ADAPTER` | seed, backfill, feed, scenario | Holder adapter instance; default `seed.adapterInstance` (`vcfops-synth holder - do not start`) |
| `-Refresh` | `VCFOPS_SYNTH_REFRESH` | seed | Push properties and stats to objects already there |
| `-DryRun` | `VCFOPS_SYNTH_DRY_RUN` | seed, backfill, content, feed, reset | Report only; change nothing |
| `-Force` | `VCFOPS_SYNTH_FORCE` | reset | Delete for real |
| `-IncludeContent` | `VCFOPS_SYNTH_INCLUDE_CONTENT` | reset | Also delete the prefixed content |
| `-ApplianceSsh` | `VCFOPS_SYNTH_APPLIANCE_SSH` | reset | `user@host` of the Operations appliance; with `-IncludeContent`, delete the views, reports and dashboards with ops-cli (key first, else ssh asks for the password) |
| `-SshKey` | `VCFOPS_SYNTH_SSH_KEY` | reset | Private key for `-ApplianceSsh`; default `/keys/id_ssh` when that file exists (the container's read-only key mount), else ssh's own |
| `-ImportField` | `VCFOPS_SYNTH_IMPORT_FIELD` | content | Multipart field the content bundle is sent in; default `contentFile` |
| `-Days` | `VCFOPS_SYNTH_DAYS` | backfill | Days of history; default `backfillDays` |
| `-Kinds` | `VCFOPS_SYNTH_KINDS` | backfill | Comma-separated resource kinds |
| `-MaxVms` | `VCFOPS_SYNTH_MAX_VMS` | backfill | First n VMs only, for a pilot |
| `-Concurrency` | `VCFOPS_SYNTH_CONCURRENCY` | backfill, feed | Objects posted at once; default 4 (feed 8) |
| `-MaxSamples` | `VCFOPS_SYNTH_MAX_SAMPLES` | backfill | Samples per post, halved when refused; default 100000 |
| `-Restart` | `VCFOPS_SYNTH_RESTART` | backfill | Forget saved progress |
| `-Cycles` | `VCFOPS_SYNTH_CYCLES` | feed | Stop after n cycles; default runs until stopped |
| `-Start` | `VCFOPS_SYNTH_START` | scenario | Scenario to start: S1, S2, S3, S4 or S8 |
| `-Stop` | `VCFOPS_SYNTH_STOP` | scenario | Scenario to stop, or `all` |
| `-Target` | `VCFOPS_SYNTH_TARGET` | scenario | Object to run it on, by inventory ID or name |
| `-RampMinutes` | `VCFOPS_SYNTH_RAMP_MINUTES` | scenario | Minutes to full effect; default 10 |
| `-Fqdn` | `VCFOPS_FQDN` | config, connect-test, plan, seed, backfill | VCF Operations host name; default `operations.fqdn` |
| `-Username` | `VCFOPS_USERNAME` | config, connect-test, plan, seed, backfill | Account; default `operations.username` |
| `-AuthSource` | `VCFOPS_AUTHSOURCE` | config, connect-test, plan, seed, backfill | Authentication source; default `operations.authSource` |
| `-Password` | `VCFOPS_PASSWORD` | connect-test, seed, backfill | The password; on a command line it shows in process lists and history, so prefer the next two |
| `-PasswordFile` | `VCFOPS_PASSWORD_FILE` | connect-test, seed, backfill | A file holding the password |
| `-SecretName` | `VCFOPS_SECRET_NAME` | connect-test, seed, backfill | A Docker secret holding the password, read from `/run/secrets/<name>` |
| `-CredentialFile` | `VCFOPS_CREDENTIAL_FILE` | config, connect-test, plan, seed, backfill | The VCF installer credentials file (JSON): host, account and password from its VCF Operations entry and Administrator credentials; `-Fqdn` picks one when it lists several |
| `-AnonymisationKey` | `VCFOPS_SYNTH_ANON_KEY` | import | Key for stable IDs and pseudonyms; default `<paths.data>/anonymise.key` |

```bash
pwsh ./bin/vcfops-synth.ps1 backfill -Kinds VirtualMachine -MaxVms 25 -ConfigPath ./config/lab.json
pwsh ./bin/vcfops-synth.ps1 backfill -CredentialFile ~/Documents/vcf-installer-creds.json -ConfigPath ./config/lab.json
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/config:/config" -v "$PWD/data:/data" -e VCFOPS_PASSWORD \
  -e VCFOPS_SYNTH_COMMAND=seed -e VCFOPS_SYNTH_DRY_RUN=true ghcr.io/msherian/vcfops-synth
```
## Seeding

`seed -Adapter <holder adapter instance>` builds the inventory as VMWARE objects under that instance, foundations first: an optional Physical Data Center (`seed.physicalDatacenter`), datacenters (linked under the holder instance), clusters, datastores, hosts, distributed switches and port groups, VM folders and VMs. Standard switches and port groups, which VMWARE does not model, go under the `adapterKind.key` push kind. Because the rest are native VMWARE objects, the stock vSphere content (dashboards, capacity, alerts) treats them like real ones. Every relationship is worked out before anything is created.

Rubrics captured from real lab objects (`seed.rubrics`, default `<paths.data>/rubrics`) only say which metrics and properties each kind has. One exception: datastores also get `datastore|totalReadLatency_average` and `datastore|totalWriteLatency_average`, because the lab's rubric datastore is vSAN, which has no such keys, while VMFS and NFS datastores do; their values are the IOPS-weighted LiveOptics latency of the powered-on VMs on the datastore, so the Datastore latency alert can fire. Every value comes from the inventory (RVTools, LiveOptics), is derived from it (for example host use over capacity, cluster roll-ups), or is a neutral placeholder (`-`, `0`, `false`). Keys Operations computes itself (capacity analytics such as time and capacity remaining, badges, alert counts, workload scores, reclamation, rightsizing, sustainability and capacity profiles) are never pushed, so its own results are not masked. Capacity inputs (usable memory, memory demand, total and HA CPU and memory capacity, disk space over the datastores a host or cluster sees) come from the inventory and stay flat through the backfill. Objects keep their inventory names (`seed.prefix` is optional) and carry two vSphere tags in `summary|tag`: `seed.tag` (default `vcfops-synth-synthetic`) and `Project-<project>`, where the project is `seed.project` or the `YYYY.#### ... OPP-n` folder the export was imported from.

The holder (`seed.adapterInstance`, default `vcfops-synth holder - do not start`) is a VMWARE adapter instance of the toolset's own. Seed creates it when it is missing, with a vCenter address that cannot resolve (`synth.invalid`), a `VMEntityVCID` of its own, autodiscovery off and a placeholder credential, and never starts it. The estate must not go under a vCenter adapter instance that collects: when that adapter restarts it marks every object its vCenter does not return as not existing, and groups, policies and alerts then leave them out (seen in the lab on Operations 9.1.1; seed warns when the instance collects). Do not start the holder either, for the same reason. Operations deletes objects that stay not existing once the Deleted Objects window in Global Settings passes (168 hours by default).

Objects that already exist are found by their identifiers, not their names, and skipped; `-Refresh` pushes the planned properties and current stats to them again. `-DryRun` prints the plan.

## Backfill

`backfill` pushes `backfillDays` of history at `intervalMinutes` for every numeric metric of the seeded objects, with analytics processing off. Metrics LiveOptics measured (VM and host CPU, memory, IOPS, throughput, latency) match its average and peak exactly. The rest follow the object's workload curve around their current value, grow to it (space in use), stay flat (capacity, counts) or stay at zero (no source). Each VM's curve comes from its workload profile in `timeZone`, with seeded noise and incident windows; hosts, clusters, datastores, port groups and folders follow the sum of their VMs' curves, so peaks line up.

Progress is saved to `paths.state` after each batch, so a stopped run resumes over the same range; `-Restart` starts afresh. `-DryRun` counts objects, series and samples; `-Kinds` and `-MaxVms` limit a pilot run; `-Concurrency` sets how many objects post at once. Operations 9.1.1 in the lab refused posts of about 250,000 samples or more with HTTP 500, so posts hold at most `-MaxSamples` samples and a refused one is halved, for the rest of the batch too. For a busy Operations, each post is retried up to 10 times with waits growing from 2 seconds to 60, and objects still refused get two more passes at the end of the run, one at a time; any left after that are reported and picked up by the next run. Five minutes after the last post, the last point of each pushed object's first and last metric is read back: in the lab, Operations sometimes answered posts it then never stored, so such objects are reported as not stored and left for the next run. The summary also counts the objects that had a post refused. In the lab, 30 days for the 1,644 objects with numeric metrics is 224,943 series and 1.94 billion samples, about 550,000 to 590,000 a second at concurrency 4 to 6 (about an hour), and about 6 bytes a sample in the Operations database. Each progress line shows the time, the batch duration and the time left.

After a backfill, run `seed -Refresh`: history is posted with analytics off, and Operations only calculates capacity (time and capacity remaining) once points arrive with analytics on. Until the live feed exists (Phase 6), those figures stay at the last refreshed point.

Calibration follows LiveOptics's average and peak exactly, with two edge cases. Where the peak is no higher than the average, the series is flat at the average. Where the average is 0 but the peak is not (LiveOptics rounds small figures down), the series is zero apart from one spike at the object's busiest point, so its mean still rounds to 0. A VM's disk throughput also goes on its first disk, because Operations calculates a VM's total write throughput from its per-disk values and overwrites a pushed total. The average is over the whole week, so a business-hours object runs at about twice its average on weekday working hours (09:00 to 18:00 in `timeZone`) and well under it at night and at weekends.

## Results in the lab

| | |
|---|---|
| Seeded | 2,220 objects (11 kinds) and 6,788 relationships, matching the plan; parents survive a vCenter collection cycle |
| Backfilled | 30 days at 5 minutes: 1,644 objects, 224,943 series, 1.94 billion samples, no failures |
| LiveOptics check | 1,918 of 1,935 calibrated series (99%) match the LiveOptics average and peak, over 40 random VMs and all 89 hosts; every series has all 8,640 points, and all 44 per-kind samples pass |
| Capacity | after `seed -Refresh`, Operations calculates time and capacity remaining itself (for example 366 days and 35.8 % on a 16-core host) |
| Content | 13 custom groups, 4 policies, 27 symptoms, 5 recommendations, 11 alerts, 4 super metrics, 5 views, 2 reports and 2 dashboards, all named `Synth-` |
| Alerts | Scenarios S1 (noisy neighbour), S3 (storage latency, VMs and datastores) and S8 (host failure) raise their alerts and clear them when stopped |
| Reset | `reset -Force -IncludeContent -ApplianceSsh` removes every seeded object and every piece of `Synth-` content, views, reports and dashboards included; only the `VcfOpsSynth` adapter kind stays, since Operations never deletes an adapter kind |
| Docker validation (v0.1.0, 23 October 2026) | From a clean Operations 9.1.1, the image on Docker Desktop ran seed (2,220 objects), backfill (1,644 objects, 1.95 billion samples in 44 minutes, none refused), content and a full reset, with the live feed running as a detached container (`--restart unless-stopped`) |

Findings that shaped the code:

- **Never push keys Operations computes.** Capacity analytics (time and capacity remaining, recommended size), badges, alert counts, workload scores, reclamation, rightsizing, sustainability and capacity profiles come from Operations. Pushed as zero, they showed as 0 Days and 0 % remaining. The seed plan leaves them out.
- **Capacity keys are sizes, not activity.** `cpu|totalCapacity_average` ends in `_average` but is a capacity, so it stays flat through history.
- **Seeded objects are found by tag and identifier, not prefix.** They keep their inventory names and carry the `vcfops-synth` and project tags; their managed object IDs contain `-synth-`.
- **Memory:** a full plan and spec takes about 500 MB in one PowerShell process. On an 8 GB host the backfill and the verification were killed for low memory; 32 GB runs the whole sequence comfortably. On a small host, use `-Concurrency 2`.

## Known gaps

- **Rightsizing lists no VMs yet.** Operations builds its oversized and undersized recommendations from its own analytics history, which takes time to accumulate on live-fed data.
- **The four `Synth-` super metrics are created but not enabled in `Synth-Base`**, so the report column that uses them is empty.
- **Very high latency is real.** Datastore and VM latency follow LiveOptics as recorded, so an estate with very slow storage raises steady critical latency alerts on the objects concerned.
- **ops-cli on 9.1.1** has the slf4j packaging fault described under [Reset](#reset); the toolset works around it without changing the appliance.
- **Phase 9 live-load** (UPSA and Photon load VMs) is not built yet.

## Live feed and scenarios

`feed` pushes one point for every seeded object each `intervalMinutes`, with analytics processing on, so capacity, symptoms and alerts run on current data. Each series carries on from the backfill at the levels it set: the scaling is worked out once over the backfill's range, and the live points follow the same workload curves. A gap since the last push, or since the backfill ended, is filled first with analytics off (up to 24 hours). The feed runs until stopped; `-Cycles 1` pushes one cycle and exits, for a scheduled task every five minutes. Progress is saved in `paths.state`, so a restart never pushes a point twice.

`scenario` starts and stops overlays on chosen objects; a running feed picks the change up on its next cycle, ramping in over `-RampMinutes` (default 10). Without `-Target` each scenario picks a busy object.

| Scenario | Target | What changes |
|---|---|---|
| S1 noisy neighbour | host | Bronze VMs take 95 % CPU and are marked `vcfops-synth\|scenario`; Gold and Silver VMs there see 12 % ready and 15 % contention; the host demands 115 % |
| S2 memory pressure | host | Its VMs balloon 25 % and swap; the host runs at 98 % memory with contention |
| S3 storage latency | datastore | 45 ms read and write latency on the datastore and the VMs on it |
| S4 guest disk filling | VM | Each guest file system fills to 97 % of its capacity |
| S8 host failure | host | The host stops reporting and shows as not responding; the other hosts in its cluster take its load and the cluster loses its capacity |

```bash
pwsh ./bin/vcfops-synth.ps1 feed -ConfigPath ./config/lab.json
pwsh ./bin/vcfops-synth.ps1 scenario -Start S1 -ConfigPath ./config/lab.json
pwsh ./bin/vcfops-synth.ps1 scenario -Stop all -ConfigPath ./config/lab.json
```

## Content: groups and tier policies

`content` publishes, by name with the prefix (existing ones are updated in place, keeping their ids):

- **Groups:** `Synth-Estate` (every seeded VM, host, cluster and datastore, matched by the synthetic tag), `Synth-Tier-1-Gold`, `-2-Silver` and `-3-Bronze` (on `vcfops-synth|tier`), one `Synth-App-<application>` per application, and `Synth-Noisy-Neighbours`.
- **Policies:** `Synth-Base` on the estate group switches on every Synth- alert. `Synth-Tier-1-Gold`, `-2-Silver` and `-3-Bronze` inherit it, go on their tier groups, and rank above it, so a VM gets its tier's policy. Only seeded objects are in these groups; real objects keep the policies they had.

The tier policies come from an SLA matrix, the part of the design that carries to other customers (which VMs land in which tier is the customer's own tier rules). `config/sla.example.json` holds the built-in values; copy it and set `content.sla` in `lab.json` to change them:

| Tier | VM time remaining, warning / critical (days) | Cluster capacity buffer | Alerts switched off |
|---|---|---|---|
| Gold | 120 / 40 | 20% | none |
| Silver | 90 / 30 | 10% | none |
| Bronze | 30 / 10 | 0% | VM memory pressure |

The alerts carry the tier thresholds themselves (through `vcfops-synth|tier`), so the policies only switch alerts on or off. The capacity buffer is a cluster setting, so it only applies to clusters a tier policy is assigned to; today clusters get `Synth-Base`.

### Symptoms, alerts and super metrics

`content` also publishes the symptoms, alerts and super metrics that make the scenarios show up in Operations, by name with the content prefix; existing ones are updated in place and anything outside the prefix is never touched. Thresholds follow the tiers, read from the `vcfops-synth|tier` property seed writes, so one set of alerts covers every tier:

| Alert | Raised by | Warning | Critical |
|---|---|---|---|
| Gold VM CPU contention | S1 | ready above 3 % | above 5 % |
| Silver VM CPU contention | S1 | ready above 5 % | above 10 % |
| Gold, Silver, Bronze VM disk latency | S3 | above 10, 20, none ms | above 20, 40, 50 ms |
| VM memory pressure | S2 | ballooning above 10 % | swapping in |
| VM guest file system nearly full | S4 | above 90 % | above 95 % |
| Host memory pressure | S2 | | usage above 95 % with ballooning above 5 % |
| Host CPU overcommitted | S1 | | demand above 100 % |
| Host not responding | S8 | | connection state notResponding |
| Datastore latency | S3 | | read or write above 30 ms |

Each alert has a recommendation. The super metrics are VM CPU demand over allocation, the worst VM CPU ready and disk latency in each cluster, and the average VM health in each tier group; a policy must enable them before Operations computes them.

### Views, reports and dashboards

`content` then builds a content bundle, `<paths.data>/content-bundle.zip`, and imports it with force, so a re-run overwrites the views and reports by name. The bundle follows the layout of a VCF Operations 9.1.1 content export (`configuration.json`, `usermappings.json`, the `<id>L.v1` owner file, `views.zip`, `reports.zip`, `dashboards/<owner>`), and the signed-in user owns it. Each view, report, dashboard and widget has a fixed id worked out from its name. With `-DryRun` the bundle is written but not imported.

| View | Objects | Columns |
|---|---|---|
| VM tier list | VMs | Tier, application, cluster, vCPUs, memory, and over the last week CPU usage, CPU ready, memory usage, disk latency and CPU demand over allocation |
| Oversized VMs | VMs Operations flags as oversized | Tier, cluster, size, and CPU and memory usage over 30 days |
| Undersized VMs | VMs Operations flags as undersized | Tier, cluster, size, and peak CPU, ready and memory over 30 days |
| VM configuration hygiene | VMs | Tier, VMware Tools running and version, hardware version, guest OS, snapshot space |
| Cluster tier pressure | Clusters | CPU and memory usage over the last week, worst VM CPU ready and disk latency, capacity and time remaining |

| Report | Views |
|---|---|
| Weekly tier compliance | VM tier list, Cluster tier pressure |
| Rightsizing | Oversized VMs, Undersized VMs |

Reports open with a cover page and come as PDF and CSV. Super metric columns appear once the super metrics exist, since a view refers to a super metric by id.

| Dashboard | Widgets |
|---|---|
| Service tiers | VM tier list, with Cluster tier pressure below |
| Rightsizing and hygiene | Oversized VMs and Undersized VMs side by side, with VM configuration hygiene below |

Each widget shows its view on the `Synth-Estate` group, so it lists the seeded objects only. A dry run on a lab where that group does not exist yet leaves the dashboards out of the bundle, since they need its id.

## Reset

`reset` removes what seed created. It finds each planned object by kind and unique identifier, as seed does, never by name, and deletes it only when its `summary|tag` carries the synthetic tag (`seed.tag`, `vcfops-synth-synthetic` by default); an object with a matching identifier but no tag is listed by ID and left alone. VMs go first and the Physical Datacenter last. Afterwards it forgets the backfill progress, the feed's last push and the running scenarios, so a reseed starts clean.

Without `-Force` it only reports what it would delete. `-IncludeContent` also deletes the policies (the tier policies before `Synth-Base`), alerts, symptoms, recommendations, super metrics and custom groups whose names start with the content prefix, `Synth-Estate` included. Views, reports and dashboards cannot be deleted through the API. Add `-ApplianceSsh root@<ops appliance>` and reset deletes each of them with `ops-cli` on the appliance, in one SSH session that carries `bin/ops-content-delete.py` and the names. It signs in with an SSH key; if the appliance refuses the key, ssh itself asks for the password on the terminal, once, and the password never passes through the toolset. It deletes by the exact names `content` gives them: dashboards for the user `content` imported them as (`operations.username`), and never ops-cli's `-all`, which would delete the built-in ones too. Without `-ApplianceSsh`, reset lists them to delete in the UI and writes their names to `<paths.data>/content-delete.json`. Where the toolset cannot reach the appliance over SSH, copy that file and `bin/ops-content-delete.py` to the appliance and run the script there as root: it makes the same ops-cli calls with the same guards, reports only until given `--apply`, and exits 1 if an item failed. An item already gone shows as `not there`. On VCF Operations 9.1.1 ops-cli itself fails with `NoClassDefFoundError: org/slf4j/LoggerFactory`, because `opscli.jar` asks for `lib/slf4j-api-2.0.17.jar` while the appliance ships 2.0.18; the script then puts the shipped version on the classpath for its own ops-cli calls (`JDK_JAVA_OPTIONS`), and changes nothing on the appliance.

```bash
scp data/content-delete.json bin/ops-content-delete.py root@<ops appliance>:/tmp/
ssh root@<ops appliance>
$VMWARE_PYTHON_BIN /tmp/ops-content-delete.py /tmp/content-delete.json           # report only
$VMWARE_PYTHON_BIN /tmp/ops-content-delete.py /tmp/content-delete.json --apply   # delete
```

```bash
pwsh ./bin/vcfops-synth.ps1 reset -ConfigPath ./config/lab.json                    # report only
pwsh ./bin/vcfops-synth.ps1 reset -Force -IncludeContent -ApplianceSsh root@ops-a.site-a.example -ConfigPath ./config/lab.json
```

## Development

PowerShell 7.4 or later, Pester 5 and PSScriptAnalyzer. Tests need no lab.

```powershell
Invoke-Pester -Path ./tests
'./src', './bin', './tests' | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 }
pwsh ./bin/vcfops-synth.ps1 plan -ConfigPath ./config/lab.example.json
```

CI lints, tests and builds the image on every pull request. Pushes to `main` publish `latest` and a short-SHA tag to GHCR; a `vX.Y.Z` tag publishes `X.Y.Z` and `X.Y` (no `v`, so tag `v0.1.0` is the image `ghcr.io/msherian/vcfops-synth:0.1.0`). Set `ModuleVersion` in `src/VcfOpsSynth/VcfOpsSynth.psd1` to the release number before tagging; `vcfops-synth version` prints it with the image version and revision. Docker Hub publishing is wired but off until the repository variable `PUBLISH_DOCKERHUB` is set to `true` with `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets.

## Handling customer data

RVTools exports carry real VM names, hosts, IP addresses and annotations. Keep them in `data/`, which git ignores.

The importer never reads IP addresses, DNS names or MAC addresses. Anonymisation is on by default: every name becomes a stable pseudonym such as `vm-3f9a2c1d0b`, and folders, resource pools, annotations, snapshot names, partition paths and the source file name are dropped. Tiering rules still see the real values, because they run first. Pseudonyms are a keyed hash, so they stay the same on every re-import with the same key and cannot be confirmed by hashing a guessed name. The key is created in `data/anonymise.key` on first import, or comes from `VCFOPS_SYNTH_ANON_KEY`; keep it to keep the same pseudonyms, since objects seeded into VCF Operations are matched by them.
