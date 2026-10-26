#!/bin/bash
########################################################################################################
#
# .SYNOPSIS
#   Enable the Linux inbox NVMe kernel drivers (nvme, nvme_core) in the initramfs of an offline OS
#   disk so the guest can boot after a SCSI-to-NVMe controller migration. v2.1.4
#
#   v2.1.4 changes vs v2.1.3 (chroot dracut aux-mount handling + subshell scope defect for LVM
#                              tracking arrays):
#     • **Fix D (chroot dracut needs /var and /tmp mounted)** — v2.1.3 mounts a separate `/usr`
#       under the classification root when fstab declares one (RHEL 9 UsrMove), but not `/var`
#       or `/tmp`. On RHEL 9's default LVM layout `/var` and `/tmp` also live on separate LVs
#       and are empty directories inside the chroot when unmounted. `dracut` calls
#       `realpath /var/tmp` to resolve its default tmpdir; that returns
#       `Invalid tmpdir '/var/tmp'` when `/var` is empty in the chroot, and dracut aborts
#       before writing any output. Live probe on `rhel-diag-145945/rescue` (2026-09-25 Test B)
#       reproduced the failure directly; Test A with `/var` and `/tmp` mounted let dracut run
#       for its full 60-second probe budget without erroring. Fix: extend the classifier's
#       aux-mount pass (currently mounts only `/usr`) to a unified loop over
#       `[usr, var, tmp]` driven by fstab-present-and-declared logic — `resolve_and_mount_aux`
#       already handles the "no fstab entry" case as not-an-error, so distros without separate
#       `/var` / `/tmp` (Ubuntu, Debian, AlmaLinux) get no-op behavior. Symmetric extensions to
#       the RW-remount block (Repair + Rollback mutation paths), the classification-failure
#       unmount branch, and `cleanup()`. Evidence JSON gains a `separateAuxMounts` object with
#       per-mount `{mounted,device}` under `guest.lvm`; existing `separateUsrMounted` and
#       `separateUsrDevice` scalars retained as backward-compat aliases (mirror the "usr" entry
#       byte-for-byte). schemaVersion bumps 1.5 → 1.6. Byte-for-byte parity with breaker per
#       Gates.md design invariant 15. This closes G-D2 RHEL 9 (blocked on Fix D since v2.1.3),
#       G-D6 (separate `/boot` was ready; only Row 2 completion was gating), and enables the
#       XFS `nouuid` retry marker for G-D7 to surface in mount-log grep.
#     • **Fix E (subshell scope defect in `activate_lvm_pvs_and_enumerate_lvs` invocation)** —
#       v2.0.1+ helper does two things concurrently: emits LV paths on stdout AND appends to
#       three global tracking arrays (`ACTIVATED_SOURCE_VGS`, `LVM_ENUMERATED_LVS`,
#       `LV_TO_DISK_MAP`). The caller invokes it via `lvm_lvs=$(activate_lvm_...)` command
#       substitution — but `$(...)` creates a subshell, and array appends inside the subshell
#       are LOST when the subshell exits. Fix B's whole point (autoactivation-aware VG
#       tracking) was defeated by this: every evidence JSON since v2.1.0 reported
#       `activatedVgs=[]` and `enumeratedLvs=[]` even when the runtime log confirmed VGs
#       activated cleanly. Local reproducer at
#       `Output/TestReports/Local-linux-fix-nvme-boot-v2.1.3/2026-09-25/fix-E-subshell-repro-v2.sh`
#       demonstrates the mechanism across 5 consumer patterns; only "temp file rehydration" or
#       "direct call, no capture" work. Fix: change the helper's contract — no more stdout
#       emission of LV paths; callers iterate the global `LVM_ENUMERATED_LVS` array populated
#       in-place. Caller becomes a direct call (no `$(...)`); the array append runs in the
#       parent shell and persists. `[Warning] udevadm settle` line no longer needs its
#       `>&2` stderr redirect (helper is no longer captured), but retained for consistency
#       with the DESIGN NOTES about Log-* invariants. Fix B's effect (VG-UUID + `lv_active=`
#       tracking) is now observable in evidence JSON on the first Row 2 rerun.
#     • Combined scope: Fix D ~48 LOC + Fix E ~20 LOC per script = ~68 LOC per script; ~136
#       LOC across the pair. New pytest cases: 5 Fix D + 4 Fix E + 1 Ubuntu regression = 10.
#       Schema bumps: fix 1.5 → 1.6; breaker 1.2 → 1.3.
#     • Byte-for-byte parity with linux-break-nvme-boot v2.1.4 per Gates.md design invariant 15.
#
#   v2.1.3 changes vs v2.1.2 (LV-safe devDisk derivation + autoactivation-aware VG tracking
#                              + bash forward-reference fix):
#     • **Fix C (bash forward reference)** — v2.1.2 added a THIRD call to `resolve_and_mount_aux`
#       inside the classification loop (`"usr"` mount for RHEL 9 UsrMove), placed BEFORE the
#       function's definition further down the file. Bash executes sequentially, so the call
#       raised `resolve_and_mount_aux: command not found` on stderr, the `if` condition
#       evaluated false, and `SEPARATE_USR_MOUNTED` stayed "false". The failure signature was
#       INDISTINGUISHABLE from the actual PKNAME/os-release defect — same `outcome=Aborted`,
#       same `reason=no-attached-root-filesystem`, same `separateUsrMounted=false` — which is
#       why v2.1.2's critic review and 3 live rounds all missed it. v2.1.3 moves the
#       `resolve_and_mount_aux()` definition to sit alongside the other LVM/mount helpers
#       (immediately after `deactivate_source_vgs()`), well before ANY call site. Byte-for-byte
#       parity with the breaker script per Gates.md invariant 15. Regression coverage in
#       `Scripts/test_vmrepair_lvm_helpers.py::test_v213_resolve_and_mount_aux_defined_before_first_call`.
#     • `resolve_and_mount_aux` and `activate_lvm_pvs_and_enumerate_lvs` both derived their
#       "which disk hosts this device" answer from `lsblk -no PKNAME <dev> | head -n1`, with a
#       one-level walk-up added in v2.1.2. Live probe on `rhel-diag-145945/rescue` (2026-09-25)
#       confirmed PKNAME returns EMPTY for every LV spelling — `/dev/mapper/rootvg-usrlv`,
#       `/dev/rootvg/usrlv`, `/dev/dm-1` all yield '' — so the safety guard `devDisk ==
#       ATTACHED_DISK` failed and the `/usr` mount was refused, breaking v2.1.2's Option C fix.
#       Root cause: `lsblk -no PKNAME` on a DM logical-volume node reports the mapper's own
#       parent-DM devices, which have no PKNAME (the parent-tree walk needs the inverse tree,
#       not a single level). Fix: use `lsblk -snlo NAME "$dev" | tail -n1` — `-s` inverts the
#       tree so we walk from the target DOWN through parents to the disk; `-l` uses list mode
#       so tree-drawing glyphs are stripped; `tail -n1` picks the disk. Live-probe-verified:
#       `lsblk -snlo NAME /dev/mapper/rootvg-rootlv | tail -n1` returns `sda` on every LV form
#       AND every plain-partition form on the RHEL 9 rescue VM, with no regression on plain
#       partitions (Ubuntu, SLES, AlmaLinux paths). Applied at TWO sites — the v2.1.2 PBI-E
#       walk-up removed at the same time (single-level `lsblk -snlo` supersedes it).
#     • `activate_lvm_pvs_and_enumerate_lvs`: the vgchange-then-append block appended a VG to
#       `ACTIVATED_SOURCE_VGS` only when `vgchange -ay --select` returned 0. On LVM versions
#       where systemd's `pvscan` auto-activates the VG before the breaker runs, vgchange can
#       return non-zero even though activation succeeded. v2.1.2 evidence JSON reported
#       `activatedVgs=[]` on RHEL 9 despite classification proceeding via `lvs --select` (which
#       key on UUID). Fix: separate the intent from the observation — `vgchange -ay || true`,
#       then re-verify state via `lvs --select "vg_uuid=$U && lv_active=active"`. If ANY LV in
#       the VG is active (whether we activated it or systemd did), track the VG so cleanup
#       still deactivates it. Live-probe evidence: `vg_attr` does NOT include an active flag
#       (contrary to the initial fix-plan sketch that grepped `vg_attr`), so v2.1.3 queries
#       `lv_active=active` instead — the state flag actually lives on `lv_attr` at position 5.
#     • Scope: 2 sites × Fix A (LV-safe devDisk in resolve_and_mount_aux + LV-safe pvDisk
#       in activate_lvm_pvs_and_enumerate_lvs) + 2 map-miss fallbacks in the classification
#       loop (candidateDisk/partDisk, converted from PKNAME for future-proof defense against
#       LV_TO_DISK_MAP population failures) + 1 site × Fix B (autoactivation-aware track).
#       Schema stays at fix `1.5` / breaker `1.2` — no evidence-shape change.
#     • Scope boundary — Fix A assumes a SINGLE-LEAF inverse-tree. LV-over-MD-RAID and
#       multi-path (mpath) layouts produce ≥2 leaf disks, and `tail -n1` would pick one
#       arbitrarily. Neither layout applies to a single Azure managed data disk attached
#       to a repair VM (the SCSI-to-NVMe migration boundary explicitly targets a single-disk
#       attach), so the primitive is safe within scope. If future work extends the script
#       to multi-disk sources, Fix A must be revisited (either enumerate all leaves and
#       cross-check against ATTACHED_DISKS, or reject multi-leaf topologies explicitly).
#     • Byte-for-byte parity with linux-break-nvme-boot v2.1.3 per Gates.md design invariant 15.
#
#   v2.1.2 changes vs v2.1.1 (RHEL 9 UsrMove — /etc/os-release symlink resolution):
#     • Classification loop now mounts a separate `/usr` filesystem (if declared in the guest's
#       fstab) UNDER the candidate root before checking for `/etc/os-release`. Phase 5 v3
#       investigation (2026-09-24) proved on preserved RG
#       vmrepair-env-linux-fix-nvme-boot-offline-1-20260925012210 that RHEL 9's Marketplace image
#       uses the modern usr-merge layout: `/etc/os-release -> ../usr/lib/os-release`, and `/usr`
#       lives on a dedicated `rootvg-usrlv` LV per fstab. When the classifier mounts rootlv
#       standalone (no `/usr` underneath), `[ -f "$MOUNT_POINT/etc/os-release" ]` returns FALSE
#       because `-f` follows the symlink and the target `/usr/lib/os-release` does not exist
#       against the standalone rootlv. Every LV then fails classification and the script emits
#       `no-attached-root-filesystem` despite having successfully mounted every LV.
#     • Fix: reuse `resolve_and_mount_aux` to mount a fstab-declared `/usr` filesystem BEFORE the
#       os-release check. If fstab has no separate `/usr` entry (Ubuntu, Debian, etc.), the mount
#       is skipped and the check runs against the standalone rootlv as before. If fstab has a
#       separate `/usr` but the resolved device is not on the attached disk, mount is refused per
#       the existing safety guard (defense against stale-UUID drift to a third disk).
#     • `cleanup()` extended to unmount `/usr` alongside `/boot` and `/boot/efi` on script exit.
#     • Evidence JSON: `guest.lvm` gains `separateUsrMounted` (true|false) and `separateUsrDevice`
#       (device path or empty) so the outer test harness can prove Option C actually fired on
#       UsrMove layouts. schemaVersion bumps 1.4 → 1.5.
#     • Byte-for-byte parity with linux-break-nvme-boot v2.1.2 per Gates.md design invariant 15.
#
#   v2.1.1 changes vs v2.1.0 (defense-in-depth against udev / partition-scan races on
#   freshly-attached disks):
#     • Outer disk-iteration loop now calls `partprobe /dev/$d` + `udevadm settle --timeout=15`
#       BEFORE `lsblk -ln -o NAME,TYPE` per disk. Phase 5 Row 2 (2026-09-24) reproduced a race
#       where `lsblk -no FSTYPE` in the subsequent classification loop returned empty on a
#       freshly-attached RHEL 9 disk because the kernel had announced the parent block device
#       but partition FSTYPE metadata (populated by blkid via udev) was still in-flight.
#       Result: LVM_PARTITIONS stayed empty, the v2.1.0 vgchange --select fix was never reached,
#       and outcome fell through to `no-attached-root-filesystem` — identical evidence to the
#       original v2.0.0 failure. Live rescue-VM investigation confirmed the race. Fix ensures
#       the partition table is re-scanned and udev events flushed before any classification.
#       Also applied symmetric to the DEVICE_OVERRIDE branch for consistency.
#
#   v2.1.0 changes vs v2.0.0 (minimal, surgical — RHEL 9 LVM discovery fix):
#     • vgchange -ay/-an: use `--select "vg_uuid=$vguuid"` instead of `vgchange -ay/-an "$vguuid"`.
#       Verified live on RHEL 9 (2026-09-24): `vgchange -ay "$UUID"` reports
#       `Volume group "$UUID" not found` because vgchange interprets its positional argument as
#       a VG NAME, not a UUID (unlike `lvs --select` which does accept UUID). Symptom: script
#       reported outcome=Aborted, reason=no-attached-root-filesystem on RHEL 9 in Phase 4 Row 2.
#       Fix flips two call sites in `activate_lvm_pvs_and_enumerate_lvs` and
#       `deactivate_source_vgs` to the --select syntax; every other v2.0.1 hardening is preserved.
#
#   v2.0.0 hardens the v2.0.0 LVM+XFS support (from PBI-A P0):
#     • Correct ATTACHED_DISK derivation for LV sources (walk LV → PV partition → disk, not just
#       the LV's single PKNAME level).
#     • Collision-guard uses VG UUIDs, not names, for vgrename/vgchange/lvs `--select` — per
#       `man vgrename`, name-based lookup is ambiguous in exactly the collision scenario.
#     • Deactivation cleanup verifies via `lvs -o lv_active --select vg_uuid=...` polling and
#       retries up to 3 times with a 1 s sleep, logging any lingering leak to stderr.
#     • Multi-PV VGs de-duplicated so a single VG is not processed once per PV.
#     • Evidence JSON emits `guest.lvm` = `{activatedVgs[], renamedVgs[], enumeratedLvs[]}`.
#     • `udevadm settle` before `vgscan --cache` for defense-in-depth on freshly-attached disks.
#
# .DESCRIPTION
#   (unchanged from v0.4.0 — see DESIGN NOTES below for the full contract.)
#
# .DESIGN NOTES
#
#   Log routing invariant: any helper function whose result is captured via command substitution
#   (`$(...)`) must NOT call the framework's `Log-*` helpers on stdout, because Logger.sh writes
#   to stdout without `>&2`. Instead, such helpers either (a) set a documented global variable and
#   return an exit code (preferred), or (b) redirect their own diagnostic output to `>&2`. In v0.4+
#   `resolve_and_mount_aux` uses pattern (a): sets `RESOLVED_AUX_DEV` and returns exit code only.
#
#   Parallel-array alignment invariant (unchanged): INITRAMFS_IMAGES, IMAGE_HAS_NVME,
#   IMAGE_VERIFY_METHODS, IMAGE_SKIP_REASON, POST_REBUILD_HAS_NVME, POST_REBUILD_METHODS must all
#   have the same length at every point where build_images_json is called.
#
#   Regex tolerance (unchanged): verify_initramfs_has_nvme() accepts `nvme.ko` + compressed
#   variants (`.xz`/`.zst`/`.gz`) and both `nvme_core`/`nvme-core` on-disk names.
#
#   Skip-list (unchanged): rescue and kdump initramfs images are backed up but neither rebuilt nor
#   gated in the pass/fail decision.
#
#   LVM+XFS root support (v2.0+): the script activates any LVM volume groups discovered on the
#   attached OS disk (`vgscan --cache` after a defensive `udevadm settle`), enumerates their
#   logical volumes via `lvs --select vg_uuid=...`, classifies each LV's filesystem, and adds
#   ext4/xfs LVs to the OS partition candidate list. Covers RHEL 9 and SLES 15 SP5 default
#   Marketplace images. A per-invocation LV→disk map (LV_TO_DISK_MAP) records the true parent
#   disk of each LV via `lsblk -snlo NAME <pv-partition> | tail -n1` (v2.1.3 spelling — see
#   header change log; the v2.0-era `lsblk -no PKNAME` returned empty on DM/LV forms and the
#   v2.1.2 walk-up around it was incorrect on the DM/LV case). Multi-PV VGs are de-duplicated
#   per invocation via a local seen-VGs set keyed on VG UUID.
#
#   Collision handling: if a source VG name collides with a VG name already present on the
#   rescue VM (unusual — rescue is stock Ubuntu 22.04 which has no LVM by default), the source
#   VG is renamed via `vgrename UUID NEWNAME`. Name-based lookup is documented as ambiguous in
#   exactly this collision case (`man vgrename`); UUID-based lookup is not. All subsequent
#   VG operations (`vgchange -ay`, `lvs --select`) also key on UUID to keep the disambiguation
#   in effect through the whole helper.
#
#   Cleanup: on exit, activated source VGs are deactivated (`vgchange -an <uuid>`), verified
#   via `lvs --noheadings -o lv_active --select vg_uuid=<uuid>` polling, and retried up to
#   3 times with a 1 s sleep. Any lingering leak is logged to stderr so the evidence log
#   records it. Renamed VGs are reversed back to their original names before exit.
#
#   Scope boundary — Btrfs: still refused. Azure SLES 15 SP5 Marketplace images use LVM+XFS,
#   not Btrfs; Btrfs is only introduced by SUSE 16 (Marketplace ETA future). If SUSE 16 shows
#   up in customer telemetry, a separate PBI (currently archived) reactivates.
#
#   Scope boundary — LUKS: still refused. Encrypted disks require the customer's passphrase or
#   key material, which offline repair cannot obtain.
#
#
#   Scope boundary — /boot/efi is defensive-mount only: the EFI System Partition is resolved via
#   fstab and mounted read-only for visibility (so that a future revision can extend the scope to
#   EFI-binary changes without changing the discovery code), but v0.5 never writes to it, never
#   backs it up, and never restores from it. When that scope changes, the manifest per-filesystem
#   free-space split (currently root/boot two buckets) MUST be extended to a third bucket for
#   `boot/efi/*` before any file under boot/efi/ can appear in the manifest.
#
#   XFS UUID collision: XFS refuses to mount a filesystem whose UUID is already known to the kernel
#   (a real, common repair-VM gotcha when the repair VM was cloned from the same base image as the
#   guest under repair). Every `mount -o ro …` call in this script therefore retries once with
#   `nouuid` appended when the source device's FSTYPE is `xfs` and the first attempt failed.
#
# .PARAMETER 1 (Mode)   Report (default) | Repair | Rollback
# .PARAMETER 2 (DeviceOverride)   Optional device such as /dev/sdc or /dev/nvme1n1 (whole disk).
# .PARAMETER 3 (BackupDir)   Required in Rollback mode. Absolute path to a Repair-mode evidence dir.
#
########################################################################################################

