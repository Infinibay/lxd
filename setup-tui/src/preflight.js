// Host preflight checks used by the wizard (all best-effort, Linux-focused).

import { accessSync, constants, existsSync, readFileSync, statSync, writeFileSync, unlinkSync } from 'node:fs'
// statfsSync exists only on Node ≥ 18.15/19.6. Import via namespace + runtime guard
// so older-but-supported Node doesn't crash the whole TUI at module link time.
import * as nodeFs from 'node:fs'
import { join } from 'node:path'

/** KVM/virtualization: is /dev/kvm present + do CPU virt flags exist? */
export function kvmPreflight () {
  const hasDevKvm = existsSync('/dev/kvm')
  let hasVirtFlags = false
  try {
    const cpuinfo = readFileSync('/proc/cpuinfo', 'utf8')
    hasVirtFlags = /\b(vmx|svm)\b/.test(cpuinfo)
  } catch { /* non-Linux */ }
  const ok = hasDevKvm && hasVirtFlags
  return {
    ok,
    hasDevKvm,
    hasVirtFlags,
    detail: ok
      ? 'KVM available (/dev/kvm present, CPU virtualization enabled).'
      : !hasVirtFlags
        ? 'CPU virtualization (VT-x/AMD-V) not detected — VMs cannot be created/started (control-plane-only).'
        : '/dev/kvm not present — the host may need KVM modules loaded, or this is a nested/limited environment (control-plane-only).'
  }
}

/** Free space (bytes) on the filesystem backing `p` (walks up to an existing ancestor). */
export function diskFree (p) {
  let dir = p
  while (dir && !existsSync(dir)) {
    const parent = dir.replace(/\/[^/]+\/?$/, '') || '/'
    if (parent === dir) break
    dir = parent
  }
  try {
    if (typeof nodeFs.statfsSync !== 'function') return { bytes: undefined, checkedPath: dir }
    const st = nodeFs.statfsSync(dir)
    return { bytes: st.bavail * st.bsize, checkedPath: dir }
  } catch {
    return { bytes: undefined, checkedPath: dir }
  }
}

export function humanBytes (n) {
  if (n === undefined) return 'unknown'
  const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  let i = 0
  let v = n
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++ }
  return `${v.toFixed(1)} ${u[i]}`
}

const NETWORK_FS = new Set(['nfs', 'nfs4', 'ceph', 'cephfs', 'cifs', 'smb', 'smb3', 'smbfs', 'glusterfs', 'fuse.glusterfs', 'lustre', 'ocfs2', 'gfs2'])

function isMountpoint (dir) {
  try {
    const a = statSync(dir)
    const parent = dir.replace(/\/[^/]+\/?$/, '') || '/'
    if (parent === dir) return true
    const b = statSync(parent)
    return a.dev !== b.dev
  } catch { return false }
}

function fsTypeOf (dir) {
  try {
    const raw = readFileSync('/proc/mounts', 'utf8')
    let bestLen = -1
    let bestType
    for (const line of raw.split('\n')) {
      const parts = line.split(/\s+/)
      if (parts.length < 3) continue
      const mp = parts[1].replace(/\\040/g, ' ')
      const isPrefix = dir === mp || dir.startsWith(mp.endsWith('/') ? mp : mp + '/')
      if (isPrefix && mp.length > bestLen) { bestLen = mp.length; bestType = parts[2].toLowerCase() }
    }
    return bestType
  } catch { return undefined }
}

function writable (dir) {
  try {
    accessSync(dir, constants.W_OK)
    const probe = join(dir, `.ib-probe-${process.pid}`)
    writeFileSync(probe, 'ok'); unlinkSync(probe)
    return true
  } catch { return false }
}

/**
 * Verify a shared-storage mount at `diskDir`: exists → mountpoint → network fs →
 * writable. Mirrors the backend verifySharedStorage so the TUI's pre-write check
 * matches what preflight will assert at boot.
 */
export function verifySharedMount (diskDir) {
  if (!existsSync(diskDir)) {
    return { ok: false, detail: `${diskDir} does not exist — create and mount the shared volume there first.` }
  }
  const mount = isMountpoint(diskDir)
  const fsType = fsTypeOf(diskDir)
  const isNet = fsType ? NETWORK_FS.has(fsType) : undefined
  const canWrite = writable(diskDir)

  if (!mount) return { ok: false, detail: `${diskDir} is not a mountpoint (looks like a plain local directory, not a shared mount).` }
  if (isNet === false) return { ok: false, detail: `${diskDir} is mounted as "${fsType}", not a recognized network filesystem (nfs/ceph/cifs/...).` }
  if (!canWrite) return { ok: false, detail: `${diskDir} is not writable by this user.` }
  const note = isNet === undefined ? ' (fs type unconfirmed)' : ` (${fsType})`
  return { ok: true, detail: `Shared mount verified at ${diskDir}${note}.` }
}
