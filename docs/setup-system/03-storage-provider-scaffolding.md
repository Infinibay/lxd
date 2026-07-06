# 03 — Storage Provider Scaffolding

Today shared storage is a single honor-system boolean (`INFINIBAY_SHARED_STORAGE`). The user
accepts that for v1 but wants a **base to grow into real NFS/Ceph** without a rewrite. This doc
specifies a thin `StorageProvider` abstraction to introduce **now** (mostly interface + two impls +
a verify check), leaving richer backends as documented stubs.

Grounding: `INFINIZATION_DISK_DIR` is read across ~7 backend spots (e.g.
`backend/app/services/InfinizationService.ts`); `INFINIBAY_SHARED_STORAGE` is read **only** at
migration time (`backend/app/graphql/resolvers/machine/resolver.ts` →
`backend/app/services/node/VMMigrationService.ts`, which also accepts an explicit
`storageMode: 'shared' | 'external'`). `infinization` never reads the shared-storage flag; it is
path-based. See [`05-grounding-reference.md`](./05-grounding-reference.md#storage--migration).

---

## 1. Current state (what we're abstracting over)

- **Disks:** local qcow2 under `INFINIZATION_DISK_DIR` (default `/var/lib/infinization/disks`),
  assumed **byte-identical path on every node** (so a migrated disk keeps its path).
- **Migration:** `INFINIBAY_SHARED_STORAGE=true` → migration skips the disk copy (assumes the disk
  is already reachable on the target); false/unset → `AgentStorageMigrationAdapter` copies + sha256-
  verifies the qcow2 over the mTLS agent channel. Nothing verifies a real shared mount exists.
- **Preflight:** `backend/scripts/production-preflight.ts` already asserts
  `INFINIBAY_SHARED_STORAGE=true` for built-in cross-node cold migration.

---

## 2. The abstraction to introduce now

Place it in **backend** (that's where the shared-storage decision and migration live; infinization
stays path-based). Suggested: `backend/app/services/storage/`.

```ts
// backend/app/services/storage/StorageProvider.ts
export type StorageBackendKind = 'local' | 'shared-mount' | 'ceph';   // 'ceph' = future stub

export interface StorageVerifyResult {
  ok: boolean;
  backend: StorageBackendKind;
  diskDir: string;
  isMountpoint?: boolean;
  isNetworkFs?: boolean;      // nfs/ceph/cifs detected via statfs / /proc/mounts
  writable?: boolean;
  detail: string;             // human-readable pass/fail reason
}

export interface StorageProvider {
  readonly kind: StorageBackendKind;
  /** Is the same disk reachable from every node without an explicit copy? */
  isShared(): boolean;
  /** Verify the backend is actually usable on this host (mount present, writable, ...). */
  verify(diskDir: string): Promise<StorageVerifyResult>;
  /** Absolute path/URI the hypervisor should use for a VM's disk.
   *  For local/shared-mount this is just a filesystem path; future block backends (ceph) override. */
  resolveDiskLocation(vmId: string, fileName: string): string;
  /** Human summary for the setup UI / preflight. */
  describe(): string;
}
```

Implementations to ship **now**:
- **`LocalStorageProvider`** — `isShared()=false`; `verify()` checks the disk dir exists + writable +
  free space; `resolveDiskLocation` = `path.join(diskDir, fileName)`.
- **`SharedMountStorageProvider`** — `isShared()=true`; `verify()` additionally checks the disk dir
  is a **mountpoint** and (best-effort) a **network fs** (parse `/proc/mounts` / `statfs` magic for
  nfs/ceph/cifs), and is writable on this node. Same `resolveDiskLocation` (it's still a filesystem
  path — that's the whole point of a shared mount).

Stub only (interface + `NotImplemented`), documented for later:
- **`CephRbdStorageProvider`** — native RBD (no filesystem mount). `resolveDiskLocation` would return
  an `rbd:pool/${vmId}` style URI, which would require **infinization** `QemuCommandBuilder` to emit
  `-drive file=rbd:...` (or `-blockdev` with the rbd driver). This is the real future work; leave a
  clear `// TODO(ceph): see 03-storage-provider-scaffolding.md` marker.

A factory: `getStorageProvider(kind)` selected from config (see [§4](#4-config--persistence)).

---

## 3. Wire the abstraction into the two existing consumers (thin)

- **Migration** (`VMMigrationService`): instead of reading `INFINIBAY_SHARED_STORAGE` directly,
  ask `getStorageProvider(cfg.kind).isShared()`. Keep the existing `storageMode` override path;
  `shared` maps to a shared provider, `external` to local+copy. This is a small refactor that
  changes *how the boolean is sourced*, not the copy/skip behavior.
- **Preflight** (`production-preflight.ts`): call `provider.verify(diskDir)` and surface its
  `detail` instead of just checking the env boolean. This closes the "honor-system" gap for the
  shared-mount case (it can now *detect* a missing mount).

`infinization` is **unchanged** for v1 (paths only). Ceph is the point where infinization would need
changes; explicitly out of scope now.

---

## 4. Config & persistence

- **v1 source of truth:** env, written by the TUI —
  `INFINIBAY_STORAGE_BACKEND=local|shared-mount` (+ legacy `INFINIBAY_SHARED_STORAGE=true` kept in
  sync for backward compat with the existing migration read until fully refactored).
- **Forward-looking (the "we'll configure something later" the user mentioned):** add an
  `AppSettings.storageConfig Json?` column so the backend can be **reconfigured post-deploy** (e.g.
  a future `/settings/storage` page picking NFS/Ceph, entering an export path or RBD pool/keyring).
  The provider factory should prefer `AppSettings.storageConfig` when present, else fall back to env.
  Scaffold the column + factory-read now; the reconfigure UI is future work.

---

## 5. Verification checks (used by TUI Phase A and preflight)

Expose a small reusable `verifySharedStorage(diskDir): Promise<StorageVerifyResult>` (the
`SharedMountStorageProvider.verify` body) so:
- **Phase A TUI** calls it before writing `INFINIBAY_SHARED_STORAGE=true` (offer override on fail).
- **Preflight** calls it at boot.
- A future **reconfigure UI** calls it before saving.

Checks: path exists → is a mountpoint → fs type is network (nfs/ceph/cifs) → writable (touch+unlink a
temp file). Report which check failed. Single-node/dev: skip (irrelevant) unless multi-node.

---

## 6. Future backends — notes for whoever adds NFS/Ceph

- **NFS/iSCSI/SAN** → fits `shared-mount` **as-is** (it's a filesystem mount at the disk dir). The
  only "support" needed is (a) docs/UX to help the operator mount it and (b) the `verify()` above.
  No new provider required — this is the recommended near-term path.
- **CephFS** (POSIX mount) → also `shared-mount`.
- **Ceph RBD** (native block, no mount) → needs `CephRbdStorageProvider` **and** infinization
  changes to attach RBD volumes to QEMU. This is the only backend that breaks the "it's just a
  path" assumption; treat it as a separate project.
- Whatever is added, keep migration's copy-vs-skip decision behind `provider.isShared()` and the
  target-side path deterministic (uniform `INFINIZATION_DISK_DIR` across nodes) so no DB `diskPaths`
  rewrite is needed.

---

## 7. Scaffolding deliverables checklist

- [ ] `StorageProvider` interface + `LocalStorageProvider` + `SharedMountStorageProvider` + `verifySharedStorage()`.
- [ ] `CephRbdStorageProvider` stub with `NotImplemented` + TODO marker.
- [ ] `getStorageProvider()` factory reading `AppSettings.storageConfig` ?? `INFINIBAY_STORAGE_BACKEND` env.
- [ ] `AppSettings.storageConfig Json?` migration.
- [ ] Refactor `VMMigrationService` + `production-preflight.ts` to source shared-ness via the provider.
- [ ] Keep `INFINIBAY_SHARED_STORAGE` in sync for backward compat until the read is fully migrated.