. ./src/linux/common/setup/init.sh

# ----------------------------------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------------------------------
MODE_INPUT="${1:-Report}"
DEVICE_OVERRIDE="${2:-}"
BACKUP_DIR_INPUT="${3:-}"

case "$(printf '%s' "$MODE_INPUT" | tr '[:upper:]' '[:lower:]')" in
    report)   MODE="Report" ;;
    repair)   MODE="Repair" ;;
    rollback) MODE="Rollback" ;;
    *)
        Log-Error "Unrecognized Mode '$MODE_INPUT'. Expected: Report | Repair | Rollback."
        exit $STATUS_ERROR
        ;;
esac

TIMESTAMP=$(date +%Y%m%d%H%M%S)
RUN_ID="nvme-fix-${TIMESTAMP}-$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-8 || echo "$$")"
EVIDENCE_DIR="/tmp/${RUN_ID}"
MOUNT_POINT="/tmp/${RUN_ID}-root"

STATUS=$STATUS_ERROR
OUTCOME="Unknown"
OS_PARTITION=""
ATTACHED_DISK=""
BOOT_PARTITION=""
BOOT_EFI_PARTITION=""
DISTRO_ID=""
DISTRO_VER=""
INITRAMFS_TOOL=""
FAILURE_REASON=""

# Helper output globals: set by resolve_and_mount_aux(); do not use command substitution on it.
RESOLVED_AUX_DEV=""

# v2.1.4 (Fix D): track ALL aux mounts (usr, var, tmp) the classifier established under the
# candidate root. `separateAuxMounts` in evidence JSON records the per-mount state. Legacy
# `SEPARATE_USR_MOUNTED` / `SEPARATE_USR_DEVICE` scalars retained as backward-compat aliases
# that mirror the "usr" entry byte-for-byte — external test harnesses reading v2.1.2-1.5 evidence
# JSON continue to work unchanged.
declare -A SEPARATE_AUX_MOUNTED=([usr]="false" [var]="false" [tmp]="false")
declare -A SEPARATE_AUX_DEVICE=([usr]="" [var]="" [tmp]="")

# v2.1.2 (PBI-E v3): legacy scalars — mirror `SEPARATE_AUX_MOUNTED[usr]` / `SEPARATE_AUX_DEVICE[usr]`.
# Kept so `build_lvm_json` can still emit `separateUsrMounted` / `separateUsrDevice` fields as
# backward-compat aliases in the evidence JSON.
SEPARATE_USR_MOUNTED="false"
SEPARATE_USR_DEVICE=""

declare -a INITRAMFS_IMAGES=()
declare -a IMAGE_VERIFY_METHODS=()
declare -a IMAGE_HAS_NVME=()
declare -a IMAGE_SKIP_REASON=()
declare -a POST_REBUILD_HAS_NVME=()
declare -a POST_REBUILD_METHODS=()

# ----------------------------------------------------------------------------------------------------
# Cleanup / trap
# ----------------------------------------------------------------------------------------------------
cleanup() {
    for pseudo in run sys proc dev/pts dev; do
        if mountpoint -q "$MOUNT_POINT/$pseudo" 2>/dev/null; then
            umount -R "$MOUNT_POINT/$pseudo" 2>/dev/null || umount -l "$MOUNT_POINT/$pseudo" 2>/dev/null || true
        fi
    done
    # v2.1.4 (Fix D): unmount ALL aux mounts BEFORE `/boot`, `/boot/efi`, and the root.
    # Leaf-first order (`tmp`, `var`, then `usr`) matches the mount-order symmetry — the loop
    # is safe to call regardless of which aux mounts fired because `mountpoint -q` gates
    # each entry. `/boot/efi` and `/boot` stay ordered leaf-first as before.
    for aux in boot/efi boot tmp var usr; do
        if mountpoint -q "$MOUNT_POINT/$aux" 2>/dev/null; then
            umount "$MOUNT_POINT/$aux" 2>/dev/null || umount -l "$MOUNT_POINT/$aux" 2>/dev/null || true
        fi
    done
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        sync 2>/dev/null || true
        umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    fi
    # v2.0.0: deactivate any source VGs we activated, and rename back any we renamed on collision.
    if declare -F deactivate_source_vgs >/dev/null 2>&1; then
        deactivate_source_vgs
    fi
}
trap cleanup EXIT

