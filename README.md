# vcfops-synth

Builds a convincing VCF 9.1 Operations Day-2 demo from a customer's RVTools export. It recreates that estate as objects in VCF Operations, pushes believable history and live metrics for them through the Suite API, and publishes custom groups, tiered policies, symptoms, alerts and dashboards as code. Where data cannot be injected through the API, an optional live-load mode drives UPSA and small load VMs in the lab instead.

Everything ships as one Docker image, published to `ghcr.io/msherian/vcfops-synth`. The design plan, scenario catalogue and build order are in [docs/design.md](docs/design.md).

## Status

Phase 2 of 9: the RVTools importer, anonymiser, tiering and baselines, on top of the Phase 1 image, CLI, Suite API sign-in and CI. The commands below marked "to come" stop with exit code 3 and name the phase that builds them.

| Command | What it does | Phase |
|---|---|---|
| `help`, `version` | Usage and versions | 1 |
| `config` | Validates `lab.json` and prints the merged settings | 1 |
| `connect-test` | Signs in to VCF Operations and prints its version | 1 |
| `plan` | Dry run: what each stage would do | 1 |
| `import` | RVTools export to inventory model | 2 |
| `seed`, `reset` | Create and remove objects in VCF Operations | to come (3) |
| `backfill` | Push generated history | to come (4) |
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
| `import.anonymise` | `true` | Replace names with pseudonyms; `--no-anonymise` overrides it for one run |
| `liveLoad.*` | off, 6 VMs, 2 UPSA pairs | Optional live-load mode and its caps |

Environment overrides: `VCFOPS_FQDN`, `VCFOPS_USERNAME`, `VCFOPS_AUTHSOURCE`, `VCFOPS_SYNTH_CONFIG` (path to `lab.json`). The password comes from `VCFOPS_PASSWORD`, or from `VCFOPS_PASSWORD_FILE` for a Docker secret such as `/run/secrets/vcfops_password`.

## Importing RVTools

`import` reads vInfo and vHost (required) and vCPU, vMemory, vCluster, vDatastore, vPartition, vSnapshot, vTools and vMetaData when present. It accepts the xlsx export or the CSV export (`RVTools -c ExportAll2csv`, files named `RVTools_tab<tab>.csv`, comma or semicolon separated), and both RVTools 3.x (`MB`) and 4.x (`MiB`) column names. The column map is `src/VcfOpsSynth/Private/RvtoolsColumns.ps1`.

The inventory model holds datacenters, clusters, hosts, datastores and VMs, with placement, sizing, configuration (guest OS, hardware version, Tools status, snapshots) and baselines from RVTools' single usage sample: VM CPU and active memory percent, guest disk use, host CPU and memory percent, and datastore use. Templates and SRM placeholders are skipped, and rows that cannot be used are listed by tab and row number in `report.skipped`, so one bad row never stops an import.

### Tiering rules

`tiering.json` gives each VM a tier (Gold, Silver or Bronze), an application and a workload profile (steady, business-hours, batch, bursty, idle or saturated). Rules run in order against the real values from the export; for each of tier, application and profile, the first matching rule that sets it wins. A rule matches when every regular expression in its `match` block matches, ignoring case. Match fields are `name`, `cluster`, `host`, `datacenter`, `folder`, `resourcePool`, `annotation`, `guestOs`, `powerState`, and `attribute:<column>` for any other vInfo column, such as a vCenter custom attribute.

```json
{ "match": { "cluster": "^PROD", "annotation": "tier ?1|critical" }, "tier": "Gold" }
```

VMs no rule profiles are profiled from their usage: idle under 5% CPU and 10% active memory, saturated from 80% CPU or 85% active memory, business-hours otherwise, and off when powered off. The thresholds are under `profiles` in the same file. See `config/tiering.example.json`.

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
