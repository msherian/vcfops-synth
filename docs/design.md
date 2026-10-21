# Design summary

The full design plan is a shared document: [VCF 9.1 Operations Synthetic Data Toolset: Design Plan](https://claude.ai/code/artifact/682a1a70-58a6-4ea7-bbff-2e2e4c93d12f). This page keeps the decisions the code depends on next to it.

## Decisions

- **Inventory comes from RVTools, and the lab is reference only.** The VM, host, cluster, datastore, network and resource pool tabs describe a whole estate, which the toolset recreates as synthetic objects: every datacenter, cluster, host, datastore, switch, network, resource pool and folder in the export gets a synthetic counterpart, and each synthetic VM lives under its own imported parents, never under real lab objects. RVTools also gives one usage sample per object. Those samples become baselines for generated history.
- **Native VMWARE objects under the vCenter adapter instance.** Seeded datacenters, clusters, hosts, datastores, distributed switches, port groups, folders and VMs are VMWARE objects under the lab's vCenter adapter instance, with the same identifiers and metric keys as real ones, so stock content (capacity, dashboards, alerts) works on them. Only kinds VMWARE does not model (standard switches and port groups) and the Physical Data Center use the push adapter kind (`adapterKind.key`). History is pushed with `disableAnalyticsProcessing=true`; points with analytics on (`seed -Refresh` now, the live feed in Phase 6) make Operations calculate capacity, symptoms and alerts.
- **Values come from the export; Operations keeps its own analytics.** Rubrics captured from lab objects only list the keys each kind has. Every value is from RVTools or LiveOptics, derived from them, or a neutral placeholder. Keys Operations computes (capacity analytics, badges, alert counts, workload, reclamation, rightsizing, sustainability, profiles) are never pushed.
- **History matches LiveOptics.** Calibrated series hit the LiveOptics average and peak. A peak no higher than the average gives a flat line; an average of 0 with a peak gives one spike at the busiest point. A VM's disk throughput goes on its first disk, because Operations calculates the VM total from its disks.
- **Optional live load.** Where the API cannot supply something (stock vSphere content on real objects, 20-second Workbench data, NSX traffic, in-guest metrics), UPSA pairs and small Photon OS load VMs generate real data in the Holodeck workload domain, within the caps in `liveLoad`.
- **One image.** PowerShell 7 on Linux, ImportExcel for xlsx, published to GHCR; Docker Hub later.
- **Seeded objects keep their names; reset finds them by tag and identifier.** Objects carry the `vcfops-synth` and project vSphere tags, and their managed object IDs contain `-synth-`. Content the toolset publishes (groups, policies, dashboards) keeps the `prefix`, so `reset` can find that too.
- **Inventory IDs are keyed hashes** (`vm-3f9a2c1d0b`) of each object's identity in the export: the vCenter plus the managed object ID, falling back to the VM UUID, then the name. They are stable across re-imports with the same key, which is what lets `seed` (Phase 3) match objects it created before. Anonymised objects use the ID as their name.
- **Baselines come from one sample.** RVTools records usage once, so each baseline is that sample; the generator (Phase 4) draws history around it by profile. Powered-off VMs get zero usage and the `off` profile.

## Build order

| Phase | Deliverable |
|---|---|
| 0 | Spikes: native vs custom adapter kind, backdated stats limits, content import API, sample RVTools parse |
| 1 | Repository, image, CLI skeleton, Suite API sign-in, CI |
| 2 | RVTools importer, anonymiser, tiering, baselines (done) |
| 3 | Seed objects, properties and relationships (done; reset moved to 8) |
| 4 | Generator and history backfill (done) |
| 5 | Custom groups and tiered policies |
| 6 | Live feed, scenarios, symptoms, alerts, super metrics |
| 7 | Dashboards, views, reports |
| 8 | Reset, container lab test, runbook and first tagged release |
| 9 | Optional live-load mode |