mkdir -p "$EVIDENCE_DIR" "$MOUNT_POINT" 2>/dev/null || {
    Log-Error "Could not create working directories under /tmp."
    exit $STATUS_ERROR
}

# ----------------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------------
json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

# Strip a single pair of surrounding double quotes from an fstab value, if present.
strip_quotes() {
    local v="$1"
    if [[ ${#v} -ge 2 && "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
        printf '%s' "${v:1:${#v}-2}"
    else
        printf '%s' "$v"
    fi
}

# Mount $dev at $target with $opts (containing at least `ro`), retrying once with `,nouuid`
# appended if the first attempt failed AND $dev is XFS-typed. Returns 0 on success, non-zero on
# failure. Emits nothing on stdout — safe to call from a helper whose result is captured via
# command substitution.
try_mount_ro_with_nouuid_retry() {
    local dev="$1"
    local target="$2"
    local opts="$3"
    if mount -o "$opts" "$dev" "$target" 2>/dev/null; then
        return 0
    fi
    local fstype
    fstype=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 || echo "")
    if [ "$fstype" != "xfs" ]; then
        return 1
    fi
    mount -o "${opts},nouuid" "$dev" "$target" 2>/dev/null
}

# Same idea for RW re-mounts. Used by Repair/Rollback when the initial `mount -o remount,rw` fails
# and the code falls back to unmount+mount.
try_mount_rw_with_nouuid_retry() {
    local dev="$1"
    local target="$2"
    if mount "$dev" "$target" 2>/dev/null; then
        return 0
    fi
    local fstype
    fstype=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 || echo "")
    if [ "$fstype" != "xfs" ]; then
        return 1
    fi
    mount -o nouuid "$dev" "$target" 2>/dev/null
}

# v2.0.1 — LVM helpers (hardened from v2.0.0 per critic round 1) ------------------------------------
# Track VGs (BY UUID) we activated so we can deactivate them on exit (see cleanup()).
declare -a ACTIVATED_SOURCE_VGS=()

# Track VGs that we had to rename to avoid a name collision with a VG already on the rescue VM.
# Entries are the pair "<renamed-name>=<original-name>" so the cleanup can rename them back.
declare -a RENAMED_SOURCE_VGS=()

# LV → attached-disk map. Populated by activate_lvm_pvs_and_enumerate_lvs() so the classification
# loop can look up the correct ATTACHED_DISK for an LV-sourced OS_PARTITION without walking
# `lsblk -no PKNAME <lv>` (which returns EMPTY on DM/LV forms — see v2.1.3 header notes).
declare -A LV_TO_DISK_MAP=()

# LVs enumerated during activation (persists across the run for evidence JSON).
declare -a LVM_ENUMERATED_LVS=()

# Activate any LVM PVs on the attached OS disk (NOT on the repair VM's root disk) and enumerate
# every ext4/xfs logical volume they expose.
#
# v2.1.4 (Fix E) — contract change: this helper NO LONGER emits LV paths on stdout. Callers
# invoke it as a direct call (not via `$(...)`) and iterate the parent-shell `LVM_ENUMERATED_LVS`
# global array. The stdout-emission form used in v2.0.1–v2.1.3 forced callers into command
# substitution, whose subshell scope discarded every `+=` array update inside this function —
# defeating Fix B (autoactivation-aware VG tracking) since v2.1.0 and reporting
# `activatedVgs=[]` / `enumeratedLvs=[]` in every evidence JSON despite runtime logs showing
# successful activation. Local reproducer proving the mechanism:
# `Output/TestReports/Local-linux-fix-nvme-boot-v2.1.3/2026-09-25/fix-E-subshell-repro-v2.sh`.
#
# v2.0.1 changes vs v2.0.0:
#   (1) Uses VG UUIDs for all rename/activate/enumerate ops so the ambiguity documented in
#       `man vgrename` when a VG name collides is avoided.
#   (2) De-duplicates VGs seen across multiple PVs so `vgchange -ay` is not called twice for
#       the same VG.
#   (3) Populates LV_TO_DISK_MAP with the correct disk (from the PV partition's `lsblk -no PKNAME`)
#       so the caller does not incorrectly re-derive ATTACHED_DISK from the LV's own single-level
#       PKNAME walk.
#   (4) `udevadm settle` before `vgscan --cache` for defense-in-depth on freshly-attached disks.
activate_lvm_pvs_and_enumerate_lvs() {
    local lvm_partitions="$1"
    local pv vgname vguuid pvDisk lv lv_fstype
    local -A seen_vgs=()

    if ! command -v vgscan >/dev/null 2>&1 || ! command -v vgchange >/dev/null 2>&1 \
       || ! command -v pvs >/dev/null 2>&1 || ! command -v lvs >/dev/null 2>&1; then
        return 1
    fi

    # Defense-in-depth against a udev race on a freshly-attached disk.
    if command -v udevadm >/dev/null 2>&1; then
        if ! udevadm settle --timeout=5 >/dev/null 2>&1; then
            printf '%s\n' "[Warning] udevadm settle --timeout=5 did not complete cleanly; proceeding with a possibly-stale device view." >&2
        fi
    fi
    vgscan --cache >/dev/null 2>&1 || true

    for pv in $lvm_partitions; do
        vgname=$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | awk '{print $1}' || echo "")
        vguuid=$(pvs --noheadings -o vg_uuid "$pv" 2>/dev/null | awk '{print $1}' || echo "")
        [ -z "$vgname" ] || [ -z "$vguuid" ] && continue

        # v2.1.3: LV-safe devDisk derivation. `lsblk -no PKNAME` returns empty on DM/LV forms;
        # inverse-tree list mode (`-snl`) walks from the target down through parents to the
        # disk and `tail -n1` picks the disk basename. Verified live on RHEL 9 rescue VM
        # 2026-09-25: correct on every LV spelling AND every plain partition spelling. Note
        # $pv here is always a PARTITION (LVM_PARTITIONS is populated from the outer
        # classification loop's blkid FSTYPE=LVM2_member matches), so -snlo on a partition is
        # the regression-safe case, but we use the same spelling as `resolve_and_mount_aux`
        # for consistency and future-proofing.
        pvDisk=$(lsblk -snlo NAME "$pv" 2>/dev/null | tail -n1 || echo "")

        # De-dup: skip if we already processed this VG via another PV in the same VG.
        [ -n "${seen_vgs[$vguuid]:-}" ] && continue
        seen_vgs[$vguuid]=1

        # Collision guard: if the rescue VM's own root disk already exposes a VG with the same
        # NAME but a DIFFERENT UUID, rename OUR (source) VG. Use UUID as the operative
        # identifier — `vgrename NAME NEWNAME` is ambiguous in exactly this scenario per
        # `man vgrename`; `vgrename UUID NEWNAME` is not.
        local collision="false"
        while IFS= read -r existing_line; do
            local existing_name existing_uuid
            existing_name=$(printf '%s' "$existing_line" | awk '{print $1}')
            existing_uuid=$(printf '%s' "$existing_line" | awk '{print $2}')
            if [ "$existing_name" = "$vgname" ] && [ "$existing_uuid" != "$vguuid" ]; then
                collision="true"
                break
            fi
        done < <(vgs --noheadings -o vg_name,vg_uuid 2>/dev/null)

        if [ "$collision" = "true" ]; then
            local new_vgname="${vgname}_src$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            if vgrename "$vguuid" "$new_vgname" >/dev/null 2>&1; then
                RENAMED_SOURCE_VGS+=("${new_vgname}=${vgname}")
                vgname="$new_vgname"
            fi
        fi

        # v2.1.0 — activate via --select "vg_uuid=..." (positional `vgchange -ay UUID` reports
        # `Volume group "UUID" not found` because vgchange treats its positional arg as a VG NAME).
        #
        # v2.1.3 — autoactivation-aware tracking. On LVM versions where systemd's pvscan
        # auto-activates the VG before this script runs, `vgchange -ay --select` can return
        # non-zero even though activation succeeded. Prior versions therefore never appended
        # such VGs to ACTIVATED_SOURCE_VGS, so cleanup left them active on the rescue VM
        # (leaked device-mapper nodes) and evidence JSON reported `activatedVgs=[]` despite
        # the LVs being live. Fix: separate intent (`vgchange -ay || true`) from observation
        # (query LV activation state). Any VG whose LVs are active — whether we activated it
        # or systemd did — is tracked so cleanup deactivates it uniformly. `vg_attr` has no
        # active flag (positions 1-6 are Permissions/Resi(z)eable/E(x)ported/(p)artial/
        # Allocation/(c)lustered); the active flag lives on `lv_attr` at position 5. Using
        # `--select "lv_active=active"` is the declarative equivalent of that positional test.
        vgchange -ay --select "vg_uuid=$vguuid" >/dev/null 2>&1 || true
        if [ -n "$(lvs --noheadings -o lv_name --select "vg_uuid=$vguuid && lv_active=active" 2>/dev/null)" ]; then
            ACTIVATED_SOURCE_VGS+=("$vguuid")
        fi

        # Enumerate LVs in this VG BY UUID. For each ext4/xfs LV, record the (LV → disk)
        # mapping AND append to LVM_ENUMERATED_LVS. v2.1.4 (Fix E): NO longer emits LV paths
        # on stdout — the helper is invoked as a direct call (not via `$(...)` command
        # substitution), so the array appends persist in the parent shell. Callers iterate
        # `LVM_ENUMERATED_LVS[@]` directly. Prior stdout emission was the ONLY consumer that
        # made the subshell wrap necessary; removing it fixes Fix B's observable effect (which
        # was masked by the same subshell defect since v2.1.0).
        while IFS= read -r lv; do
            [ -z "$lv" ] && continue
            lv_fstype=$(blkid -s TYPE -o value "$lv" 2>/dev/null || echo "")
            case "$lv_fstype" in
                ext2|ext3|ext4|xfs)
                    LV_TO_DISK_MAP[$lv]="$pvDisk"
                    LVM_ENUMERATED_LVS+=("$lv")
                    ;;
            esac
        done < <(lvs --noheadings -o lv_path --select "vg_uuid=$vguuid" 2>/dev/null | awk '{print $1}')
    done

    return 0
}

# Called from cleanup(). Deactivates any VGs we activated (BY UUID), verifies inactivity via
# `lvs --select "vg_uuid=$vguuid"`, retries with a short sleep, and logs any lingering leak to
# stderr so the evidence log at least records the problem. Then reverses any renames.
deactivate_source_vgs() {
    local vguuid still_active attempt pair renamed original
    for vguuid in "${ACTIVATED_SOURCE_VGS[@]}"; do
        still_active=0
        for attempt in 1 2 3; do
            vgchange -an --select "vg_uuid=$vguuid" >/dev/null 2>&1 || true
            # Note: `--select vg_uuid=...` intentionally includes hidden/internal LVs
            # (thin-pool tdata/tmeta, RAID metadata, cache metadata) so the leak-detection
            # retry catches them too — they hold device-mapper nodes just like user LVs.
            still_active=$(lvs --noheadings -o lv_active --select "vg_uuid=$vguuid" 2>/dev/null | grep -c 'active' || echo 0)
            [ "$still_active" -eq 0 ] && break
            sleep 1
        done
        if [ "${still_active:-0}" -ne 0 ]; then
            printf '%s\n' "[Warning] VG uuid=$vguuid still has active LVs after 3 attempts; lingering device-mapper nodes may persist on the rescue VM." >&2
        fi
    done
    for pair in "${RENAMED_SOURCE_VGS[@]}"; do
        renamed="${pair%%=*}"
        original="${pair##*=}"
        vgchange -an "$renamed" >/dev/null 2>&1 || true
        vgrename "$renamed" "$original" >/dev/null 2>&1 || true
    done
}

