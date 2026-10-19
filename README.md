# vcfops-synth

Builds a convincing VCF 9.1 Operations Day-2 demo from a customer's RVTools export. It recreates that estate as objects in VCF Operations, pushes believable history and live metrics for them through the Suite API, and publishes custom groups, tiered policies, symptoms, alerts and dashboards as code. Where data cannot be injected through the API, an optional live-load mode drives UPSA and small load VMs in the lab instead.

Everything ships as one Docker image, published to `ghcr.io/msherian/vcfops-synth`. The design plan, scenario catalogue and build order are in [docs/design.md](docs/design.md).

## Status

Phase 4 of 9: seeding the estate into VCF Operations and backfilling its history, on top of the Phase 2 importer and the Phase 1 image, CLI, Suite API sign-in and CI. The commands below marked "to come" stop with exit code 3 and name the phase that builds them.

| Command | What it does | Phase |
|---|---|---|
| `help`, `version` | Usage and versions | 1 |
| `config` | Validates `lab.json` and prints the merged settings | 1 |
| `connect-test` | Signs in to VCF Operations and prints its version | 1 |
| `plan` | Dry run: what each stage would do | 1 |
| `import` | RVTools export to inventory model | 2 |
| `seed` | Create the estate in VCF Operations under a vCenter adapter instance | 3 |
| `reset` | Remove the objects seed created | to come (3) |
| `backfill` | Push generated history for every numeric metric | 4 |
| `content` | Groups, policies, alerts, dashboards | to come (5 to 7) |
| `feed`, `scenario` | Live metrics and scenario overlays | to come (6) |
| `live-load` | Optional UPSA and load VMs | to come (9) |

## Quick start

```bash
mkdir -p config data
cp config/lab.example.json config/lab.json      # then set operations.fqdn for your lab
export VCFOPS_PASSWORD='...'                     # never stored in lab.json

docker run --rm -v "$PWD/config:/config" -v "$PWD/data:/data" -e VCFOPS_PASSWORD \
  ghcr.io/msherian/vcfops-synth config
docker run --rm -v "$PWD/config:/config" -v "$PWD/data:/data" -e VCFOPS_PASSWORD \
  ghcr.io/msherian/vcfops-synth connect-test
```

Then import an RVTools export (xlsx, or a folder of its CSV files) into the inventory model:

```bash
cp config/tiering.example.json config/tiering.json   # then edit the rules for this estate
cp ~/Downloads/RVTools_export_all.xlsx data/rvtools.xlsx

docker run --rm -v "$PWD/config:/config" -v "$PWD/data:/data" ghcr.io/msherian/vcfops-synth import
docker run --rm -v "$PWD/config:/config" -v "$PWD/data:/data" ghcr.io/msherian/vcfops-synth plan
```

The FQDN in `lab.example.json` is a placeholder in Holodeck's `site-a.vcf.lab` domain; use the name of your VCF Operations instance.

## Configuration

`lab.json` holds everything except the password. Values it leaves out take the defaults in `src/VcfOpsSynth/Private/ConfigDefaults.ps1`.

| Setting | Default | Meaning |
|---|---|---|
| `operations.fqdn` | (required) | VCF Operations host name, no scheme |
| `operations.username` / `authSource` | `admin` / `LOCAL` | Account used for the Suite API |
| `operations.skipCertificateCheck` | `false` | Set `true` for Holodeck's self-signed certificates |
| `adapterKind.key` | `VcfOpsSynth` | Push adapter kind the synthetic objects live under |
| `prefix` | `Synth-` | Prefix on everything created, so reset can find it |
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
| `-Adapter` | `VCFOPS_SYNTH_ADAPTER` | seed, backfill | vCenter adapter instance; default `seed.adapterInstance` |
| `-Refresh` | `VCFOPS_SYNTH_REFRESH` | seed | Push properties and stats to objects already there |
| `-DryRun` | `VCFOPS_SYNTH_DRY_RUN` | seed, backfill | Report only; change nothing |
| `-Days` | `VCFOPS_SYNTH_DAYS` | backfill | Days of history; default `backfillDays` |
| `-Kinds` | `VCFOPS_SYNTH_KINDS` | backfill | Comma-separated resource kinds |
| `-MaxVms` | `VCFOPS_SYNTH_MAX_VMS` | backfill | First n VMs only, for a pilot |
| `-Concurrency` | `VCFOPS_SYNTH_CONCURRENCY` | backfill | Objects posted at once; default 4 |
| `-MaxSamples` | `VCFOPS_SYNTH_MAX_SAMPLES` | backfill | Samples per post, halved when refused; default 100000 |
| `-Restart` | `VCFOPS_SYNTH_RESTART` | backfill | Forget saved progress |
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
docker run --rm -v "$PWD/config:/config" -v "$PWD/data:/data" -e VCFOPS_PASSWORD \
  -e VCFOPS_SYNTH_COMMAND=seed -e VCFOPS_SYNTH_DRY_RUN=true ghcr.io/msherian/vcfops-synth
