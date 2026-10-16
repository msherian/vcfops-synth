# Design summary

The full design plan is a shared document: [VCF 9.1 Operations Synthetic Data Toolset: Design Plan](https://claude.ai/code/artifact/682a1a70-58a6-4ea7-bbff-2e2e4c93d12f). This page keeps the decisions the code depends on next to it.

## Decisions

- **Inventory comes from RVTools, and the lab is reference only.** The VM, host, cluster, datastore, network and resource pool tabs describe a whole estate, which the toolset recreates as synthetic objects: every datacenter, cluster, host, datastore, switch, network, resource pool and folder in the export gets a synthetic counterpart, and each synthetic VM lives under its own imported parents, never under real lab objects. RVTools also gives one usage sample per object. Those samples become baselines for generated history.
- **Metrics go straight into the Suite API.** Objects are created as native `VMWARE` objects under the vCenter adapter instance named in `seed.adapterInstance`, so they match collected objects key for key and stock content applies to them. Only kinds Operations lacks (standard vSwitches and their port groups) use the push adapter kind (`adapterKind.key`). History is pushed with `disableAnalyticsProcessing=true`, then `seed -Refresh` and the live feed push with analytics on, so capacity is calculated and symptoms and alerts fire.
- **Parity with real objects.** A real object of each kind is the rubric for which metrics and properties a synthetic one carries; the inventory supplies only values. Keys Operations computes itself are never pushed.
- **Optional live load.** Where the API cannot supply something (stock vSphere content on real objects, 20-second Workbench data, NSX traffic, in-guest metrics), UPSA pairs and small Photon OS load VMs generate real data in the Holodeck workload domain, within the caps in `liveLoad`.
- **One image.** PowerShell 7 on Linux, ImportExcel for xlsx, published to GHCR; Docker Hub later.
- **Seeded objects keep their real names in the lab** and carry the `seed.tag` synthetic tag; `reset` finds them by tag and identifier, never by name. The toolset's own content (groups, policies, dashboards) carries `prefix`.
- **Inventory IDs are keyed hashes** (`vm-3f9a2c1d0b`) of each object's identity in the export: the vCenter plus the managed object ID, falling back to the VM UUID, then the name. They are stable across re-imports with the same key, which is what lets `seed` (Phase 3) match objects it created before. Anonymised objects use the ID as their name.
- **Baselines come from one sample, calibrated by LiveOptics.** RVTools records usage once, so each baseline is that sample; the generator draws history around it by profile. Where a LiveOptics workbook is imported (`-Performance`), measured VM and host series are generated to hit its average and peak exactly. Powered-off VMs get zero usage and the `off` profile.

## Build order

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Spikes: native vs custom adapter kind, backdated stats limits, content import API, sample RVTools parse | Done |
| 1 | Repository, image, CLI skeleton, Suite API sign-in, CI | Done |
| 2 | RVTools importer, anonymiser, tiering, baselines | Done |
| 3 | Seed objects, properties and relationships; reset | Seed done; reset moves to 8 |
| 4 | Generator and history backfill | Done (30 days, 95% of LiveOptics series match) |
| 5 | Custom groups and tiered policies | Under way |
| 6 | Live feed, scenarios, symptoms, alerts, super metrics | To do |
| 7 | Dashboards, views, reports | To do |
| 8 | Runbook, reset and first tagged release | Container runbook in review |
| 9 | Optional live-load mode | To do |
