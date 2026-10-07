# vcfops-synth

Builds a convincing VCF 9.1 Operations Day-2 demo from a customer's RVTools export. It recreates that estate as objects in VCF Operations, pushes believable history and live metrics for them through the Suite API, and publishes custom groups, tiered policies, symptoms, alerts and dashboards as code. Where data cannot be injected through the API, an optional live-load mode drives UPSA and small load VMs in the lab instead.

Everything ships as one Docker image, published to `ghcr.io/msherian/vcfops-synth`. The design plan, scenario catalogue and build order are in [docs/design.md](docs/design.md).

## Status

Phase 1 of 9: repository, image, command-line skeleton, Suite API sign-in and CI. The commands below marked "to come" stop with exit code 3 and name the phase that builds them.

| Command | What it does | Phase |
|---|---|---|
| `help`, `version` | Usage and versions | 1 |
| `config` | Validates `lab.json` and prints the merged settings | 1 |
| `connect-test` | Signs in to VCF Operations and prints its version | 1 |
| `plan` | Dry run: what each stage would do | 1 |
| `import` | RVTools export to inventory model | to come (2) |
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
| `liveLoad.*` | off, 6 VMs, 2 UPSA pairs | Optional live-load mode and its caps |

Environment overrides: `VCFOPS_FQDN`, `VCFOPS_USERNAME`, `VCFOPS_AUTHSOURCE`, `VCFOPS_SYNTH_CONFIG` (path to `lab.json`). The password comes from `VCFOPS_PASSWORD`, or from `VCFOPS_PASSWORD_FILE` for a Docker secret such as `/run/secrets/vcfops_password`.

## Development

PowerShell 7.4 or later, Pester 5 and PSScriptAnalyzer. Tests need no lab.

```powershell
Invoke-Pester -Path ./tests
'./src', './bin', './tests' | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 }
pwsh ./bin/vcfops-synth.ps1 plan -ConfigPath ./config/lab.example.json
```

CI lints, tests and builds the image on every pull request. Pushes to `main` publish `latest` and a short-SHA tag to GHCR; `v*` tags publish versioned images. Docker Hub publishing is wired but off until the repository variable `PUBLISH_DOCKERHUB` is set to `true` with `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets.

## Handling customer data

RVTools exports carry real VM names, hosts, IP addresses and annotations. Keep them in `data/`, which git ignores, and use the importer's anonymisation (Phase 2) before sharing any output.