```
## Seeding

`seed -Adapter <vCenter adapter instance>` builds the inventory as VMWARE objects under that instance, foundations first: an optional Physical Data Center (`seed.physicalDatacenter`), datacenters (linked under the vCenter), clusters, datastores, hosts, distributed switches and port groups, VM folders and VMs. Standard switches and port groups, which VMWARE does not model, go under the `adapterKind.key` push kind. Every relationship is worked out before anything is created.

Rubrics captured from real lab objects (`seed.rubrics`, default `<paths.data>/rubrics`) only say which metrics and properties each kind has. Every value comes from the inventory (RVTools, LiveOptics), is derived from it (for example host use over capacity, cluster roll-ups), or is a neutral placeholder (`-`, `0`, `false`). Keys Operations computes itself (capacity analytics such as time and capacity remaining, badges, alert counts, workload scores, reclamation, rightsizing, sustainability and capacity profiles) are never pushed, so its own results are not masked. Capacity inputs (usable memory, memory demand, total and HA CPU and memory capacity, disk space over the datastores a host or cluster sees) come from the inventory and stay flat through the backfill. Objects keep their inventory names (`seed.prefix` is optional) and carry two vSphere tags in `summary|tag`: `seed.tag` (default `vcfops-synth-synthetic`) and `Project-<project>`, where the project is `seed.project` or the `YYYY.#### ... OPP-n` folder the export was imported from.

Objects that already exist are found by their identifiers, not their names, and skipped; `-Refresh` pushes the planned properties and current stats to them again. `-DryRun` prints the plan.

## Backfill

`backfill` pushes `backfillDays` of history at `intervalMinutes` for every numeric metric of the seeded objects, with analytics processing off. Metrics LiveOptics measured (VM and host CPU, memory, IOPS, throughput, latency) match its average and peak exactly. The rest follow the object's workload curve around their current value, grow to it (space in use), stay flat (capacity, counts) or stay at zero (no source). Each VM's curve comes from its workload profile in `timeZone`, with seeded noise and incident windows; hosts, clusters, datastores, port groups and folders follow the sum of their VMs' curves, so peaks line up.

Progress is saved to `paths.state` after each batch, so a stopped run resumes over the same range; `-Restart` starts afresh. `-DryRun` counts objects, series and samples; `-Kinds` and `-MaxVms` limit a pilot run; `-Concurrency` sets how many objects post at once. Operations 9.1.1 in the lab refused posts of about 250,000 samples or more with HTTP 500, so posts hold at most `-MaxSamples` samples and a refused one is halved, for the rest of the batch too. For a busy Operations, each post is retried up to 10 times with waits growing from 2 seconds to 60, and objects still refused get two more passes at the end of the run, one at a time; any left after that are reported and picked up by the next run. In the lab, 30 days for 1,709 objects is 2.4 billion samples, about 620,000 a second at concurrency 4, and about 6 bytes a sample in the Operations database.

## Development

PowerShell 7.4 or later, Pester 5 and PSScriptAnalyzer. Tests need no lab.

```powershell
Invoke-Pester -Path ./tests
'./src', './bin', './tests' | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 }
pwsh ./bin/vcfops-synth.ps1 plan -ConfigPath ./config/lab.example.json
```

CI lints, tests and builds the image on every pull request. Pushes to `main` publish `latest` and a short-SHA tag to GHCR; `v*` tags publish versioned images. Docker Hub publishing is wired but off until the repository variable `PUBLISH_DOCKERHUB` is set to `true` with `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets.

## Handling customer data

RVTools exports carry real VM names, hosts, IP addresses and annotations. Keep them in `data/`, which git ignores.

The importer never reads IP addresses, DNS names or MAC addresses. Anonymisation is on by default: every name becomes a stable pseudonym such as `vm-3f9a2c1d0b`, and folders, resource pools, annotations, snapshot names, partition paths and the source file name are dropped. Tiering rules still see the real values, because they run first. Pseudonyms are a keyed hash, so they stay the same on every re-import with the same key and cannot be confirmed by hashing a guessed name. The key is created in `data/anonymise.key` on first import, or comes from `VCFOPS_SYNTH_ANON_KEY`; keep it to keep the same pseudonyms, since objects seeded into VCF Operations are matched by them.
