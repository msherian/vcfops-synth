# Design summary

The full design plan is a shared document: [VCF 9.1 Operations Synthetic Data Toolset: Design Plan](https://claude.ai/code/artifact/682a1a70-58a6-4ea7-bbff-2e2e4c93d12f). This page keeps the decisions the code depends on next to it.

## Decisions

- **Inventory comes from RVTools.** vInfo, vCPU, vMemory, vHost, vCluster, vDatastore, vPartition, vSnapshot and vTools give placement, sizing, configuration and one usage sample per object. Those samples become baselines for generated history.
- **Metrics go straight into the Suite API.** Objects are created under a push adapter kind (`adapterKind.key`), mirroring the vSphere resource kinds and using the same metric keys. History is pushed with `disableAnalyticsProcessing=true`, then a live feed runs with analytics on so symptoms and alerts fire.
- **Optional live load.** Where the API cannot supply something (stock vSphere content on real objects, 20-second Workbench data, NSX traffic, in-guest metrics), UPSA pairs and small Photon OS load VMs generate real data in the Holodeck workload domain, within the caps in `liveLoad`.
- **One image.** PowerShell 7 on Linux, ImportExcel for xlsx, published to GHCR; Docker Hub later.
- **Everything created carries the prefix** so `reset` can remove it.
- **Inventory IDs are keyed hashes** (`vm-3f9a2c1d0b`) of each object's identity in the export: the vCenter plus the managed object ID, falling back to the VM UUID, then the name. They are stable across re-imports with the same key, which is what lets `seed` (Phase 3) match objects it created before. Anonymised objects use the ID as their name.
- **Baselines come from one sample.** RVTools records usage once, so each baseline is that sample; the generator (Phase 4) draws history around it by profile. Powered-off VMs get zero usage and the `off` profile.

## Build order

| Phase | Deliverable |
|---|---|
| 0 | Spikes: native vs custom adapter kind, backdated stats limits, content import API, sample RVTools parse |
| 1 | Repository, image, CLI skeleton, Suite API sign-in, CI |
| 2 | RVTools importer, anonymiser, tiering, baselines (this phase) |
| 3 | Seed objects, properties and relationships; reset |
| 4 | Generator and history backfill |
| 5 | Custom groups and tiered policies |
| 6 | Live feed, scenarios, symptoms, alerts, super metrics |
| 7 | Dashboards, views, reports |
| 8 | Runbook and first tagged release |
| 9 | Optional live-load mode |