# NOTE: definition location matters -- this function must appear BEFORE the first call site,
# which is in the classification loop's separate-/usr mount step (v2.1.2's Option C, made
# reachable in v2.1.3 by Fix C). Bash executes sequentially; a forward reference resolves to
# 'command not found' and the classifier silently falls through with no separateUsrMounted
# evidence recorded. See PBI-E 'v2.1.3 Row 2 rerun' analysis (Output/TestReports/Local-linux-
# fix-nvme-boot-v2.1.3/2026-09-25/row2-fail-analysis.md).
# ----------------------------------------------------------------------------------------------------
# Resolve and mount a separate /boot (and /boot/efi) partition if fstab declares one.
#
# CONTRACT: sets $RESOLVED_AUX_DEV to the mounted device path on success and returns 0. Returns
# non-zero if the fstab entry is missing, cannot be resolved, or cannot be mounted. This helper
# calls Log-* directly (safe: called as a plain statement, NOT via command substitution).
# ----------------------------------------------------------------------------------------------------
resolve_and_mount_aux() {
    local mp="$1"        # "boot" or "boot/efi"
    local mpTarget="/$mp"
    RESOLVED_AUX_DEV=""

    # Match the fstab line whose field-2 is the mount target (with or without trailing slash).
    local fstabLine
    fstabLine=$(awk -v mp="$mpTarget" -v mps="${mpTarget}/" \
        '$1 !~ /^#/ && ($2 == mp || $2 == mps) { print; exit }' \
        "$MOUNT_POINT/etc/fstab" 2>/dev/null || echo "")
    if [ -z "$fstabLine" ]; then
        return 0    # not declared; not an error
    fi

    local spec opts
    spec=$(printf '%s' "$fstabLine" | awk '{print $1}')
    opts=$(printf '%s' "$fstabLine" | awk '{print $4}')
    spec=$(strip_quotes "$spec")

    local dev=""
    case "$spec" in
        UUID=*)     dev=$(blkid -U "${spec#UUID=}" 2>/dev/null || echo "") ;;
        LABEL=*)    dev=$(blkid -L "${spec#LABEL=}" 2>/dev/null || echo "") ;;
        PARTUUID=*) dev=$(blkid -o device -t "PARTUUID=${spec#PARTUUID=}" 2>/dev/null | head -n1 || echo "") ;;
        /dev/*)     dev="$spec" ;;
        *)          dev="" ;;
    esac

    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        Log-Warning "Could not resolve fstab entry '$spec' for $mpTarget to a block device."
        return 1
    fi

    # Safety cross-checks: refuse if resolved device is on the repair VM's root disk, and refuse if
    # it is NOT on the same disk as the attached OS partition (defense against a stale fstab UUID
    # resolving to an unrelated third disk).
    #
    # v2.1.3 (PBI-E follow-up): devDisk via inverse-tree list. `lsblk -no PKNAME` returns
    # EMPTY for every LV spelling on RHEL 9 (`/dev/mapper/rootvg-usrlv`, `/dev/rootvg/usrlv`,
    # `/dev/dm-1` all yield '') because the immediate parent-of-DM is another DM node with
    # no PKNAME reflected in that single-column query. v2.1.2's one-level walk-up was based
    # on an incorrect assumption that PKNAME would return the PV partition; the live probe
    # (2026-09-25 on `rhel-diag-145945/rescue`) proved otherwise. Fix: `-s` inverts the tree
    # so we walk from the target DOWN through parents to the disk; `-l` uses list mode so
    # tree-drawing glyphs (`-, |, backtick) are stripped from the output; `-n` removes the
    # header; `-o NAME` selects the name column. `tail -n1` picks the disk (last node in the
    # inverted chain).
    #
    # Verified live 2026-09-25:
    #   /dev/mapper/rootvg-rootlv  ->  'sda'
    #   /dev/mapper/rootvg-usrlv   ->  'sda'
    #   /dev/rootvg/rootlv         ->  'sda'
    #   /dev/rootvg/usrlv          ->  'sda'
    #   /dev/dm-4                  ->  'sda'
    #   /dev/dm-1                  ->  'sda'
    #   /dev/sda1..sda4            ->  'sda'  (regression-safe on plain partitions)
    #   /dev/sdb1                  ->  'sdb'  (regression-safe on rescue VM's own root)
    local devDisk
    devDisk=$(lsblk -snlo NAME "$dev" 2>/dev/null | tail -n1 || echo "")
    if [ "$devDisk" = "$ROOT_DISK" ]; then
        Log-Error "Resolved $mpTarget device '$dev' is on the repair VM's own root disk. Refusing."
        return 1
    fi
    if [ -n "$ATTACHED_DISK" ] && [ "$devDisk" != "$ATTACHED_DISK" ]; then
        Log-Error "Resolved $mpTarget device '$dev' (on disk $devDisk) is NOT on the attached OS disk ($ATTACHED_DISK). Refusing."
        return 1
    fi

    # Assemble mount options: always start with `ro`, then append caller-declared options that pass
    # a strict ALLOWLIST. Anything not on the list is dropped with a Log-Warning. The allowlist covers
    # options a /boot mount legitimately needs to succeed offline (subvol, noload, norecovery) plus
    # safety hardening (nodev/nosuid/noexec/noatime).
    local mountOpts="ro"
    if [ -n "$opts" ] && [ "$opts" != "defaults" ] && [ "$opts" != "-" ]; then
        local o
        IFS=',' read -ra optArr <<< "$opts"
        for o in "${optArr[@]}"; do
            case "$o" in
                ""|rw|defaults|auto|noauto|ro) ;;                              # explicitly ignored
                noload|norecovery|noatime|nodev|nosuid|noexec) mountOpts="${mountOpts},${o}" ;;
                subvol=*|subvolid=*)                            mountOpts="${mountOpts},${o}" ;;
                *)
                    Log-Warning "Dropping unrecognized fstab option '$o' for $mpTarget (allowlist policy)."
                    ;;
            esac
        done
    fi

    mkdir -p "$MOUNT_POINT/$mp" 2>/dev/null || true
    if try_mount_ro_with_nouuid_retry "$dev" "$MOUNT_POINT/$mp" "$mountOpts"; then
        Log-Info "Mounted separate $mpTarget ($dev, opts=$mountOpts) at $MOUNT_POINT/$mp"
        RESOLVED_AUX_DEV="$dev"
        return 0
    fi

    Log-Warning "fstab declares $mpTarget on '$dev' but the mount failed (opts=$mountOpts)."
    return 1
}

build_images_json() {
    local i=0
    local out=""
    while [ $i -lt "${#INITRAMFS_IMAGES[@]}" ]; do
        local sep=","
        [ $i -eq 0 ] && sep=""
        local path="${INITRAMFS_IMAGES[$i]}"
        local preHas="${IMAGE_HAS_NVME[$i]:-}"
        local preMethod="${IMAGE_VERIFY_METHODS[$i]:-}"
        local skip="${IMAGE_SKIP_REASON[$i]:-}"
        local postHas="${POST_REBUILD_HAS_NVME[$i]:-}"
        local postMethod="${POST_REBUILD_METHODS[$i]:-}"
        local preHasField preMethodField postHasField postMethodField skipField

        if [ -z "$preHas" ]; then preHasField="null"; else preHasField="\"$(json_escape "$preHas")\""; fi
        if [ -z "$preMethod" ]; then preMethodField="null"; else preMethodField="\"$(json_escape "$preMethod")\""; fi
        if [ -z "$postHas" ]; then postHasField="null"; else postHasField="\"$(json_escape "$postHas")\""; fi
        if [ -z "$postMethod" ]; then postMethodField="null"; else postMethodField="\"$(json_escape "$postMethod")\""; fi
        if [ -z "$skip" ]; then skipField="null"; else skipField="\"$(json_escape "$skip")\""; fi

        out="${out}${sep}{\"path\":\"$(json_escape "$path")\",\"preHasNvme\":${preHasField},\"preMethod\":${preMethodField},\"postHasNvme\":${postHasField},\"postMethod\":${postMethodField},\"skipped\":${skipField}}"
        i=$((i + 1))
    done
    printf '[%s]' "$out"
}

emit_evidence() {
    local outcome="$1"
    local reason="$2"
    local backupDir="$3"
    local imagesJson
    imagesJson=$(build_images_json)

    # v2.0.1 — build a JSON array segment for LVM state (activated VG UUIDs, renamed VG pairs,
    # enumerated LV device paths). v2.1.2 (PBI-E v3): extended to include separateUsrMounted
    # and separateUsrDevice so downstream reporting can prove the UsrMove classification path
    # fired.
    local lvmJson
    lvmJson=$(build_lvm_json)

    local jsonOut="$EVIDENCE_DIR/evidence.json"
    cat > "$jsonOut" <<EOF
{"schemaVersion":"1.6","scenario":"scsi-to-nvme-migration","producedBy":"linux-fix-nvme-boot","producedAtUtc":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","mode":"$MODE","outcome":"$outcome","reason":"$(json_escape "$reason")","os":{"family":"linux","distro":"$(json_escape "$DISTRO_ID")","version":"$(json_escape "$DISTRO_VER")"},"guest":{"osPartition":"$(json_escape "$OS_PARTITION")","attachedDisk":"$(json_escape "$ATTACHED_DISK")","bootPartition":"$(json_escape "$BOOT_PARTITION")","bootEfiPartition":"$(json_escape "$BOOT_EFI_PARTITION")","initramfsTool":"$(json_escape "$INITRAMFS_TOOL")","images":$imagesJson,"lvm":$lvmJson},"backupDir":"$(json_escape "$backupDir")","evidencePath":"$(json_escape "$EVIDENCE_DIR")"}
EOF
    Log-Output "[NVME-FIX-JSON]$(cat "$jsonOut")"
}

# v2.0.1 — emit LVM state for the evidence JSON audit trail. Format:
#   {"activatedVgs":["<uuid>",...],"renamedVgs":[{"renamed":"...","original":"..."},...],
#    "enumeratedLvs":["<lv-path>",...],
#    "separateUsrMounted":"true|false","separateUsrDevice":"<device or empty>"}
# v2.1.2 (PBI-E v3): separateUsrMounted / separateUsrDevice added so downstream reporting
# can distinguish UsrMove-family layouts (RHEL 8+, Fedora 32+, AlmaLinux 9, Rocky 9, etc.)
# where the classifier had to mount `/usr` under the candidate root to resolve the
# `/etc/os-release` symlink from single-partition layouts (Ubuntu, older SLES/RHEL) where
# it did not.
build_lvm_json() {
    local i sep
    local activated=""
    local renamed=""
    local enumerated=""

    i=0
    for vguuid in "${ACTIVATED_SOURCE_VGS[@]}"; do
        sep=","; [ $i -eq 0 ] && sep=""
        activated="${activated}${sep}\"$(json_escape "$vguuid")\""
        i=$((i + 1))
    done

    i=0
    for pair in "${RENAMED_SOURCE_VGS[@]}"; do
        sep=","; [ $i -eq 0 ] && sep=""
        local r="${pair%%=*}"
        local o="${pair##*=}"
        renamed="${renamed}${sep}{\"renamed\":\"$(json_escape "$r")\",\"original\":\"$(json_escape "$o")\"}"
        i=$((i + 1))
    done

    i=0
    for lv in "${LVM_ENUMERATED_LVS[@]}"; do
        sep=","; [ $i -eq 0 ] && sep=""
        enumerated="${enumerated}${sep}\"$(json_escape "$lv")\""
        i=$((i + 1))
    done

    # v2.1.4 (Fix D): emit `separateAuxMounts` object with per-aux {mounted,device}. Retains
    # legacy `separateUsrMounted` / `separateUsrDevice` scalar aliases (mirror the "usr" entry
    # byte-for-byte) so v2.1.2/1.3/1.5-era consumers keep working.
    local auxMounts=""
    local first="true"
    for aux in usr var tmp; do
        [ "$first" = "true" ] || auxMounts="${auxMounts},"
        first="false"
        auxMounts="${auxMounts}\"${aux}\":{\"mounted\":\"${SEPARATE_AUX_MOUNTED[$aux]}\",\"device\":\"$(json_escape "${SEPARATE_AUX_DEVICE[$aux]}")\"}"
    done

    printf '{"activatedVgs":[%s],"renamedVgs":[%s],"enumeratedLvs":[%s],"separateUsrMounted":"%s","separateUsrDevice":"%s","separateAuxMounts":{%s}}' \
        "$activated" "$renamed" "$enumerated" \
        "$SEPARATE_USR_MOUNTED" "$(json_escape "$SEPARATE_USR_DEVICE")" \
        "$auxMounts"
}

verify_initramfs_has_nvme() {
    local img="$1"
    local methodFile="$2"
    local list

    if command -v lsinitrd >/dev/null 2>&1; then
        list=$(lsinitrd "$img" 2>/dev/null || true)
        printf 'lsinitrd\n' > "$methodFile"
    elif command -v lsinitramfs >/dev/null 2>&1; then
        list=$(lsinitramfs "$img" 2>/dev/null || true)
        printf 'lsinitramfs\n' > "$methodFile"
    else
        printf 'binary-scan(low-confidence)\n' > "$methodFile"
        if grep -a -qE 'nvme_core' "$img" 2>/dev/null && grep -a -qE 'nvme\.ko' "$img" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    if printf '%s' "$list" | grep -qE '(^|/)nvme\.ko(\.[a-z0-9]+)?$' && \
       printf '%s' "$list" | grep -qE '(^|/)nvme[-_]core\.ko(\.[a-z0-9]+)?$'; then
        return 0
    fi
    return 1
}

extract_kver_from_image() {
    local base
    base=$(basename "$1")
    if [[ "$base" =~ ^initramfs-(.+)\.img$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$base" =~ ^initrd\.img-(.+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$base" =~ ^initrd-(.+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    printf ''
}

classify_non_primary_boot() {
    local base
    base=$(basename "$1")
    if [[ "$base" =~ -rescue- ]]; then
        printf 'non-primary-boot-image'
        return 0
    fi
    if [[ "$base" =~ kdump\.img$ ]] || [[ "$base" =~ kdump$ ]]; then
        printf 'non-primary-boot-image'
        return 0
    fi
    printf ''
}

# ----------------------------------------------------------------------------------------------------
# Discover repair VM's own root disk (so we do not touch it)
# ----------------------------------------------------------------------------------------------------
ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || echo "")
Log-Info "Repair VM root device: ${ROOT_SOURCE:-unknown} (disk: ${ROOT_DISK:-unknown})"

if [ -z "$ROOT_DISK" ]; then
    Log-Error "Could not identify the repair VM's own root disk. Refusing to run without knowing what to skip."
    FAILURE_REASON="repair-vm-root-disk-unknown"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

# ----------------------------------------------------------------------------------------------------
# Locate the attached OS root partition
# ----------------------------------------------------------------------------------------------------
CANDIDATES=""
if [ -n "$DEVICE_OVERRIDE" ]; then
    if [ ! -b "$DEVICE_OVERRIDE" ]; then
        Log-Error "DeviceOverride '$DEVICE_OVERRIDE' is not a block device."
        FAILURE_REASON="device-override-not-block"
        emit_evidence "Aborted" "$FAILURE_REASON" ""
        exit $STATUS_ERROR
    fi
    OVERRIDE_BASENAME=$(basename "$DEVICE_OVERRIDE")
    if [ "$OVERRIDE_BASENAME" = "$ROOT_DISK" ]; then
        Log-Error "DeviceOverride '$DEVICE_OVERRIDE' points at the repair VM's own root disk. Refusing."
        FAILURE_REASON="device-override-is-repair-root"
        emit_evidence "Aborted" "$FAILURE_REASON" ""
        exit $STATUS_ERROR
    fi
    ATTACHED_DISK="$OVERRIDE_BASENAME"
    # v2.1.1 — force partition-table refresh + wait for udev events on the target disk
    # before enumerating partitions. See fix in the auto-discovery branch below for the
    # symmetric change and the incident-report reference.
    if command -v partprobe >/dev/null 2>&1; then partprobe "$DEVICE_OVERRIDE" 2>/dev/null || true; fi
    if command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=15 >/dev/null 2>&1 || true; fi
    CANDIDATES=$(lsblk -ln -o NAME,TYPE "$DEVICE_OVERRIDE" 2>/dev/null | awk '$2=="part"{print "/dev/"$1}' || echo "")
    Log-Info "Using device override: $DEVICE_OVERRIDE"
else
    for d in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        [ "$d" = "$ROOT_DISK" ] && continue
        # v2.1.1 — force partition-table refresh + wait for udev events per disk. Phase 5
        # Row 2 rerun (2026-09-24) reproduced the failure mode where `lsblk -no FSTYPE`
        # in the classification loop below returned empty on a freshly-attached disk
        # because the kernel had announced the disk (parent block device) but the udev
        # events for its partitions were still in-flight. Live investigation on
        # rhel-diag-145945 rescue VM confirmed that a fresh detach+reattach can leave
        # partition device nodes populated but partition FSTYPE metadata (from blkid
        # scan triggered by udev) unpropagated for tens of seconds. `partprobe` forces
        # the kernel to re-scan the partition table; `udevadm settle` waits for all
        # pending udev events to complete.
        if command -v partprobe >/dev/null 2>&1; then partprobe "/dev/$d" 2>/dev/null || true; fi
        if command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=15 >/dev/null 2>&1 || true; fi
        parts=$(lsblk -ln -o NAME,TYPE "/dev/$d" 2>/dev/null | awk '$2=="part"{print "/dev/"$1}' || echo "")
        CANDIDATES="$CANDIDATES $parts"
        ATTACHED_DISK="$d"
    done
fi

OS_PARTITION_CANDIDATES=""
LVM_PARTITIONS=""
for part in $CANDIDATES; do
    fstype=$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1 || echo "")
    case "$fstype" in
        ext2|ext3|ext4|xfs)
            OS_PARTITION_CANDIDATES="$OS_PARTITION_CANDIDATES $part"
            ;;
        btrfs)
            Log-Warning "$part is btrfs. btrfs subvolume layouts are UNSUPPORTED in this release."
            FAILURE_REASON="btrfs-unsupported"
            ;;
        LVM2_member)
            Log-Info "$part is an LVM physical volume; will activate the VG and enumerate its logical volumes"
            LVM_PARTITIONS="$LVM_PARTITIONS $part"
            ;;
        crypto_LUKS)
            Log-Warning "$part is LUKS-encrypted (ADE). Encrypted disks are UNSUPPORTED in this release."
            FAILURE_REASON="luks-unsupported"
            ;;
        *) ;;
    esac
done

# If we found any LVM PVs on the attached disk, activate them and enumerate ext4/xfs LVs.
# Runs BEFORE the classification-mount loop so LV device paths become candidates alongside
# plain partitions. Diagnostic logging happens inside this block (not inside the helper).
#
# v2.1.4 (Fix E): direct call (NOT command substitution). The helper populates the parent-shell
# `LVM_ENUMERATED_LVS` array in-place; we iterate that array here instead of parsing captured
# stdout. This preserves Fix B's `ACTIVATED_SOURCE_VGS` appends (which were lost in the v2.1.3
# subshell), so evidence JSON reports the true set of activated VGs on the first run.
if [ -n "$LVM_PARTITIONS" ]; then
    Log-Info "Activating LVM PVs on the attached disk and enumerating LVs..."
    activate_lvm_pvs_and_enumerate_lvs "$LVM_PARTITIONS" 2>/dev/null || true
    if [ "${#LVM_ENUMERATED_LVS[@]}" -gt 0 ]; then
        for lv in "${LVM_ENUMERATED_LVS[@]}"; do
            [ -z "$lv" ] && continue
            Log-Info "  LV candidate: $lv"
            OS_PARTITION_CANDIDATES="$OS_PARTITION_CANDIDATES $lv"
        done
    else
        Log-Warning "LVM PVs were found but no ext4/xfs LVs were enumerated (missing tools or empty VGs)."
        FAILURE_REASON="lvm-no-supported-lvs-found"
    fi
fi

for part in $OS_PARTITION_CANDIDATES; do
    if try_mount_ro_with_nouuid_retry "$part" "$MOUNT_POINT" "ro"; then
        # v2.1.2 (PBI-E v3): check fstab presence FIRST. On UsrMove distros (RHEL 8+, Fedora
        # 32+, AlmaLinux 9, Rocky 9, ...) `/etc/os-release` is a symlink into
        # `/usr/lib/os-release`. When `/usr` lives on a separate LV (RHEL 9 default), the
        # symlink target does not exist against the standalone rootlv, and the classic
        # `[ -f "$MOUNT_POINT/etc/os-release" ]` check returns FALSE. We must mount `/usr`
        # from fstab BEFORE checking os-release.
        if [ -f "$MOUNT_POINT/etc/fstab" ]; then
            # Pre-compute the candidate's disk so `resolve_and_mount_aux`'s
            # "$devDisk" != "$ATTACHED_DISK" safety guard has something to compare against.
            # ATTACHED_DISK is only committed AFTER the successful classification below, so
            # we set it provisionally here and revert on classification failure.
            candidateDisk="${LV_TO_DISK_MAP[$part]:-}"
            if [ -z "$candidateDisk" ]; then
                # v2.1.3: same LV-safe spelling as `resolve_and_mount_aux` — the map-miss
                # fallback used to run `lsblk -no PKNAME` which returned empty on any LV
                # form. Defense-in-depth: if `activate_lvm_pvs_and_enumerate_lvs` ever
                # fails to populate the map for an LV (tool/race), this fallback still
                # resolves correctly. Regression-safe on plain partitions.
                candidateDisk=$(lsblk -snlo NAME "$part" 2>/dev/null | tail -n1 || echo "")
            fi
            saved_attached_disk="$ATTACHED_DISK"
            if [ -n "$candidateDisk" ]; then ATTACHED_DISK="$candidateDisk"; fi

            # v2.1.4 (Fix D): unified aux-mount loop over [usr, var, tmp]. `/usr` remains the
            # UsrMove-fixup for RHEL/AlmaLinux `/etc/os-release` symlink resolution; `/var`
            # and `/tmp` are needed so a subsequent chroot `dracut` can `realpath /var/tmp`
            # (which would otherwise return `Invalid tmpdir '/var/tmp'` and abort). Distros
            # without separate `/var` / `/tmp` (Ubuntu, Debian) get no-op behavior because
            # `resolve_and_mount_aux` returns 0 for a not-declared fstab entry (only sets
            # `RESOLVED_AUX_DEV` on successful mount). Order [usr, var, tmp] matches the
            # dependency shape: `/usr` first (needed for os-release check), then `/var` and
            # `/tmp` for downstream chroot dracut.
            for aux in usr var tmp; do
                SEPARATE_AUX_MOUNTED[$aux]="false"
                SEPARATE_AUX_DEVICE[$aux]=""
                if resolve_and_mount_aux "$aux" && [ -n "$RESOLVED_AUX_DEV" ]; then
                    SEPARATE_AUX_MOUNTED[$aux]="true"
                    SEPARATE_AUX_DEVICE[$aux]="$RESOLVED_AUX_DEV"
                fi
            done
            # Legacy aliases mirror the "usr" entry for backward-compat with evidence JSON
            # consumers that read separateUsrMounted / separateUsrDevice directly.
            SEPARATE_USR_MOUNTED="${SEPARATE_AUX_MOUNTED[usr]}"
            SEPARATE_USR_DEVICE="${SEPARATE_AUX_DEVICE[usr]}"

            if [ -f "$MOUNT_POINT/etc/os-release" ]; then
                OS_PARTITION="$part"
                # v2.1.3 — LV-safe disk derivation via inverse-tree list. See v2.1.3 header
                # notes: `lsblk -no PKNAME` returns EMPTY on DM/LV forms; the -snlo spelling
                # walks target -> parents -> disk uniformly for plain partitions AND LVs.
                # `LV_TO_DISK_MAP` (populated by activate_lvm_pvs_and_enumerate_lvs) is still
                # consulted first so the fast path skips the lsblk call when the map is hot.
                partDisk="${LV_TO_DISK_MAP[$part]:-}"
                if [ -z "$partDisk" ]; then
                    partDisk=$(lsblk -snlo NAME "$part" 2>/dev/null | tail -n1 || echo "")
                fi
                if [ -n "$partDisk" ]; then ATTACHED_DISK="$partDisk"; fi
                Log-Output "Found attached Linux root filesystem on $part (mounted read-only for classification)"
                # v2.1.4 (Fix D): log every aux mount the classifier established, not just /usr.
                # Legacy aliases already synced above via SEPARATE_USR_* = SEPARATE_AUX_*[usr].
                for aux in usr var tmp; do
                    if [ "${SEPARATE_AUX_MOUNTED[$aux]}" = "true" ]; then
                        Log-Info "Mounted separate /$aux LV (${SEPARATE_AUX_DEVICE[$aux]}) under classification root (fstab-declared)"
                    fi
                done
                break
            fi

            # os-release still missing after optional aux mounts — unmount ALL aux (if we
            # mounted them) so the next candidate's classification starts clean, then fall
            # through to unmount the root candidate. v2.1.4 (Fix D): leaf-first reverse order.
            for aux in tmp var usr; do
                if [ "${SEPARATE_AUX_MOUNTED[$aux]}" = "true" ] && mountpoint -q "$MOUNT_POINT/$aux" 2>/dev/null; then
                    umount "$MOUNT_POINT/$aux" 2>/dev/null || umount -l "$MOUNT_POINT/$aux" 2>/dev/null || true
                    SEPARATE_AUX_MOUNTED[$aux]="false"
                    SEPARATE_AUX_DEVICE[$aux]=""
                fi
            done
            SEPARATE_USR_MOUNTED="false"
            SEPARATE_USR_DEVICE=""
            ATTACHED_DISK="$saved_attached_disk"
        fi
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
done

if [ -z "$OS_PARTITION" ]; then
    if [ -z "$FAILURE_REASON" ]; then FAILURE_REASON="no-attached-root-filesystem"; fi
    Log-Error "No attached Linux root filesystem could be classified as supported. Reason: $FAILURE_REASON"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

# ----------------------------------------------------------------------------------------------------
# Classify distro family
# ----------------------------------------------------------------------------------------------------
DISTRO_ID=$(grep -E '^ID=' "$MOUNT_POINT/etc/os-release" | head -n1 | cut -d= -f2 | tr -d '"' || echo "")
DISTRO_VER=$(grep -E '^VERSION_ID=' "$MOUNT_POINT/etc/os-release" | head -n1 | cut -d= -f2 | tr -d '"' || echo "")
DISTRO_ID_LIKE=$(grep -E '^ID_LIKE=' "$MOUNT_POINT/etc/os-release" | head -n1 | cut -d= -f2 | tr -d '"' || echo "")

case "$DISTRO_ID" in
    rhel|centos|rocky|almalinux|fedora|ol|mariner|azurelinux) INITRAMFS_TOOL="dracut" ;;
    sles|opensuse|opensuse-leap|opensuse-tumbleweed)          INITRAMFS_TOOL="dracut" ;;
    ubuntu|debian)                                             INITRAMFS_TOOL="initramfs-tools" ;;
    *)
        case " $DISTRO_ID_LIKE " in
            *rhel*|*fedora*|*centos*|*suse*)  INITRAMFS_TOOL="dracut" ;;
            *debian*)                          INITRAMFS_TOOL="initramfs-tools" ;;
            *)
                Log-Error "Distro '$DISTRO_ID' (ID_LIKE='$DISTRO_ID_LIKE') is not in the supported set."
                FAILURE_REASON="distro-unsupported"
                emit_evidence "Aborted" "$FAILURE_REASON" ""
                exit $STATUS_ERROR
                ;;
        esac
        ;;
esac
Log-Output "Attached OS: $DISTRO_ID $DISTRO_VER (initramfs tool: $INITRAMFS_TOOL)"


# Call as a statement (not command substitution) so Log-* output is preserved.
if resolve_and_mount_aux "boot"; then
    BOOT_PARTITION="$RESOLVED_AUX_DEV"
fi
if resolve_and_mount_aux "boot/efi"; then
    BOOT_EFI_PARTITION="$RESOLVED_AUX_DEV"
fi

# ----------------------------------------------------------------------------------------------------
# Inspect current state
# ----------------------------------------------------------------------------------------------------
if [ "$INITRAMFS_TOOL" = "dracut" ]; then
    DROPIN_PATH="etc/dracut.conf.d/99-azure-nvme.conf"
    DROPIN_CONTENT='force_drivers+=" nvme nvme_core "'
    DROPIN_MODE="write"
else
    DROPIN_PATH="etc/initramfs-tools/modules"
    DROPIN_CONTENT=""
    DROPIN_MODE="append"
fi

DROPIN_PRESENT="false"
DROPIN_MATCHES="false"
if [ "$DROPIN_MODE" = "write" ]; then
    if [ -f "$MOUNT_POINT/$DROPIN_PATH" ]; then
        DROPIN_PRESENT="true"
        if grep -Fxq "$DROPIN_CONTENT" "$MOUNT_POINT/$DROPIN_PATH" 2>/dev/null; then
            DROPIN_MATCHES="true"
        fi
    fi
else
    if [ -f "$MOUNT_POINT/$DROPIN_PATH" ]; then
        DROPIN_PRESENT="true"
        has_nvme=$(grep -Ec '^[[:space:]]*nvme([[:space:]]|$)' "$MOUNT_POINT/$DROPIN_PATH" 2>/dev/null || echo 0)
        has_core=$(grep -Ec '^[[:space:]]*nvme_core([[:space:]]|$)' "$MOUNT_POINT/$DROPIN_PATH" 2>/dev/null || echo 0)
        if [ "$has_nvme" -ge 1 ] && [ "$has_core" -ge 1 ]; then
            DROPIN_MATCHES="true"
        fi
    fi
fi

while IFS= read -r img; do
    [ -z "$img" ] && continue
    INITRAMFS_IMAGES+=("$img")
done < <(ls -1 "$MOUNT_POINT"/boot/init* 2>/dev/null | grep -Ev '\.old$|\.bak$' || true)

if [ "${#INITRAMFS_IMAGES[@]}" -eq 0 ]; then
    Log-Error "No initramfs images found under $MOUNT_POINT/boot. If /boot is a separate partition, verify /etc/fstab declares it correctly."
    FAILURE_REASON="no-initramfs-images-found"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

ALL_PRIMARY_IMAGES_OK="true"
HAVE_ANY_PRIMARY="false"
for img in "${INITRAMFS_IMAGES[@]}"; do
    methodFile=$(mktemp)
    if verify_initramfs_has_nvme "$img" "$methodFile"; then
        IMAGE_HAS_NVME+=("true")
    else
        IMAGE_HAS_NVME+=("false")
    fi
    IMAGE_VERIFY_METHODS+=("$(cat "$methodFile")")
    rm -f "$methodFile" 2>/dev/null || true

    skipReason=$(classify_non_primary_boot "$img")
    IMAGE_SKIP_REASON+=("$skipReason")
    if [ -z "$skipReason" ]; then
        HAVE_ANY_PRIMARY="true"
        if [ "${IMAGE_HAS_NVME[-1]}" != "true" ]; then
            ALL_PRIMARY_IMAGES_OK="false"
        fi
        Log-Info "  $img -> PRIMARY, hasNvme=${IMAGE_HAS_NVME[-1]} (method: ${IMAGE_VERIFY_METHODS[-1]})"
    else
        Log-Info "  $img -> SKIPPED ($skipReason)"
    fi
done

if [ "$HAVE_ANY_PRIMARY" != "true" ]; then
    Log-Error "No PRIMARY-boot initramfs images (non-rescue, non-kdump) were found."
    FAILURE_REASON="no-primary-initramfs-images-found"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

Log-Output "Current state: dropin_present=$DROPIN_PRESENT dropin_matches=$DROPIN_MATCHES all_primary_images_have_nvme=$ALL_PRIMARY_IMAGES_OK"

# ----------------------------------------------------------------------------------------------------
# Report mode short-circuit
# ----------------------------------------------------------------------------------------------------
if [ "$MODE" = "Report" ]; then
    if [ "$DROPIN_MATCHES" = "true" ] && [ "$ALL_PRIMARY_IMAGES_OK" = "true" ]; then
        OUTCOME="NoChangeNeeded"
        Log-Output "NoChangeNeeded: drop-in in place and every primary-boot initramfs image already contains nvme+nvme_core."
    else
        OUTCOME="Report"
        Log-Output "Report only: Repair mode would install '$DROPIN_PATH' and rebuild primary-boot initramfs images. No changes were made."
    fi
    emit_evidence "$OUTCOME" "" ""
    STATUS=$STATUS_SUCCESS
    exit $STATUS
fi

# ----------------------------------------------------------------------------------------------------
# Rollback mode
# ----------------------------------------------------------------------------------------------------
if [ "$MODE" = "Rollback" ]; then
    if [ -z "$BACKUP_DIR_INPUT" ] || [ ! -d "$BACKUP_DIR_INPUT" ]; then
        Log-Error "Rollback requires a valid BackupDir. Not found: '$BACKUP_DIR_INPUT'."
        FAILURE_REASON="rollback-backup-dir-invalid"
        emit_evidence "Aborted" "$FAILURE_REASON" ""
        exit $STATUS_ERROR
    fi
    MANIFEST="$BACKUP_DIR_INPUT/backup-manifest.txt"
    if [ ! -f "$MANIFEST" ]; then
        Log-Error "BackupDir '$BACKUP_DIR_INPUT' has no backup-manifest.txt."
        FAILURE_REASON="rollback-manifest-missing"
        emit_evidence "Aborted" "$FAILURE_REASON" ""
        exit $STATUS_ERROR
    fi

    # Empty-manifest guard: refuse to declare a vacuous success.
    manifest_line_count=$(grep -cve '^[[:space:]]*$' "$MANIFEST" 2>/dev/null || echo 0)
    if [ "$manifest_line_count" -lt 1 ]; then
        Log-Error "backup-manifest.txt is empty. Refusing to declare a vacuous rollback."
        FAILURE_REASON="rollback-manifest-empty"
        emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"
        exit $STATUS_ERROR
    fi

    # Per-filesystem free-space pre-flight: split manifest sizes by target filesystem.
    boot_required_kb=0
    root_required_kb=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        relPath=$(echo "$line" | awk '{print $1}')
        src="$BACKUP_DIR_INPUT/files/$relPath"
        [ -f "$src" ] || continue
        kb=$(du -k "$src" 2>/dev/null | awk '{print $1}')
        [ -z "$kb" ] && kb=0
        if [[ "$relPath" == boot/* ]] || [[ "$relPath" == boot ]]; then
            boot_required_kb=$((boot_required_kb + kb))
        else
            root_required_kb=$((root_required_kb + kb))
        fi
    done < "$MANIFEST"

    # RW re-mount for root.
    if ! mount -o remount,rw "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
        if ! try_mount_rw_with_nouuid_retry "$OS_PARTITION" "$MOUNT_POINT"; then
            Log-Error "Could not re-mount $OS_PARTITION read-write for rollback."
            FAILURE_REASON="rollback-mount-rw-failed"
            emit_evidence "Aborted" "$FAILURE_REASON" ""
            exit $STATUS_ERROR
        fi
    fi
    if ! findmnt -no OPTIONS "$MOUNT_POINT" 2>/dev/null | grep -Eq '(^|,)rw(,|$)'; then
        Log-Error "$MOUNT_POINT is not actually writable. Aborting rollback."
        FAILURE_REASON="rollback-filesystem-forced-read-only"
        emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"
        exit $STATUS_ERROR
    fi
    if [ -n "$BOOT_PARTITION" ] && mountpoint -q "$MOUNT_POINT/boot"; then
        if ! mount -o remount,rw "$MOUNT_POINT/boot" 2>/dev/null; then
            umount "$MOUNT_POINT/boot" 2>/dev/null || true
            if ! try_mount_rw_with_nouuid_retry "$BOOT_PARTITION" "$MOUNT_POINT/boot"; then
                Log-Error "Could not re-mount separate /boot ($BOOT_PARTITION) RW for rollback."
                FAILURE_REASON="rollback-boot-mount-rw-failed"
                emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"
                exit $STATUS_ERROR
            fi
        fi
    fi

    # v2.1.4 (Fix D): symmetric RW-remount for /var and /tmp in Rollback mode. Rollback
    # itself only writes into $MOUNT_POINT (root) and $MOUNT_POINT/boot, but the rollback
    # path also re-runs a chroot dracut in some downstream scenarios; keep the environment
    # ready. Non-fatal if the aux mounts weren't established (e.g., re-invoked Rollback
    # against an already-classified disk that did not re-mount aux).
    for aux in var tmp; do
        if [ "${SEPARATE_AUX_MOUNTED[$aux]:-false}" = "true" ] && mountpoint -q "$MOUNT_POINT/$aux" 2>/dev/null; then
            if ! mount -o remount,rw "$MOUNT_POINT/$aux" 2>/dev/null; then
                umount "$MOUNT_POINT/$aux" 2>/dev/null || true
                if ! try_mount_rw_with_nouuid_retry "${SEPARATE_AUX_DEVICE[$aux]}" "$MOUNT_POINT/$aux"; then
                    Log-Error "Could not re-mount separate /$aux (${SEPARATE_AUX_DEVICE[$aux]}) RW for rollback."
                    FAILURE_REASON="rollback-${aux}-mount-rw-failed"
                    emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"
                    exit $STATUS_ERROR
                fi
            fi
        fi
    done

    root_free_kb=$(df -Pk "$MOUNT_POINT" | awk 'NR==2 {print $4}')
    boot_free_kb=$(df -Pk "$MOUNT_POINT/boot" | awk 'NR==2 {print $4}')
    if [ "${root_free_kb:-0}" -lt "$root_required_kb" ] || [ "${boot_free_kb:-0}" -lt "$boot_required_kb" ]; then
        Log-Error "Insufficient free space for Rollback. root free=${root_free_kb}KB required=${root_required_kb}KB; boot free=${boot_free_kb}KB required=${boot_required_kb}KB."
        FAILURE_REASON="rollback-insufficient-disk-space"
        emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"
        exit $STATUS_ERROR
    fi

    RESTORE_COUNT=0
    RESTORE_OK="true"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        relPath=$(echo "$line" | awk '{print $1}')
        expectedSha=$(echo "$line" | awk '{print $2}')
        src="$BACKUP_DIR_INPUT/files/$relPath"
        dst="$MOUNT_POINT/$relPath"
        if [ ! -f "$src" ]; then
            Log-Error "Backup file '$src' missing; cannot restore '$relPath'."
            RESTORE_OK="false"
            continue
        fi
        mkdir -p "$(dirname "$dst")" 2>/dev/null || true
        cp -a "$src" "$dst" || RESTORE_OK="false"
        actualSha=$(sha256sum "$dst" 2>/dev/null | awk '{print $1}')
        if [ "$actualSha" != "$expectedSha" ]; then
            Log-Error "Post-restore hash mismatch for '$relPath': expected $expectedSha, got $actualSha."
            RESTORE_OK="false"
        fi
        RESTORE_COUNT=$((RESTORE_COUNT + 1))
    done < "$MANIFEST"

    if [ -f "$BACKUP_DIR_INPUT/added-files.txt" ]; then
        while IFS= read -r addedRel; do
            [ -z "$addedRel" ] && continue
            rm -f "$MOUNT_POINT/$addedRel" 2>/dev/null || true
        done < "$BACKUP_DIR_INPUT/added-files.txt"
    fi

    if [ "$RESTORE_OK" != "true" ] || [ "$RESTORE_COUNT" -eq 0 ]; then
        FAILURE_REASON="rollback-restore-failed"
        [ "$RESTORE_COUNT" -eq 0 ] && FAILURE_REASON="rollback-no-files-restored"
        emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"
        exit $STATUS_ERROR
    fi

    OUTCOME="RolledBack"
    Log-Output "VERIFIED: Rollback restored $RESTORE_COUNT file(s) recorded in '$MANIFEST'."
    emit_evidence "$OUTCOME" "" "$BACKUP_DIR_INPUT"
    STATUS=$STATUS_SUCCESS
    exit $STATUS
fi

# ----------------------------------------------------------------------------------------------------
# Repair mode
# ----------------------------------------------------------------------------------------------------
if [ "$DROPIN_MATCHES" = "true" ] && [ "$ALL_PRIMARY_IMAGES_OK" = "true" ]; then
    OUTCOME="NoChangeNeeded"
    Log-Output "NoChangeNeeded: no repair required; drop-in and every primary-boot image are already correct."
    emit_evidence "$OUTCOME" "" ""
    STATUS=$STATUS_SUCCESS
    exit $STATUS
fi

# Free-space pre-flight.
total_images_kb=0
max_image_kb=0
for img in "${INITRAMFS_IMAGES[@]}"; do
    kb=$(du -k "$img" 2>/dev/null | awk '{print $1}')
    if [ -n "$kb" ]; then
        total_images_kb=$((total_images_kb + kb))
        [ "$kb" -gt "$max_image_kb" ] && max_image_kb=$kb
    fi
done
tmp_free_kb=$(df -Pk /tmp | awk 'NR==2 {print $4}')
boot_free_kb=$(df -Pk "$MOUNT_POINT/boot" | awk 'NR==2 {print $4}')
required_tmp_kb=$((total_images_kb + 128*1024))
required_boot_kb=$((max_image_kb + 64*1024))
if [ "${tmp_free_kb:-0}" -lt "$required_tmp_kb" ] || [ "${boot_free_kb:-0}" -lt "$required_boot_kb" ]; then
    Log-Error "Insufficient free space. /tmp free=${tmp_free_kb}KB required=${required_tmp_kb}KB; /boot free=${boot_free_kb}KB required=${required_boot_kb}KB."
    FAILURE_REASON="insufficient-disk-space"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

if ! mount -o remount,rw "$MOUNT_POINT" 2>/dev/null; then
    umount "$MOUNT_POINT" 2>/dev/null || true
    if ! try_mount_rw_with_nouuid_retry "$OS_PARTITION" "$MOUNT_POINT"; then
        Log-Error "Could not re-mount $OS_PARTITION read-write for repair."
        FAILURE_REASON="mount-rw-failed"
        emit_evidence "Aborted" "$FAILURE_REASON" ""
        exit $STATUS_ERROR
    fi
fi
if ! findmnt -no OPTIONS "$MOUNT_POINT" 2>/dev/null | grep -Eq '(^|,)rw(,|$)'; then
    Log-Error "$MOUNT_POINT is not actually writable (kernel forced read-only despite mount success)."
    FAILURE_REASON="filesystem-forced-read-only"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi
if [ -n "$BOOT_PARTITION" ] && mountpoint -q "$MOUNT_POINT/boot"; then
    if ! mount -o remount,rw "$MOUNT_POINT/boot" 2>/dev/null; then
        umount "$MOUNT_POINT/boot" 2>/dev/null || true
        if ! try_mount_rw_with_nouuid_retry "$BOOT_PARTITION" "$MOUNT_POINT/boot"; then
            Log-Error "Could not re-mount separate /boot ($BOOT_PARTITION) RW for repair."
            FAILURE_REASON="boot-mount-rw-failed"
            emit_evidence "Aborted" "$FAILURE_REASON" ""
            exit $STATUS_ERROR
        fi
    fi
    if ! findmnt -no OPTIONS "$MOUNT_POINT/boot" 2>/dev/null | grep -Eq '(^|,)rw(,|$)'; then
        Log-Error "$MOUNT_POINT/boot is not actually writable."
        FAILURE_REASON="boot-filesystem-forced-read-only"
        emit_evidence "Aborted" "$FAILURE_REASON" ""
        exit $STATUS_ERROR
    fi
fi

# v2.1.4 (Fix D): RW-remount for `/var` and `/tmp` if the classifier mounted them RO under
# the candidate root. Required so subsequent chroot dracut can write its tmp files to
# `/var/tmp/dracut.XXXX` and helper mktemp calls to `/tmp`. Symmetric to the `/boot` block
# above. `/usr` intentionally stays RO — dracut only reads it (drivers, modules.d), never
# writes; keeping it RO defends against accidental modification during rebuild.
for aux in var tmp; do
    if [ "${SEPARATE_AUX_MOUNTED[$aux]}" = "true" ] && mountpoint -q "$MOUNT_POINT/$aux" 2>/dev/null; then
        if ! mount -o remount,rw "$MOUNT_POINT/$aux" 2>/dev/null; then
            umount "$MOUNT_POINT/$aux" 2>/dev/null || true
            if ! try_mount_rw_with_nouuid_retry "${SEPARATE_AUX_DEVICE[$aux]}" "$MOUNT_POINT/$aux"; then
                Log-Error "Could not re-mount separate /$aux (${SEPARATE_AUX_DEVICE[$aux]}) RW for repair."
                FAILURE_REASON="${aux}-mount-rw-failed"
                emit_evidence "Aborted" "$FAILURE_REASON" ""
                exit $STATUS_ERROR
            fi
        fi
        if ! findmnt -no OPTIONS "$MOUNT_POINT/$aux" 2>/dev/null | grep -Eq '(^|,)rw(,|$)'; then
            Log-Error "$MOUNT_POINT/$aux is not actually writable (kernel forced read-only)."
            FAILURE_REASON="${aux}-filesystem-forced-read-only"
            emit_evidence "Aborted" "$FAILURE_REASON" ""
            exit $STATUS_ERROR
        fi
    fi
done

BACKUP_ROOT="$EVIDENCE_DIR/files"
MANIFEST="$EVIDENCE_DIR/backup-manifest.txt"
ADDED_FILES="$EVIDENCE_DIR/added-files.txt"
mkdir -p "$BACKUP_ROOT" || {
    Log-Error "Could not create backup root '$BACKUP_ROOT'."
    FAILURE_REASON="backup-root-mkdir-failed"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
}
: > "$MANIFEST"
: > "$ADDED_FILES"

backup_or_note_missing() {
    local relPath="$1"
    local src="$MOUNT_POINT/$relPath"
    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$BACKUP_ROOT/$relPath")" 2>/dev/null || true
        cp -a "$src" "$BACKUP_ROOT/$relPath"
        local sha
        sha=$(sha256sum "$src" | awk '{print $1}')
        printf '%s %s\n' "$relPath" "$sha" >> "$MANIFEST"
    else
        printf '%s\n' "$relPath" >> "$ADDED_FILES"
    fi
}

backup_or_note_missing "$DROPIN_PATH"
for img in "${INITRAMFS_IMAGES[@]}"; do
    relImg=${img#"$MOUNT_POINT/"}
    backup_or_note_missing "$relImg"
done

if [ "$DROPIN_MODE" = "write" ]; then
    mkdir -p "$MOUNT_POINT/$(dirname "$DROPIN_PATH")" 2>/dev/null || true
    if ! printf '%s\n' "$DROPIN_CONTENT" > "$MOUNT_POINT/$DROPIN_PATH"; then
        Log-Error "Failed to write drop-in '$MOUNT_POINT/$DROPIN_PATH'."
        FAILURE_REASON="dropin-write-failed"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    fi
else
    mkdir -p "$MOUNT_POINT/$(dirname "$DROPIN_PATH")" 2>/dev/null || true
    touch "$MOUNT_POINT/$DROPIN_PATH" || {
        Log-Error "Failed to create '$MOUNT_POINT/$DROPIN_PATH'."
        FAILURE_REASON="dropin-write-failed"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    }
    if ! grep -qE '^[[:space:]]*nvme([[:space:]]|$)' "$MOUNT_POINT/$DROPIN_PATH"; then
        printf 'nvme\n' >> "$MOUNT_POINT/$DROPIN_PATH" || {
            Log-Error "Failed to append 'nvme' to '$MOUNT_POINT/$DROPIN_PATH'."
            FAILURE_REASON="dropin-write-failed"
            emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
            exit $STATUS_ERROR
        }
    fi
    if ! grep -qE '^[[:space:]]*nvme_core([[:space:]]|$)' "$MOUNT_POINT/$DROPIN_PATH"; then
        printf 'nvme_core\n' >> "$MOUNT_POINT/$DROPIN_PATH" || {
            Log-Error "Failed to append 'nvme_core' to '$MOUNT_POINT/$DROPIN_PATH'."
            FAILURE_REASON="dropin-write-failed"
            emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
            exit $STATUS_ERROR
        }
    fi
fi
Log-Output "Wrote / updated drop-in: $DROPIN_PATH"

for dir in dev proc sys run; do
    if [ ! -d "$MOUNT_POINT/$dir" ]; then
        mkdir -p "$MOUNT_POINT/$dir" || {
            Log-Error "Missing '$MOUNT_POINT/$dir' and could not create it."
            FAILURE_REASON="chroot-mkdir-failed:$dir"
            emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
            exit $STATUS_ERROR
        }
    fi
done

for spec in "dev|rbind|/dev" "sys|rbind|/sys" "run|bind|/run"; do
    dir="${spec%%|*}"
    rest="${spec#*|}"
    kind="${rest%%|*}"
    src="${rest##*|}"
    if ! mount --"$kind" "$src" "$MOUNT_POINT/$dir"; then
        Log-Error "Failed to $kind $src into chroot."
        FAILURE_REASON="chroot-bind-mount-failed:$dir"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    fi
    if ! mount --make-rslave "$MOUNT_POINT/$dir"; then
        Log-Error "Failed to mark $MOUNT_POINT/$dir as rslave."
        FAILURE_REASON="chroot-make-rslave-failed:$dir"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    fi
    if ! mountpoint -q "$MOUNT_POINT/$dir"; then
        Log-Error "$MOUNT_POINT/$dir is not a mountpoint after $kind."
        FAILURE_REASON="chroot-mountpoint-check-failed:$dir"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    fi
done
if ! mount -t proc proc "$MOUNT_POINT/proc"; then
    Log-Error "Failed to mount fresh procfs at $MOUNT_POINT/proc."
    FAILURE_REASON="chroot-bind-mount-failed:proc"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
    exit $STATUS_ERROR
fi
if ! mountpoint -q "$MOUNT_POINT/proc"; then
    Log-Error "$MOUNT_POINT/proc is not a mountpoint after fresh proc mount."
    FAILURE_REASON="chroot-mountpoint-check-failed:proc"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
    exit $STATUS_ERROR
fi

if [ -d /dev/pts ] && [ ! -d "$MOUNT_POINT/dev/pts" ]; then
    mkdir -p "$MOUNT_POINT/dev/pts" 2>/dev/null || true
fi
if [ -d "$MOUNT_POINT/dev/pts" ] && ! mountpoint -q "$MOUNT_POINT/dev/pts" 2>/dev/null; then
    if mount --bind /dev/pts "$MOUNT_POINT/dev/pts"; then
        mount --make-slave "$MOUNT_POINT/dev/pts" 2>/dev/null || true
    else
        Log-Warning "Failed to bind /dev/pts; continuing (some tools may lack pty)."
    fi
fi

CHROOT_LOG="$EVIDENCE_DIR/chroot.log"

if [ "$INITRAMFS_TOOL" = "dracut" ]; then
    if ! chroot "$MOUNT_POINT" /bin/bash -c 'command -v dracut >/dev/null 2>&1'; then
        Log-Error "dracut is not installed inside the attached guest. Cannot rebuild initramfs offline."
        FAILURE_REASON="dracut-not-installed-in-guest"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    fi
else
    if ! chroot "$MOUNT_POINT" /bin/bash -c 'command -v update-initramfs >/dev/null 2>&1'; then
        Log-Error "update-initramfs is not installed inside the attached guest. Cannot rebuild initramfs offline."
        FAILURE_REASON="update-initramfs-not-installed-in-guest"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    fi
fi

CHROOT_KVERS=$(chroot "$MOUNT_POINT" /bin/bash -c 'ls -1 /lib/modules 2>/dev/null | tr "\n" " "' || echo "")
if [ -z "$(printf '%s' "$CHROOT_KVERS" | tr -d '[:space:]')" ]; then
    Log-Error "No kernel modules tree found under /lib/modules inside the attached guest."
    FAILURE_REASON="no-kernel-modules-found-in-chroot"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
    exit $STATUS_ERROR
fi
Log-Info "Kernel versions available under /lib/modules in chroot: $CHROOT_KVERS"

Log-Output "Rebuilding primary-boot initramfs images inside chroot ($INITRAMFS_TOOL)..."

REBUILD_OK="true"
if [ "$INITRAMFS_TOOL" = "dracut" ]; then
    i=0
    for img in "${INITRAMFS_IMAGES[@]}"; do
        skipReason="${IMAGE_SKIP_REASON[$i]}"
        i=$((i + 1))
        if [ -n "$skipReason" ]; then
            Log-Info "  SKIP $img ($skipReason)"
            continue
        fi
        relImg=${img#"$MOUNT_POINT"}
        kver=$(extract_kver_from_image "$img")
        if [ -z "$kver" ]; then
            Log-Warning "Could not extract kernel version from '$img' — skipping."
            continue
        fi
        if ! chroot "$MOUNT_POINT" /bin/bash -c 'test -d "/lib/modules/$1"' -- "$kver"; then
            Log-Warning "/lib/modules/$kver missing in chroot — skipping rebuild of $img."
            continue
        fi
        Log-Info "  dracut -f $relImg $kver"
        if ! chroot "$MOUNT_POINT" /bin/bash -c 'dracut -f "$1" "$2"' -- "$relImg" "$kver" >> "$CHROOT_LOG" 2>&1; then
            Log-Error "dracut failed for $img (kver=$kver). See $CHROOT_LOG."
            REBUILD_OK="false"
            break
        fi
    done
else
    if ! chroot "$MOUNT_POINT" /bin/bash -c 'update-initramfs -u -k all' >> "$CHROOT_LOG" 2>&1; then
        Log-Error "update-initramfs failed. See $CHROOT_LOG."
        REBUILD_OK="false"
    fi
fi

if [ "$REBUILD_OK" != "true" ]; then
    FAILURE_REASON="initramfs-rebuild-failed"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
    exit $STATUS_ERROR
fi

declare -a POST_IMAGES=()
while IFS= read -r img; do
    [ -z "$img" ] && continue
    POST_IMAGES+=("$img")
done < <(ls -1 "$MOUNT_POINT"/boot/init* 2>/dev/null | grep -Ev '\.old$|\.bak$' || true)

for postImg in "${POST_IMAGES[@]}"; do
    seen="false"
    for preImg in "${INITRAMFS_IMAGES[@]}"; do
        if [ "$preImg" = "$postImg" ]; then seen="true"; break; fi
    done
    if [ "$seen" = "false" ]; then
        relPost=${postImg#"$MOUNT_POINT/"}
        printf '%s\n' "$relPost" >> "$ADDED_FILES"
        INITRAMFS_IMAGES+=("$postImg")
        IMAGE_HAS_NVME+=("")
        IMAGE_VERIFY_METHODS+=("")
        newSkip=$(classify_non_primary_boot "$postImg")
        IMAGE_SKIP_REASON+=("$newSkip")
    fi
done

VERIFIED_ALL="true"
VERIFY_COUNT=0
i=0
for img in "${INITRAMFS_IMAGES[@]}"; do
    skipReason="${IMAGE_SKIP_REASON[$i]}"
    if [ -n "$skipReason" ]; then
        POST_REBUILD_HAS_NVME+=("")
        POST_REBUILD_METHODS+=("")
        i=$((i + 1))
        continue
    fi
    methodFile=$(mktemp)
    if verify_initramfs_has_nvme "$img" "$methodFile"; then
        Log-Info "  VERIFIED $img (method: $(cat "$methodFile"))"
        POST_REBUILD_HAS_NVME+=("true")
    else
        Log-Error "  MISSING nvme in $img (method: $(cat "$methodFile"))"
        POST_REBUILD_HAS_NVME+=("false")
        VERIFIED_ALL="false"
    fi
    POST_REBUILD_METHODS+=("$(cat "$methodFile")")
    rm -f "$methodFile" 2>/dev/null || true
    VERIFY_COUNT=$((VERIFY_COUNT + 1))
    i=$((i + 1))
done

if [ "$VERIFY_COUNT" -eq 0 ]; then
    Log-Error "Post-rebuild verification set was empty; refusing to declare a vacuous success."
    FAILURE_REASON="no-primary-images-to-verify"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
    exit $STATUS_ERROR
fi

if [ "$VERIFIED_ALL" != "true" ]; then
    Log-Error "Verification failed for at least one primary-boot image. Roll back with: --parameters ++Rollback ++${DEVICE_OVERRIDE:-<device>} ++$EVIDENCE_DIR"
    FAILURE_REASON="post-rebuild-verification-failed"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
    exit $STATUS_ERROR
fi

OUTCOME="Repaired"
Log-Output "VERIFIED: $VERIFY_COUNT primary-boot initramfs image(s) rebuilt and each contains nvme+nvme_core. Rollback dir: $EVIDENCE_DIR"
emit_evidence "$OUTCOME" "" "$EVIDENCE_DIR"
STATUS=$STATUS_SUCCESS
exit $STATUS
