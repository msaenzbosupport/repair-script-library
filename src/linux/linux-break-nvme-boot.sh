#!/bin/bash
########################################################################################################
#
# .SYNOPSIS
#   Fault-injection breaker for the Linux SCSI-to-NVMe repair script: removes the nvme and nvme_core
#   kernel modules from every PRIMARY-boot initramfs image on an offline OS disk, reproducing the
#   post-controller-migration boot failure. v2.1.4
#
#   v2.1.4 changes vs v2.1.3 (paired with the fix script per Gates.md design invariant 15 —
#   chroot dracut aux-mount handling + subshell scope defect for LVM tracking arrays):
#     • **Fix D (chroot dracut needs /var and /tmp mounted)** — v2.1.3 mounts a separate `/usr`
#       under the classification root when fstab declares one (RHEL 9 UsrMove), but not `/var`
#       or `/tmp`. On RHEL 9's default LVM layout `/var` and `/tmp` also live on separate LVs
#       and are empty directories inside the chroot when unmounted. Chroot dracut calls
#       `realpath /var/tmp` to resolve its default tmpdir; that returns
#       `Invalid tmpdir '/var/tmp'` when `/var` is empty and dracut aborts before writing.
#       (Breaker mode does not currently rebuild initramfs images via dracut — it strips
#       modules from existing images — but symmetric behavior is required per invariant 15
#       and the aux-mount pattern is small enough that lockstep parity is trivial.) Extend
#       the classifier's aux-mount pass into a unified loop over `[usr, var, tmp]` driven by
#       fstab-present-and-declared logic. Distros without separate `/var` / `/tmp` (Ubuntu,
#       Debian) get no-op behavior. Symmetric cleanup and evidence-JSON extensions match the
#       fix script byte-for-byte. Evidence JSON gains `separateAuxMounts` object under
#       `guest.lvm`; `separateUsrMounted`/`separateUsrDevice` scalars kept as backward-compat
#       aliases. schemaVersion bumps 1.2 → 1.3.
#     • **Fix E (subshell scope defect in `activate_lvm_pvs_and_enumerate_lvs` invocation)** —
#       v2.0.1+ helper does two things concurrently: emits LV paths on stdout AND appends to
#       three global tracking arrays. The caller invokes it via `lvm_lvs=$(activate_lvm_...)`
#       command substitution — `$(...)` creates a subshell and array appends inside the
#       subshell are LOST when it exits. Fix B's autoactivation-aware VG tracking was defeated
#       by this since v2.1.0. Fix: helper no longer emits LV paths on stdout; callers invoke
#       it as a direct call (not via `$(...)`) and iterate the parent-shell
#       `LVM_ENUMERATED_LVS` global array in-place. See fix script header for the local
#       reproducer and full mechanism analysis.
#     • Combined scope ~68 LOC in this script (matching the fix); byte-for-byte parity with
#       linux-fix-nvme-boot v2.1.4 per Gates.md design invariant 15.
#
#   v2.1.3 changes vs v2.1.2 (paired with the fix script per Gates.md design invariant 15 —
#   LV-safe devDisk derivation + autoactivation-aware VG tracking + bash forward-reference fix):
#     • **Fix C (bash forward reference)** — v2.1.2 added a THIRD call to `resolve_and_mount_aux`
#       inside the classification loop (`"usr"` mount for RHEL 9 UsrMove), placed BEFORE the
#       function's definition further down the file. Bash executes sequentially, so the call
#       raised `resolve_and_mount_aux: command not found` on stderr and the classifier silently
#       fell through with no `separateUsrMounted` evidence. The failure signature was identical
#       to the PKNAME/os-release defect (`no-attached-root-filesystem`), which is why 3 v2.1.2
#       live rounds diagnosed only the surface symptom. v2.1.3 moves the definition to sit
#       alongside the other helpers, well before any call site. See fix script header for
#       full incident report.
#     • `resolve_and_mount_aux` and `activate_lvm_pvs_and_enumerate_lvs` both derived their
#       "which disk hosts this device" answer from `lsblk -no PKNAME <dev> | head -n1`, with a
#       one-level walk-up added in v2.1.2. Live probe on `rhel-diag-145945/rescue` (2026-09-25)
#       confirmed PKNAME returns EMPTY for every LV spelling — `/dev/mapper/rootvg-usrlv`,
#       `/dev/rootvg/usrlv`, `/dev/dm-1` all yield '' — so the safety guard `devDisk ==
#       ATTACHED_DISK` failed and the `/usr` mount was refused, breaking v2.1.2's Option C fix.
#       Root cause: `lsblk -no PKNAME` on a DM logical-volume node reports the mapper's own
#       parent-DM devices, which have no PKNAME. Fix: use `lsblk -snlo NAME "$dev" | tail -n1`
#       — `-s` inverts the tree so we walk from the target DOWN through parents to the disk,
#       `-l` uses list mode so tree-drawing glyphs are stripped, `tail -n1` picks the disk.
#       Live-probe-verified across LV mapper forms, `/dev/vg/lv` forms, `/dev/dm-N` forms, and
#       every plain-partition regression case. Applied at TWO sites; the v2.1.2 walk-up removed.
#     • `activate_lvm_pvs_and_enumerate_lvs`: separated intent from observation — `vgchange -ay
#       --select "vg_uuid=$U" || true`, then `lvs --select "vg_uuid=$U && lv_active=active"` to
#       verify state. VGs auto-activated by systemd's pvscan are now correctly tracked in
#       ACTIVATED_SOURCE_VGS so cleanup deactivates them uniformly. (Prior `vg_attr` grep would
#       never match because vg_attr has no active flag; the flag lives on lv_attr at position 5.)
#     • Scope: 2 sites × Fix A (LV-safe devDisk + LV-safe pvDisk) + 2 map-miss fallbacks
#       in the classification loop (candidateDisk/partDisk, defense against LV_TO_DISK_MAP
#       population failures) + 1 site × Fix B. Schema unchanged at breaker `1.2` — no
#       evidence-shape change.
#     • Scope boundary — Fix A assumes a single-leaf inverse-tree. LV-over-MD-RAID and
#       multi-path layouts produce ≥2 leaf disks. Not in scope for single-disk repair VMs;
#       see fix script header for the full rationale.
#     • Byte-for-byte parity with linux-fix-nvme-boot v2.1.3 per Gates.md design invariant 15.
#
#   v2.1.2 changes vs v2.1.1 (paired with the fix script per Gates.md design invariant 15 —
#     • Classification loop now mounts a separate `/usr` filesystem (if declared in the guest's
#       fstab) UNDER the candidate root before checking for `/etc/os-release`. Phase 5 v3
#       investigation (2026-09-24) proved on preserved RG
#       vmrepair-env-linux-fix-nvme-boot-offline-1-20260925012210 that RHEL 9's Marketplace image
#       uses the modern usr-merge layout: `/etc/os-release -> ../usr/lib/os-release`, and `/usr`
#       lives on a dedicated `rootvg-usrlv` LV per fstab. When the classifier mounts rootlv
#       standalone (no `/usr` underneath), `[ -f "$MOUNT_POINT/etc/os-release" ]` returns FALSE
#       because `-f` follows the symlink and the target does not exist. Every LV then fails
#       classification and the script emits `no-attached-root-filesystem` despite having
#       successfully mounted every LV.
#     • Fix: reuse `resolve_and_mount_aux` to mount a fstab-declared `/usr` filesystem BEFORE the
#       os-release check. If fstab has no separate `/usr` entry, the mount is skipped and the
#       check runs against the standalone rootlv as before. Safety guard refuses if the resolved
#       device is not on the attached disk (defense against stale-UUID drift).
#     • `cleanup()` extended to unmount `/usr` alongside `/boot` and `/boot/efi` on script exit.
#     • Evidence JSON: `guest.lvm` gains `separateUsrMounted` (true|false) and `separateUsrDevice`
#       (device path or empty). schemaVersion bumps 1.1 → 1.2.
#     • Byte-for-byte parity with linux-fix-nvme-boot v2.1.2 per Gates.md design invariant 15.
#
#   v2.1.1 changes vs v2.1.0 (defense-in-depth against udev / partition-scan races, paired with
#   the fix script per Gates.md design invariant 15):
#     • Outer disk-iteration loop now calls `partprobe /dev/$d` + `udevadm settle --timeout=15`
#       BEFORE `lsblk -ln -o NAME,TYPE` per disk. See fix script header for the full incident
#       report from Phase 5 Row 2 (2026-09-24). Also applied to the DEVICE_OVERRIDE branch.
#
#   v2.1.0 changes vs v2.0.0 (minimal, surgical — RHEL 9 LVM discovery fix, paired with the fix
#   script per Gates.md design invariant 15):
#     • vgchange -ay/-an: use `--select "vg_uuid=$vguuid"` instead of `vgchange -ay/-an "$vguuid"`.
#       Verified live on RHEL 9 (2026-09-24): `vgchange -ay "$UUID"` reports
#       `Volume group "$UUID" not found` because vgchange interprets its positional arg as
#       a VG NAME, not a UUID. Symptom: script reported outcome=Aborted,
#       reason=no-attached-root-filesystem on RHEL 9 in Phase 4 Row 2. Fix flips two call sites
#       in `activate_lvm_pvs_and_enumerate_lvs` and `deactivate_source_vgs` to --select syntax.
#
#   v2.0.0 hardens the v2.0.0 LVM+XFS support (from PBI-A P0):
#     • Correct ATTACHED_DISK derivation for LV sources (walk LV → PV partition → disk, not just
#       the LV's single PKNAME level).
#     • Collision-guard uses VG UUIDs, not names, for vgrename/vgchange/lvs `--select`.
#     • Deactivation cleanup verifies via `lvs -o lv_active --select vg_uuid=...` polling and
#       retries up to 3 times with a 1 s sleep, logging any lingering leak to stderr.
#     • Multi-PV VGs de-duplicated so a single VG is not processed once per PV.
#     • Evidence JSON emits `guest.lvm` = `{activatedVgs[], renamedVgs[], enumeratedLvs[]}`.
#     • `udevadm settle` before `vgscan --cache` for defense-in-depth on freshly-attached disks.
#
#   Design mirrors linux-fix-nvme-boot.sh v2.0.0 for lockstep-parity in the pair test cycle
#   (per Gates.md design invariant 15). The LVM helpers, classification-loop patches, cleanup
#   trap hook, and evidence-JSON shape are byte-for-byte identical between the two scripts.
#
# .DESCRIPTION
#   Runs on a repair VM (invoked with --run-on-repair) against the source VM's OS disk attached as a
#   data disk. Report mode is the DEFAULT and makes no configuration changes.
#
#   Break mode:
#     1. Discovers the attached OS root partition and any separate /boot partition, exactly as the
#        paired repair script `linux-fix-nvme-boot` does.
#     2. Mounts / read-only for classification; refuses LUKS/LVM/Btrfs/unknown-distro.
#     3. Re-mounts / read-write.
#     4. Removes any repair-side drop-in (`etc/dracut.conf.d/99-azure-nvme.conf` or the `nvme`/
#        `nvme_core` module lines in `etc/initramfs-tools/modules`) and installs a break-side
#        drop-in (`etc/dracut.conf.d/98-azure-nvme-break.conf` with `omit_drivers+=" nvme nvme_core "`)
#        or, on initramfs-tools, sets `MODULES=list` in a break drop-in (`etc/initramfs-tools/conf.d/
#        90-azure-nvme-break.conf`).
#     5. Backs up every existing PRIMARY-boot initramfs image plus the drop-in targets into a
#        timestamped evidence directory (`/tmp/nvme-break-<ts>-<rand>`).
#     6. Chroots into the guest and rebuilds every primary-boot image IN PLACE.
#     7. Post-rebuild, if any image still contains `nvme.ko` or `nvme_core.ko`, unpacks the image
#        (cpio + optional gzip/xz/zstd decompress), removes matching files, and repacks it. This
#        universal-strip fallback covers initramfs-tools builds where MODULES policy did not fully
#        exclude the modules.
#     8. Verifies every primary-boot image is now MISSING both `nvme.ko` and `nvme_core.ko`; aborts
#        with `post-break-verification-failed` if not.
#
#   Rollback mode:
#     Byte-for-byte restore from a Break-mode BackupDir. Identical safety envelope to the repair
#     script's Rollback mode.
#
# .DESIGN NOTES
#
#   Design mirrors `linux-fix-nvme-boot.sh` for uniform behavior across the pair. Every gate the
#   repair script enforces (empty-image hard abort, primary-vs-skip classification, XFS `nouuid`
#   retry, fstab-option allowlist, single-disk `/boot` scope boundary, parallel-array invariant)
#   is preserved identically here.
#
#   Contract with the paired repair script: the exact drop-in files the repair script writes are the
#   ones this breaker removes; the exact modules the repair script includes are the ones this
#   breaker excludes. If either script changes its mutation surface, the paired script MUST be
#   updated in lockstep or the pair test becomes invalid.
#
#   LVM+XFS root support (v2.0+): the script activates any LVM volume groups discovered on the
#   attached OS disk (`vgscan --cache` after a defensive `udevadm settle`), enumerates their
#   logical volumes via `lvs --select vg_uuid=...`, classifies each LV's filesystem, and adds
#   ext4/xfs LVs to the OS partition candidate list. Covers RHEL 9 and SLES 15 SP5 default
#   Marketplace images. A per-invocation LV→disk map (LV_TO_DISK_MAP) records the true parent
#   disk of each LV via `lsblk -snlo NAME <pv-partition> | tail -n1` (v2.1.3 spelling; the
#   pre-v2.1.3 PKNAME-based derivation returned empty on DM/LV forms). Multi-PV VGs are
#   de-duplicated per invocation via a local seen-VGs set keyed on VG UUID.
#
#   Collision handling: if a source VG name collides with a VG name already present on the
#   rescue VM (unusual — rescue is stock Ubuntu 22.04 which has no LVM by default), the source
#   VG is renamed via `vgrename UUID NEWNAME`. Name-based lookup is documented as ambiguous in
#   exactly this collision case (`man vgrename`); UUID-based lookup is not. All subsequent
#   VG operations key on UUID.
#
#   Cleanup: on exit, activated source VGs are deactivated (`vgchange -an <uuid>`), verified
#   via `lvs --noheadings -o lv_active --select vg_uuid=<uuid>` polling, and retried up to
#   3 times with a 1 s sleep. Any lingering leak is logged to stderr. Renamed VGs are reversed.
#
#   Scope boundary — Btrfs: still refused. Azure SLES 15 SP5 Marketplace images use LVM+XFS,
#   not Btrfs; Btrfs is only introduced by SUSE 16 (Marketplace ETA future). If SUSE 16 shows
#   up in customer telemetry, a separate PBI (currently archived) reactivates.
#
#   Scope boundary — LUKS: still refused. Encrypted disks require the customer's passphrase or
#   key material, which offline repair cannot obtain.
#
#   Modules-file provenance limit: Break mode strips `nvme`/`nvme_core` lines from
#   `/etc/initramfs-tools/modules` by content, not by provenance. If the customer's pristine
#   (pre-repair) disk already contained manually-added `nvme` lines for an unrelated reason, Break
#   would strip those too. This is a fundamental limit of content-diffing without provenance
#   markers.
#
#   Compression preservation: the on-disk initramfs image may be gzip, xz, zstd, or lz4. The
#   surgery step MUST sniff the compression from the original file's magic bytes and preserve it
#   at repack — recompressing with a mismatched algorithm can produce an image the guest kernel
#   cannot decompress at all (`CONFIG_RD_GZIP` may not be enabled in every guest kernel).
#
#   initramfs-tools concat layout: modern Debian/Ubuntu images are `<early cpio (microcode,
#   uncompressed)><main cpio (compressed)>`. Feeding this whole file to `cpio -id` extracts ONLY
#   the early cpio (it stops at the TRAILER) and the main payload is silently dropped. `unmkinitramfs`
#   is the only correct tool. This script hard-aborts if `unmkinitramfs` is unavailable on
#   initramfs-tools family guests rather than fall back to the unsafe manual path.
#
# .PARAMETER 1 (Mode)   Report (default) | Break | Rollback
# .PARAMETER 2 (DeviceOverride)   Optional device such as /dev/sdc or /dev/nvme1n1 (whole disk).
# .PARAMETER 3 (BackupDir)   Required in Rollback mode. Absolute path to a Break-mode evidence dir.
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
    break)    MODE="Break" ;;
    rollback) MODE="Rollback" ;;
    *)
        Log-Error "Unrecognized Mode '$MODE_INPUT'. Expected: Report | Break | Rollback."
        exit $STATUS_ERROR
        ;;
esac

TIMESTAMP=$(date +%Y%m%d%H%M%S)
RUN_ID="nvme-break-${TIMESTAMP}-$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-8 || echo "$$")"
EVIDENCE_DIR="/tmp/${RUN_ID}"
MOUNT_POINT="/tmp/${RUN_ID}-root"
SURGERY_DIR="/tmp/${RUN_ID}-surgery"

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
RESOLVED_AUX_DEV=""

# v2.1.4 (Fix D): track ALL aux mounts (usr, var, tmp) the classifier established under the
# candidate root. `separateAuxMounts` in evidence JSON records the per-mount state. Legacy
# `SEPARATE_USR_MOUNTED` / `SEPARATE_USR_DEVICE` scalars retained as backward-compat aliases
# that mirror the "usr" entry byte-for-byte — external test harnesses reading v2.1.2 evidence
# JSON continue to work unchanged.
declare -A SEPARATE_AUX_MOUNTED=([usr]="false" [var]="false" [tmp]="false")
declare -A SEPARATE_AUX_DEVICE=([usr]="" [var]="" [tmp]="")

# v2.1.2 (PBI-E v3): legacy scalars — mirror `SEPARATE_AUX_MOUNTED[usr]` / `SEPARATE_AUX_DEVICE[usr]`.
# Kept so `build_lvm_json` can still emit `separateUsrMounted` / `separateUsrDevice` fields as
# backward-compat aliases in the evidence JSON.
SEPARATE_USR_MOUNTED="false"
SEPARATE_USR_DEVICE=""

# Paths this breaker touches (all relative to $MOUNT_POINT). The repair-side drop-in paths and
# module-line targets MUST match the repair script's contract exactly.
REPAIR_DROPIN_DRACUT="etc/dracut.conf.d/99-azure-nvme.conf"
BREAK_DROPIN_DRACUT="etc/dracut.conf.d/98-azure-nvme-break.conf"
BREAK_DROPIN_DRACUT_CONTENT='omit_drivers+=" nvme nvme_core "'
REPAIR_DROPIN_INITRAMFS="etc/initramfs-tools/modules"    # nvme/nvme_core lines are removed from here
BREAK_DROPIN_INITRAMFS="etc/initramfs-tools/conf.d/90-azure-nvme-break.conf"
BREAK_DROPIN_INITRAMFS_CONTENT='MODULES=list'

declare -a INITRAMFS_IMAGES=()
declare -a IMAGE_VERIFY_METHODS=()
declare -a IMAGE_HAS_NVME=()
declare -a IMAGE_SKIP_REASON=()
declare -a POST_BREAK_HAS_NVME=()
declare -a POST_BREAK_METHODS=()

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
    # each entry. Byte-for-byte parity with fix script per invariant 15.
    for aux in boot/efi boot tmp var usr; do
        if mountpoint -q "$MOUNT_POINT/$aux" 2>/dev/null; then
            umount "$MOUNT_POINT/$aux" 2>/dev/null || umount -l "$MOUNT_POINT/$aux" 2>/dev/null || true
        fi
    done
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        sync 2>/dev/null || true
        umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    fi
    [ -d "$SURGERY_DIR" ] && rm -rf "$SURGERY_DIR" 2>/dev/null || true
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
# Helpers (same as linux-fix-nvme-boot.sh)
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

strip_quotes() {
    local v="$1"
    if [[ ${#v} -ge 2 && "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
        printf '%s' "${v:1:${#v}-2}"
    else
        printf '%s' "$v"
    fi
}

try_mount_ro_with_nouuid_retry() {
    local dev="$1" target="$2" opts="$3"
    if mount -o "$opts" "$dev" "$target" 2>/dev/null; then return 0; fi
    local fstype
    fstype=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 || echo "")
    [ "$fstype" = "xfs" ] || return 1
    mount -o "${opts},nouuid" "$dev" "$target" 2>/dev/null
}

try_mount_rw_with_nouuid_retry() {
    local dev="$1" target="$2"
    if mount "$dev" "$target" 2>/dev/null; then return 0; fi
    local fstype
    fstype=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 || echo "")
    [ "$fstype" = "xfs" ] || return 1
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
# `lsblk -no PKNAME <lv>` (returns EMPTY on DM/LV forms; see v2.1.3 header notes).
declare -A LV_TO_DISK_MAP=()

# LVs enumerated during activation (persists across the run for evidence JSON).
declare -a LVM_ENUMERATED_LVS=()

# v2.0.1 changes vs v2.0.0: UUID-based VG identity end-to-end, LV→disk mapping, multi-PV dedup,
# udevadm settle, verified deactivation with retry + stderr leak log. Byte-for-byte parity with
# the fix script's helpers per Gates.md design invariant 15.
activate_lvm_pvs_and_enumerate_lvs() {
    local lvm_partitions="$1"
    local pv vgname vguuid pvDisk lv lv_fstype
    local -A seen_vgs=()

    if ! command -v vgscan >/dev/null 2>&1 || ! command -v vgchange >/dev/null 2>&1 \
       || ! command -v pvs >/dev/null 2>&1 || ! command -v lvs >/dev/null 2>&1; then
        return 1
    fi

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

        # v2.1.3 (paired with fix): LV-safe pvDisk. See fix script v2.1.3 header for full
        # rationale. `$pv` here is always a partition, so this is the regression-safe case,
        # but we use the same spelling as `resolve_and_mount_aux` for consistency.
        pvDisk=$(lsblk -snlo NAME "$pv" 2>/dev/null | tail -n1 || echo "")

        [ -n "${seen_vgs[$vguuid]:-}" ] && continue
        seen_vgs[$vguuid]=1

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

        # v2.1.0 — activate via --select "vg_uuid=..." (see fix script header for full explanation).
        # v2.1.3 — autoactivation-aware tracking. See fix script v2.1.3 header for rationale.
        # `vgchange -ay || true` because it can return non-zero when systemd's pvscan
        # auto-activated the VG first. State is then queried via lvs --select "lv_active=active"
        # so cleanup deactivates every VG we consumed for source-OS discovery, uniformly.
        vgchange -ay --select "vg_uuid=$vguuid" >/dev/null 2>&1 || true
        if [ -n "$(lvs --noheadings -o lv_name --select "vg_uuid=$vguuid && lv_active=active" 2>/dev/null)" ]; then
            ACTIVATED_SOURCE_VGS+=("$vguuid")
        fi

        # v2.1.4 (Fix E): NO longer emits LV paths on stdout — the helper is invoked as a
        # direct call (not via `$(...)` command substitution), so the array appends persist
        # in the parent shell. See fix script header for the local-reproducer evidence and
        # subshell-scope mechanism analysis.
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
# ----------------------------------------------------------------------------------------------------
resolve_and_mount_aux() {
    local mp="$1"
    local mpTarget="/$mp"
    RESOLVED_AUX_DEV=""

    local fstabLine
    fstabLine=$(awk -v mp="$mpTarget" -v mps="${mpTarget}/" \
        '$1 !~ /^#/ && ($2 == mp || $2 == mps) { print; exit }' \
        "$MOUNT_POINT/etc/fstab" 2>/dev/null || echo "")
    [ -z "$fstabLine" ] && return 0

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
    esac

    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        Log-Warning "Could not resolve fstab entry '$spec' for $mpTarget to a block device."
        return 1
    fi

    # v2.1.3 (PBI-E follow-up): LV-safe devDisk derivation via inverse-tree list. See fix
    # script v2.1.3 header for full rationale + live-probe evidence (2026-09-25). Applies
    # uniformly to LV mapper forms, /dev/vg/lv forms, /dev/dm-N forms, and plain partitions.
    local devDisk
    devDisk=$(lsblk -snlo NAME "$dev" 2>/dev/null | tail -n1 || echo "")
    if [ "$devDisk" = "$ROOT_DISK" ]; then
        Log-Error "Resolved $mpTarget device '$dev' is on the repair VM's own root disk. Refusing."
        return 1
    fi
    if [ -n "$ATTACHED_DISK" ] && [ "$devDisk" != "$ATTACHED_DISK" ]; then
        Log-Error "Resolved $mpTarget device '$dev' is NOT on the attached OS disk ($ATTACHED_DISK). Refusing."
        return 1
    fi

    local mountOpts="ro"
    if [ -n "$opts" ] && [ "$opts" != "defaults" ] && [ "$opts" != "-" ]; then
        local o
        IFS=',' read -ra optArr <<< "$opts"
        for o in "${optArr[@]}"; do
            case "$o" in
                ""|rw|defaults|auto|noauto|ro) ;;
                noload|norecovery|noatime|nodev|nosuid|noexec) mountOpts="${mountOpts},${o}" ;;
                subvol=*|subvolid=*)                            mountOpts="${mountOpts},${o}" ;;
                *) Log-Warning "Dropping unrecognized fstab option '$o' for $mpTarget (allowlist policy)." ;;
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

    # v2.1.4 (Fix D): build `separateAuxMounts` object with per-aux {mounted,device}.
    # Retains legacy `separateUsrMounted` / `separateUsrDevice` scalar aliases for
    # backward-compat with v2.1.2-1.5 consumers. Byte-for-byte parity with fix script.
    local auxMounts=""
    local first="true"
    for aux in usr var tmp; do
        [ "$first" = "true" ] || auxMounts="${auxMounts},"
        first="false"
        auxMounts="${auxMounts}\"${aux}\":{\"mounted\":\"${SEPARATE_AUX_MOUNTED[$aux]}\",\"device\":\"$(json_escape "${SEPARATE_AUX_DEVICE[$aux]}")\"}"
    done

    # v2.1.2 (PBI-E v3): separateUsrMounted / separateUsrDevice for UsrMove-layout evidence.
    # Byte-for-byte parity with linux-fix-nvme-boot per Gates.md design invariant 15.
    printf '{"activatedVgs":[%s],"renamedVgs":[%s],"enumeratedLvs":[%s],"separateUsrMounted":"%s","separateUsrDevice":"%s","separateAuxMounts":{%s}}' \
        "$activated" "$renamed" "$enumerated" \
        "$SEPARATE_USR_MOUNTED" "$(json_escape "$SEPARATE_USR_DEVICE")" \
        "$auxMounts"
}

build_images_json() {
    local i=0 out=""
    while [ $i -lt "${#INITRAMFS_IMAGES[@]}" ]; do
        local sep=","
        [ $i -eq 0 ] && sep=""
        local path="${INITRAMFS_IMAGES[$i]}"
        local preHas="${IMAGE_HAS_NVME[$i]:-}"
        local preMethod="${IMAGE_VERIFY_METHODS[$i]:-}"
        local skip="${IMAGE_SKIP_REASON[$i]:-}"
        local postHas="${POST_BREAK_HAS_NVME[$i]:-}"
        local postMethod="${POST_BREAK_METHODS[$i]:-}"
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
    local outcome="$1" reason="$2" backupDir="$3"
    local imagesJson lvmJson
    imagesJson=$(build_images_json)
    lvmJson=$(build_lvm_json)
    local jsonOut="$EVIDENCE_DIR/evidence.json"
    cat > "$jsonOut" <<EOF
{"schemaVersion":"1.3","scenario":"scsi-to-nvme-migration","producedBy":"linux-break-nvme-boot","producedAtUtc":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","mode":"$MODE","outcome":"$outcome","reason":"$(json_escape "$reason")","os":{"family":"linux","distro":"$(json_escape "$DISTRO_ID")","version":"$(json_escape "$DISTRO_VER")"},"guest":{"osPartition":"$(json_escape "$OS_PARTITION")","attachedDisk":"$(json_escape "$ATTACHED_DISK")","bootPartition":"$(json_escape "$BOOT_PARTITION")","bootEfiPartition":"$(json_escape "$BOOT_EFI_PARTITION")","initramfsTool":"$(json_escape "$INITRAMFS_TOOL")","images":$imagesJson,"lvm":$lvmJson},"backupDir":"$(json_escape "$backupDir")","evidencePath":"$(json_escape "$EVIDENCE_DIR")"}
EOF
    Log-Output "[NVME-BREAK-JSON]$(cat "$jsonOut")"
}

# Verify presence of nvme/nvme_core in an initramfs image. Returns 0 if BOTH present, 1 otherwise.
verify_initramfs_has_nvme() {
    local img="$1" methodFile="$2" list
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
    if [[ "$base" =~ ^initramfs-(.+)\.img$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$base" =~ ^initrd\.img-(.+)$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$base" =~ ^initrd-(.+)$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
    printf ''
}

classify_non_primary_boot() {
    local base
    base=$(basename "$1")
    if [[ "$base" =~ -rescue- ]]; then printf 'non-primary-boot-image'; return 0; fi
    if [[ "$base" =~ kdump\.img$ ]] || [[ "$base" =~ kdump$ ]]; then printf 'non-primary-boot-image'; return 0; fi
    printf ''
}

# ----------------------------------------------------------------------------------------------------
# Discover repair VM's own root disk (so we do not touch it)
# ----------------------------------------------------------------------------------------------------
ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n1 || echo "")
Log-Info "Repair VM root device: ${ROOT_SOURCE:-unknown} (disk: ${ROOT_DISK:-unknown})"

if [ -z "$ROOT_DISK" ]; then
    Log-Error "Could not identify the repair VM's own root disk."
    FAILURE_REASON="repair-vm-root-disk-unknown"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

# ----------------------------------------------------------------------------------------------------
# Locate the attached OS root partition
# ----------------------------------------------------------------------------------------------------
CANDIDATES=""
if [ -n "$DEVICE_OVERRIDE" ]; then
    [ -b "$DEVICE_OVERRIDE" ] || { Log-Error "DeviceOverride '$DEVICE_OVERRIDE' is not a block device."; FAILURE_REASON="device-override-not-block"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
    OVERRIDE_BASENAME=$(basename "$DEVICE_OVERRIDE")
    [ "$OVERRIDE_BASENAME" = "$ROOT_DISK" ] && { Log-Error "DeviceOverride points at the repair VM's own root disk. Refusing."; FAILURE_REASON="device-override-is-repair-root"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
    ATTACHED_DISK="$OVERRIDE_BASENAME"
    # v2.1.1 — see fix script header for the full incident report.
    if command -v partprobe >/dev/null 2>&1; then partprobe "$DEVICE_OVERRIDE" 2>/dev/null || true; fi
    if command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=15 >/dev/null 2>&1 || true; fi
    CANDIDATES=$(lsblk -ln -o NAME,TYPE "$DEVICE_OVERRIDE" 2>/dev/null | awk '$2=="part"{print "/dev/"$1}' || echo "")
    Log-Info "Using device override: $DEVICE_OVERRIDE"
else
    for d in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        [ "$d" = "$ROOT_DISK" ] && continue
        # v2.1.1 — force partition-table refresh + wait for udev events per disk.
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
        ext2|ext3|ext4|xfs) OS_PARTITION_CANDIDATES="$OS_PARTITION_CANDIDATES $part" ;;
        btrfs)              Log-Warning "$part is btrfs (UNSUPPORTED)."; FAILURE_REASON="btrfs-unsupported" ;;
        LVM2_member)        Log-Info "$part is an LVM physical volume; will activate the VG and enumerate its logical volumes"; LVM_PARTITIONS="$LVM_PARTITIONS $part" ;;
        crypto_LUKS)        Log-Warning "$part is LUKS (UNSUPPORTED)."; FAILURE_REASON="luks-unsupported" ;;
    esac
done

if [ -n "$LVM_PARTITIONS" ]; then
    Log-Info "Activating LVM PVs on the attached disk and enumerating LVs..."
    # v2.1.4 (Fix E): direct call, NOT command substitution. Helper populates the parent-shell
    # `LVM_ENUMERATED_LVS` array in-place; we iterate that array here. This preserves Fix B's
    # `ACTIVATED_SOURCE_VGS` appends (which were lost in the v2.1.3 subshell), so evidence
    # JSON reports the true set of activated VGs on the first run.
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
        # `[ -f "$MOUNT_POINT/etc/os-release" ]` check returns FALSE. Mount `/usr` from
        # fstab BEFORE checking os-release. See fix script header for the full incident report.
        if [ -f "$MOUNT_POINT/etc/fstab" ]; then
            # Pre-compute the candidate's disk so `resolve_and_mount_aux`'s safety guard has
            # something to compare against. ATTACHED_DISK is only committed AFTER classification
            # succeeds, so provisionally set it and revert on failure.
            candidateDisk="${LV_TO_DISK_MAP[$part]:-}"
            if [ -z "$candidateDisk" ]; then
                # v2.1.3: LV-safe fallback — see fix script header for rationale.
                candidateDisk=$(lsblk -snlo NAME "$part" 2>/dev/null | tail -n1 || echo "")
            fi
            saved_attached_disk="$ATTACHED_DISK"
            if [ -n "$candidateDisk" ]; then ATTACHED_DISK="$candidateDisk"; fi

            # v2.1.4 (Fix D): unified aux-mount loop over [usr, var, tmp]. See fix script
            # header for the full rationale. Distros without separate `/var` / `/tmp` (Ubuntu,
            # Debian) get no-op behavior because `resolve_and_mount_aux` returns 0 for a
            # not-declared fstab entry.
            for aux in usr var tmp; do
                SEPARATE_AUX_MOUNTED[$aux]="false"
                SEPARATE_AUX_DEVICE[$aux]=""
                if resolve_and_mount_aux "$aux" && [ -n "$RESOLVED_AUX_DEV" ]; then
                    SEPARATE_AUX_MOUNTED[$aux]="true"
                    SEPARATE_AUX_DEVICE[$aux]="$RESOLVED_AUX_DEV"
                fi
            done
            # Legacy aliases mirror the "usr" entry for backward-compat with evidence JSON.
            SEPARATE_USR_MOUNTED="${SEPARATE_AUX_MOUNTED[usr]}"
            SEPARATE_USR_DEVICE="${SEPARATE_AUX_DEVICE[usr]}"

            if [ -f "$MOUNT_POINT/etc/os-release" ]; then
                OS_PARTITION="$part"
                # v2.1.3 — LV-safe disk derivation (see fix script header for full explanation).
                partDisk="${LV_TO_DISK_MAP[$part]:-}"
                if [ -z "$partDisk" ]; then
                    partDisk=$(lsblk -snlo NAME "$part" 2>/dev/null | tail -n1 || echo "")
                fi
                [ -n "$partDisk" ] && ATTACHED_DISK="$partDisk"
                Log-Output "Found attached Linux root filesystem on $part (mounted read-only for classification)"
                # v2.1.4 (Fix D): log every aux mount the classifier established. Legacy
                # aliases already synced above via SEPARATE_USR_* = SEPARATE_AUX_*[usr].
                for aux in usr var tmp; do
                    if [ "${SEPARATE_AUX_MOUNTED[$aux]}" = "true" ]; then
                        Log-Info "Mounted separate /$aux LV (${SEPARATE_AUX_DEVICE[$aux]}) under classification root (fstab-declared)"
                    fi
                done
                break
            fi

            # os-release still missing — unmount ALL aux (if we mounted them) so the next
            # candidate starts clean, then fall through to unmount the root candidate.
            # v2.1.4 (Fix D): leaf-first reverse order.
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
    [ -z "$FAILURE_REASON" ] && FAILURE_REASON="no-attached-root-filesystem"
    Log-Error "No attached Linux root filesystem classified as supported. Reason: $FAILURE_REASON"
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
            *rhel*|*fedora*|*centos*|*suse*) INITRAMFS_TOOL="dracut" ;;
            *debian*)                        INITRAMFS_TOOL="initramfs-tools" ;;
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


if resolve_and_mount_aux "boot"; then BOOT_PARTITION="$RESOLVED_AUX_DEV"; fi
if resolve_and_mount_aux "boot/efi"; then BOOT_EFI_PARTITION="$RESOLVED_AUX_DEV"; fi

# ----------------------------------------------------------------------------------------------------
# Inspect current state
# ----------------------------------------------------------------------------------------------------
while IFS= read -r img; do
    [ -z "$img" ] && continue
    INITRAMFS_IMAGES+=("$img")
done < <(ls -1 "$MOUNT_POINT"/boot/init* 2>/dev/null | grep -Ev '\.old$|\.bak$' || true)

if [ "${#INITRAMFS_IMAGES[@]}" -eq 0 ]; then
    Log-Error "No initramfs images found under $MOUNT_POINT/boot."
    FAILURE_REASON="no-initramfs-images-found"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

ALL_PRIMARY_BROKEN="true"
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
        if [ "${IMAGE_HAS_NVME[-1]}" = "true" ]; then ALL_PRIMARY_BROKEN="false"; fi
        Log-Info "  $img -> PRIMARY, hasNvme=${IMAGE_HAS_NVME[-1]} (method: ${IMAGE_VERIFY_METHODS[-1]})"
    else
        Log-Info "  $img -> SKIPPED ($skipReason)"
    fi
done

if [ "$HAVE_ANY_PRIMARY" != "true" ]; then
    Log-Error "No PRIMARY-boot initramfs images found."
    FAILURE_REASON="no-primary-initramfs-images-found"
    emit_evidence "Aborted" "$FAILURE_REASON" ""
    exit $STATUS_ERROR
fi

Log-Output "Current state: all_primary_broken=$ALL_PRIMARY_BROKEN"

# Idempotency gate: for symmetry with the fix script's two-part gate, also inspect the drop-in state.
# Break is a no-op only when BOTH (a) every primary image already lacks nvme AND (b) the break-side
# drop-in is installed AND the repair-side drop-in is absent (or has been stripped of nvme lines).
BREAK_DROPIN_INSTALLED="false"
REPAIR_DROPIN_CLEARED="false"
if [ "$INITRAMFS_TOOL" = "dracut" ]; then
    if [ -f "$MOUNT_POINT/$BREAK_DROPIN_DRACUT" ] && grep -Fxq "$BREAK_DROPIN_DRACUT_CONTENT" "$MOUNT_POINT/$BREAK_DROPIN_DRACUT" 2>/dev/null; then
        BREAK_DROPIN_INSTALLED="true"
    fi
    if [ ! -f "$MOUNT_POINT/$REPAIR_DROPIN_DRACUT" ]; then
        REPAIR_DROPIN_CLEARED="true"
    fi
else
    if [ -f "$MOUNT_POINT/$BREAK_DROPIN_INITRAMFS" ] && grep -Fxq "$BREAK_DROPIN_INITRAMFS_CONTENT" "$MOUNT_POINT/$BREAK_DROPIN_INITRAMFS" 2>/dev/null; then
        BREAK_DROPIN_INSTALLED="true"
    fi
    if [ ! -f "$MOUNT_POINT/$REPAIR_DROPIN_INITRAMFS" ] || ! grep -qE '^[[:space:]]*(nvme|nvme_core)([[:space:]]|$)' "$MOUNT_POINT/$REPAIR_DROPIN_INITRAMFS" 2>/dev/null; then
        REPAIR_DROPIN_CLEARED="true"
    fi
fi
Log-Info "Drop-in state: break_dropin_installed=$BREAK_DROPIN_INSTALLED repair_dropin_cleared=$REPAIR_DROPIN_CLEARED"

# ----------------------------------------------------------------------------------------------------
# Report mode
# ----------------------------------------------------------------------------------------------------
if [ "$MODE" = "Report" ]; then
    if [ "$ALL_PRIMARY_BROKEN" = "true" ] && [ "$BREAK_DROPIN_INSTALLED" = "true" ] && [ "$REPAIR_DROPIN_CLEARED" = "true" ]; then
        OUTCOME="NoChangeNeeded"
        Log-Output "NoChangeNeeded: every primary-boot image already has nvme removed AND break drop-in is in place AND repair drop-in is cleared."
    else
        OUTCOME="Report"
        Log-Output "Report only: Break mode would remove the repair drop-in, install the break drop-in, and strip nvme/nvme_core from every primary-boot image."
    fi
    emit_evidence "$OUTCOME" "" ""
    STATUS=$STATUS_SUCCESS
    exit $STATUS
fi

# ----------------------------------------------------------------------------------------------------
# Rollback mode  (same envelope as the fix script)
# ----------------------------------------------------------------------------------------------------
if [ "$MODE" = "Rollback" ]; then
    [ -z "$BACKUP_DIR_INPUT" ] || [ ! -d "$BACKUP_DIR_INPUT" ] && { Log-Error "Rollback requires a valid BackupDir."; FAILURE_REASON="rollback-backup-dir-invalid"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
    MANIFEST="$BACKUP_DIR_INPUT/backup-manifest.txt"
    [ -f "$MANIFEST" ] || { Log-Error "BackupDir has no backup-manifest.txt."; FAILURE_REASON="rollback-manifest-missing"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
    manifest_line_count=$(grep -cve '^[[:space:]]*$' "$MANIFEST" 2>/dev/null || echo 0)
    if [ "$manifest_line_count" -lt 1 ]; then
        Log-Error "backup-manifest.txt is empty."
        FAILURE_REASON="rollback-manifest-empty"
        emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"
        exit $STATUS_ERROR
    fi

    boot_required_kb=0; root_required_kb=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        relPath=$(echo "$line" | awk '{print $1}')
        src="$BACKUP_DIR_INPUT/files/$relPath"
        [ -f "$src" ] || continue
        kb=$(du -k "$src" 2>/dev/null | awk '{print $1}'); [ -z "$kb" ] && kb=0
        if [[ "$relPath" == boot/* ]] || [[ "$relPath" == boot ]]; then
            boot_required_kb=$((boot_required_kb + kb))
        else
            root_required_kb=$((root_required_kb + kb))
        fi
    done < "$MANIFEST"

    if ! mount -o remount,rw "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
        if ! try_mount_rw_with_nouuid_retry "$OS_PARTITION" "$MOUNT_POINT"; then
            Log-Error "Could not re-mount $OS_PARTITION RW for rollback."
            FAILURE_REASON="rollback-mount-rw-failed"
            emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR
        fi
    fi
    findmnt -no OPTIONS "$MOUNT_POINT" 2>/dev/null | grep -Eq '(^|,)rw(,|$)' || { Log-Error "$MOUNT_POINT not writable."; FAILURE_REASON="rollback-filesystem-forced-read-only"; emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"; exit $STATUS_ERROR; }
    if [ -n "$BOOT_PARTITION" ] && mountpoint -q "$MOUNT_POINT/boot"; then
        if ! mount -o remount,rw "$MOUNT_POINT/boot" 2>/dev/null; then
            umount "$MOUNT_POINT/boot" 2>/dev/null || true
            try_mount_rw_with_nouuid_retry "$BOOT_PARTITION" "$MOUNT_POINT/boot" || { Log-Error "Could not re-mount /boot RW for rollback."; FAILURE_REASON="rollback-boot-mount-rw-failed"; emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"; exit $STATUS_ERROR; }
        fi
    fi

    # v2.1.4 (Fix D): symmetric RW-remount for /var and /tmp in Rollback mode.
    for aux in var tmp; do
        if [ "${SEPARATE_AUX_MOUNTED[$aux]:-false}" = "true" ] && mountpoint -q "$MOUNT_POINT/$aux" 2>/dev/null; then
            if ! mount -o remount,rw "$MOUNT_POINT/$aux" 2>/dev/null; then
                umount "$MOUNT_POINT/$aux" 2>/dev/null || true
                try_mount_rw_with_nouuid_retry "${SEPARATE_AUX_DEVICE[$aux]}" "$MOUNT_POINT/$aux" || { Log-Error "Could not re-mount /$aux RW for rollback."; FAILURE_REASON="rollback-${aux}-mount-rw-failed"; emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"; exit $STATUS_ERROR; }
            fi
        fi
    done

    root_free_kb=$(df -Pk "$MOUNT_POINT" | awk 'NR==2 {print $4}')
    boot_free_kb=$(df -Pk "$MOUNT_POINT/boot" | awk 'NR==2 {print $4}')
    if [ "${root_free_kb:-0}" -lt "$root_required_kb" ] || [ "${boot_free_kb:-0}" -lt "$boot_required_kb" ]; then
        Log-Error "Insufficient free space for Rollback."
        FAILURE_REASON="rollback-insufficient-disk-space"
        emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"; exit $STATUS_ERROR
    fi

    RESTORE_COUNT=0; RESTORE_OK="true"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        relPath=$(echo "$line" | awk '{print $1}')
        expectedSha=$(echo "$line" | awk '{print $2}')
        src="$BACKUP_DIR_INPUT/files/$relPath"; dst="$MOUNT_POINT/$relPath"
        if [ ! -f "$src" ]; then Log-Error "Backup file '$src' missing."; RESTORE_OK="false"; continue; fi
        mkdir -p "$(dirname "$dst")" 2>/dev/null || true
        cp -a "$src" "$dst" || RESTORE_OK="false"
        actualSha=$(sha256sum "$dst" 2>/dev/null | awk '{print $1}')
        [ "$actualSha" = "$expectedSha" ] || { Log-Error "Post-restore hash mismatch for '$relPath'."; RESTORE_OK="false"; }
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
        emit_evidence "Aborted" "$FAILURE_REASON" "$BACKUP_DIR_INPUT"; exit $STATUS_ERROR
    fi

    OUTCOME="RolledBack"
    Log-Output "VERIFIED: Rollback restored $RESTORE_COUNT file(s)."
    emit_evidence "$OUTCOME" "" "$BACKUP_DIR_INPUT"
    STATUS=$STATUS_SUCCESS
    exit $STATUS
fi

# ----------------------------------------------------------------------------------------------------
# Break mode
# ----------------------------------------------------------------------------------------------------
if [ "$ALL_PRIMARY_BROKEN" = "true" ] && [ "$BREAK_DROPIN_INSTALLED" = "true" ] && [ "$REPAIR_DROPIN_CLEARED" = "true" ]; then
    OUTCOME="NoChangeNeeded"
    Log-Output "NoChangeNeeded: every primary-boot image already has nvme removed AND break drop-in in place AND repair drop-in cleared."
    emit_evidence "$OUTCOME" "" ""
    STATUS=$STATUS_SUCCESS
    exit $STATUS
fi

# Free-space pre-flight.
total_images_kb=0; max_image_kb=0
for img in "${INITRAMFS_IMAGES[@]}"; do
    kb=$(du -k "$img" 2>/dev/null | awk '{print $1}')
    if [ -n "$kb" ]; then
        total_images_kb=$((total_images_kb + kb))
        [ "$kb" -gt "$max_image_kb" ] && max_image_kb=$kb
    fi
done
tmp_free_kb=$(df -Pk /tmp | awk 'NR==2 {print $4}')
boot_free_kb=$(df -Pk "$MOUNT_POINT/boot" | awk 'NR==2 {print $4}')
required_tmp_kb=$((total_images_kb + 128*1024 + max_image_kb))    # extra headroom for surgery unpack
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
        Log-Error "Could not re-mount $OS_PARTITION RW for break."
        FAILURE_REASON="mount-rw-failed"
        emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR
    fi
fi
findmnt -no OPTIONS "$MOUNT_POINT" 2>/dev/null | grep -Eq '(^|,)rw(,|$)' || { Log-Error "$MOUNT_POINT not writable."; FAILURE_REASON="filesystem-forced-read-only"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
if [ -n "$BOOT_PARTITION" ] && mountpoint -q "$MOUNT_POINT/boot"; then
    if ! mount -o remount,rw "$MOUNT_POINT/boot" 2>/dev/null; then
        umount "$MOUNT_POINT/boot" 2>/dev/null || true
        try_mount_rw_with_nouuid_retry "$BOOT_PARTITION" "$MOUNT_POINT/boot" || { Log-Error "Could not re-mount /boot RW for break."; FAILURE_REASON="boot-mount-rw-failed"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
    fi
fi

# v2.1.4 (Fix D): symmetric RW-remount for /var and /tmp in Break mode. Matches the fix
# script per Gates.md design invariant 15.
for aux in var tmp; do
    if [ "${SEPARATE_AUX_MOUNTED[$aux]}" = "true" ] && mountpoint -q "$MOUNT_POINT/$aux" 2>/dev/null; then
        if ! mount -o remount,rw "$MOUNT_POINT/$aux" 2>/dev/null; then
            umount "$MOUNT_POINT/$aux" 2>/dev/null || true
            try_mount_rw_with_nouuid_retry "${SEPARATE_AUX_DEVICE[$aux]}" "$MOUNT_POINT/$aux" || { Log-Error "Could not re-mount /$aux RW for break."; FAILURE_REASON="${aux}-mount-rw-failed"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
        fi
    fi
done

BACKUP_ROOT="$EVIDENCE_DIR/files"
MANIFEST="$EVIDENCE_DIR/backup-manifest.txt"
ADDED_FILES="$EVIDENCE_DIR/added-files.txt"
mkdir -p "$BACKUP_ROOT" || { Log-Error "Could not create backup root."; FAILURE_REASON="backup-root-mkdir-failed"; emit_evidence "Aborted" "$FAILURE_REASON" ""; exit $STATUS_ERROR; }
: > "$MANIFEST"; : > "$ADDED_FILES"

backup_or_note_missing() {
    local relPath="$1"
    local src="$MOUNT_POINT/$relPath"
    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$BACKUP_ROOT/$relPath")" 2>/dev/null || true
        cp -a "$src" "$BACKUP_ROOT/$relPath"
        local sha; sha=$(sha256sum "$src" | awk '{print $1}')
        printf '%s %s\n' "$relPath" "$sha" >> "$MANIFEST"
    else
        printf '%s\n' "$relPath" >> "$ADDED_FILES"
    fi
}

# Back up drop-in targets (repair-side + break-side) and every existing initramfs image.
backup_or_note_missing "$REPAIR_DROPIN_DRACUT"
backup_or_note_missing "$BREAK_DROPIN_DRACUT"
backup_or_note_missing "$REPAIR_DROPIN_INITRAMFS"
backup_or_note_missing "$BREAK_DROPIN_INITRAMFS"
for img in "${INITRAMFS_IMAGES[@]}"; do
    relImg=${img#"$MOUNT_POINT/"}
    backup_or_note_missing "$relImg"
done

# Mutation step 1: remove repair-side drop-in artifacts.
if [ "$INITRAMFS_TOOL" = "dracut" ]; then
    if [ -f "$MOUNT_POINT/$REPAIR_DROPIN_DRACUT" ]; then
        rm -f "$MOUNT_POINT/$REPAIR_DROPIN_DRACUT" || { Log-Error "Failed to remove repair dracut drop-in."; FAILURE_REASON="repair-dropin-remove-failed"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
    fi
    # Install break drop-in.
    mkdir -p "$MOUNT_POINT/$(dirname "$BREAK_DROPIN_DRACUT")" 2>/dev/null || true
    printf '%s\n' "$BREAK_DROPIN_DRACUT_CONTENT" > "$MOUNT_POINT/$BREAK_DROPIN_DRACUT" || { Log-Error "Failed to write break dracut drop-in."; FAILURE_REASON="break-dropin-write-failed"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
else
    if [ -f "$MOUNT_POINT/$REPAIR_DROPIN_INITRAMFS" ]; then
        # Remove `nvme` and `nvme_core` module lines from /etc/initramfs-tools/modules.
        # Use `cat > file` (not `cp -a`) so we preserve the destination's mode/owner.
        tmpf=$(mktemp)
        grep -Ev '^[[:space:]]*(nvme|nvme_core)([[:space:]]|$)' "$MOUNT_POINT/$REPAIR_DROPIN_INITRAMFS" > "$tmpf" || true
        if ! cat "$tmpf" > "$MOUNT_POINT/$REPAIR_DROPIN_INITRAMFS"; then
            rm -f "$tmpf" 2>/dev/null || true
            Log-Error "Failed to strip nvme lines."
            FAILURE_REASON="repair-dropin-strip-failed"
            emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
            exit $STATUS_ERROR
        fi
        rm -f "$tmpf" 2>/dev/null || true
    fi
    mkdir -p "$MOUNT_POINT/$(dirname "$BREAK_DROPIN_INITRAMFS")" 2>/dev/null || true
    printf '%s\n' "$BREAK_DROPIN_INITRAMFS_CONTENT" > "$MOUNT_POINT/$BREAK_DROPIN_INITRAMFS" || { Log-Error "Failed to write break initramfs-tools drop-in."; FAILURE_REASON="break-dropin-write-failed"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
fi
Log-Output "Repair drop-in cleared; break drop-in installed."

# Mutation step 2: chroot prep (identical to fix script).
for dir in dev proc sys run; do
    [ -d "$MOUNT_POINT/$dir" ] || mkdir -p "$MOUNT_POINT/$dir" || { Log-Error "Missing $MOUNT_POINT/$dir."; FAILURE_REASON="chroot-mkdir-failed:$dir"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
done

for spec in "dev|rbind|/dev" "sys|rbind|/sys" "run|bind|/run"; do
    dir="${spec%%|*}"; rest="${spec#*|}"; kind="${rest%%|*}"; src="${rest##*|}"
    mount --"$kind" "$src" "$MOUNT_POINT/$dir" || { Log-Error "Failed to $kind $src."; FAILURE_REASON="chroot-bind-mount-failed:$dir"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
    mount --make-rslave "$MOUNT_POINT/$dir" || { Log-Error "Failed to make rslave $MOUNT_POINT/$dir."; FAILURE_REASON="chroot-make-rslave-failed:$dir"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
    mountpoint -q "$MOUNT_POINT/$dir" || { Log-Error "Not a mountpoint $MOUNT_POINT/$dir."; FAILURE_REASON="chroot-mountpoint-check-failed:$dir"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
done
mount -t proc proc "$MOUNT_POINT/proc" || { Log-Error "Failed to mount procfs."; FAILURE_REASON="chroot-bind-mount-failed:proc"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
mountpoint -q "$MOUNT_POINT/proc" || { Log-Error "procfs not mounted."; FAILURE_REASON="chroot-mountpoint-check-failed:proc"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
if [ -d /dev/pts ] && [ ! -d "$MOUNT_POINT/dev/pts" ]; then
    mkdir -p "$MOUNT_POINT/dev/pts" 2>/dev/null || true
fi
if [ -d "$MOUNT_POINT/dev/pts" ] && ! mountpoint -q "$MOUNT_POINT/dev/pts" 2>/dev/null; then
    if mount --bind /dev/pts "$MOUNT_POINT/dev/pts"; then
        mount --make-slave "$MOUNT_POINT/dev/pts" 2>/dev/null || true
    fi
fi

CHROOT_LOG="$EVIDENCE_DIR/chroot.log"
if [ "$INITRAMFS_TOOL" = "dracut" ]; then
    chroot "$MOUNT_POINT" /bin/bash -c 'command -v dracut >/dev/null 2>&1' || { Log-Error "dracut not installed."; FAILURE_REASON="dracut-not-installed-in-guest"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
else
    chroot "$MOUNT_POINT" /bin/bash -c 'command -v update-initramfs >/dev/null 2>&1' || { Log-Error "update-initramfs not installed."; FAILURE_REASON="update-initramfs-not-installed-in-guest"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }
    # Since initramfs-tools guests may ship concat (early + main) images, unmkinitramfs is REQUIRED
    # for the surgery fallback path. Refusing here (rather than silently corrupting during surgery)
    # is the safe default. Also acceptable on the repair VM itself (host-side) since surgery runs
    # outside the chroot.
    if ! command -v unmkinitramfs >/dev/null 2>&1; then
        Log-Error "unmkinitramfs is not available on this repair VM. It is required for safe surgery on Debian/Ubuntu concat initramfs images. Install initramfs-tools on the repair VM."
        FAILURE_REASON="unmkinitramfs-not-available-on-repair-vm"
        emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"
        exit $STATUS_ERROR
    fi
fi

CHROOT_KVERS=$(chroot "$MOUNT_POINT" /bin/bash -c 'ls -1 /lib/modules 2>/dev/null | tr "\n" " "' || echo "")
if [ -z "$(printf '%s' "$CHROOT_KVERS" | tr -d '[:space:]')" ]; then
    Log-Error "No kernel modules tree in chroot."
    FAILURE_REASON="no-kernel-modules-found-in-chroot"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR
fi

# Mutation step 3: rebuild PRIMARY-boot images in place.
Log-Output "Rebuilding primary-boot initramfs images inside chroot ($INITRAMFS_TOOL)..."
REBUILD_OK="true"
if [ "$INITRAMFS_TOOL" = "dracut" ]; then
    i=0
    for img in "${INITRAMFS_IMAGES[@]}"; do
        skipReason="${IMAGE_SKIP_REASON[$i]}"; i=$((i + 1))
        [ -n "$skipReason" ] && { Log-Info "  SKIP $img ($skipReason)"; continue; }
        relImg=${img#"$MOUNT_POINT"}
        kver=$(extract_kver_from_image "$img")
        [ -z "$kver" ] && { Log-Warning "Could not extract kver from $img."; continue; }
        chroot "$MOUNT_POINT" /bin/bash -c 'test -d "/lib/modules/$1"' -- "$kver" || { Log-Warning "/lib/modules/$kver missing."; continue; }
        Log-Info "  dracut -f $relImg $kver (with break drop-in in effect)"
        chroot "$MOUNT_POINT" /bin/bash -c 'dracut -f "$1" "$2"' -- "$relImg" "$kver" >> "$CHROOT_LOG" 2>&1 || { Log-Error "dracut failed for $img."; REBUILD_OK="false"; break; }
    done
else
    chroot "$MOUNT_POINT" /bin/bash -c 'update-initramfs -u -k all' >> "$CHROOT_LOG" 2>&1 || { Log-Error "update-initramfs failed."; REBUILD_OK="false"; }
fi

[ "$REBUILD_OK" = "true" ] || { FAILURE_REASON="initramfs-rebuild-failed"; emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR; }

# Mutation step 4: universal-strip fallback. If any primary image STILL contains nvme.ko or
# nvme_core.ko after the rebuild (typical for initramfs-tools with MODULES=most), unpack the image,
# delete matching files, and repack. This is a distro-agnostic surgery.
# Sniff the compression scheme from the first bytes of an initramfs image. Returns one of:
# gzip | xz | zstd | lz4 | none. "none" means the file starts with a bare cpio archive (uncompressed).
sniff_initramfs_compression() {
    local img="$1"
    local hex
    hex=$(head -c 6 "$img" 2>/dev/null | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo "")
    case "$hex" in
        1f8b*)      printf 'gzip' ;;
        fd377a58*)  printf 'xz' ;;
        28b52ffd*)  printf 'zstd' ;;
        04224d18*)  printf 'lz4' ;;    # LZ4 Frame format (v1.4+)
        02214c18*)  printf 'lz4' ;;    # LZ4 legacy format (what the Linux kernel decompressor expects)
        070701*|070702*|070707*) printf 'none' ;;    # bare cpio
        *)          printf 'none' ;;
    esac
}

# Emit the correct decompressor command for a sniffed scheme. Prints the command; caller pipes.
decompressor_for() {
    case "$1" in
        gzip) printf 'gzip -dc' ;;
        xz)   printf 'xz -dc' ;;
        zstd) printf 'zstd -dc' ;;
        lz4)  printf 'lz4 -dc' ;;
        none|*) printf 'cat' ;;
    esac
}

# Emit the correct compressor command for a sniffed scheme. Prints the command; caller pipes.
# Kernel decoder constraints:
#   - xz needs --check=crc32 (kernel's lib/xz/ only supports CRC32/none, not the CLI default CRC64)
#   - zstd needs a standard-window frame; any level in [1..19] without --long/--ultra works.
#     Level 19 is a reasonable default; matching the source level is NOT required.
#   - lz4 needs legacy format (-l); kernel's lib/decompress_unlz4.c does not understand LZ4 Frame.
compressor_for() {
    case "$1" in
        gzip) printf 'gzip -c' ;;
        xz)   printf 'xz -c --check=crc32' ;;
        zstd) printf 'zstd -c -q -19' ;;
        lz4)  printf 'lz4 -c -l' ;;
        none|*) printf 'cat' ;;
    esac
}

# Returns 0 if $img appears to be a concatenated cpio-then-compressed initramfs (Debian/Ubuntu
# microcode + main payload). Detects the boundary by locating the first cpio TRAILER!!! marker
# (which terminates the early-cpio segment) and looking near it for a compression magic. The
# theoretical exact end of the trailer record for a newc-format cpio with pathname "TRAILER!!!\0"
# is at grep-reported offset + 14 (110-byte header + 11-byte pathname → 121, padded to 124 = off+14),
# but real-world cpio generators sometimes add extra inter-segment alignment padding. We start the
# scan 6 bytes BEFORE the theoretical boundary and read 512 bytes past it, so a magic at any actual
# position within ±6 bytes of the theoretical boundary (and up to +506 bytes past) is caught. This
# widened window trades a negligible false-positive-risk increase for robustness against
# generator-specific padding conventions.
is_concat_initramfs() {
    local img="$1"
    local off
    off=$(LC_ALL=C grep -a -bo -m1 'TRAILER!!!' "$img" 2>/dev/null | head -n1 | cut -d: -f1)
    [ -z "$off" ] && return 1
    # Widened window: start a few bytes before the theoretical boundary in case the padding
    # convention differs. `tail -c +N` is 1-indexed, so 0-indexed position P corresponds to N=P+1.
    # Theoretical end = off+14 (0-indexed); we start scanning at 0-indexed off+8 → N=off+9.
    local scanStart=$((off + 9))
    [ "$scanStart" -lt 1 ] && scanStart=1
    local hex
    hex=$(tail -c +"$scanStart" "$img" 2>/dev/null | head -c 512 | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo "")
    case "$hex" in
        *1f8b*|*fd377a58*|*28b52ffd*|*04224d18*|*02214c18*) return 0 ;;
        *) return 1 ;;
    esac
}

strip_nvme_from_image() {
    local img="$1"
    mkdir -p "$SURGERY_DIR" 2>/dev/null || return 1
    rm -rf "${SURGERY_DIR:?}"/* 2>/dev/null || true

    local scheme
    scheme=$(sniff_initramfs_compression "$img")

    local extracted="false"
    if command -v unmkinitramfs >/dev/null 2>&1; then
        if unmkinitramfs "$img" "$SURGERY_DIR" 2>/dev/null; then
            extracted="true"
        fi
    fi

    if [ "$extracted" != "true" ]; then
        # Manual fallback: SAFE ONLY FOR NON-CONCAT IMAGES. If the file is a concatenation of an
        # early-cpio (uncompressed microcode) + main compressed cpio (any size), feeding the whole
        # file to `cpio -id` extracts ONLY the early segment and silently drops the main payload,
        # producing an empty-shell garbage image that would false-verify as "nvme absent". We use
        # a TRAILER-based boundary detector rather than a fixed window so early-cpio segments of
        # any size (including 100KB+ microcode bundles) are correctly identified as concat.
        if is_concat_initramfs "$img"; then
            Log-Error "Image '$img' is a concatenated cpio-then-compressed initramfs but unmkinitramfs is unavailable / did not extract it. Refusing manual extraction (would produce a corrupted image)."
            return 1
        fi
        local decomp
        decomp=$(decompressor_for "$scheme")
        (cd "$SURGERY_DIR" && $decomp < "$img" | cpio -id --quiet 2>/dev/null) || return 1
    fi

    # Delete nvme + nvme_core module files (any compression suffix). Also prune stale references
    # from modules.dep / modules.alias.
    find "$SURGERY_DIR" -type f \( \
        -name 'nvme.ko' -o -name 'nvme.ko.*' \
        -o -name 'nvme_core.ko' -o -name 'nvme_core.ko.*' \
        -o -name 'nvme-core.ko' -o -name 'nvme-core.ko.*' \
    \) -delete 2>/dev/null || true
    find "$SURGERY_DIR" -type f -name 'modules.dep' -exec sed -i.bak -E '/(^|[[:space:]])[^[:space:]]*\/nvme(_core|-core)?\.ko(\.[a-z0-9]+)?([[:space:]]|:)/d' {} \; 2>/dev/null || true
    find "$SURGERY_DIR" -type f -name 'modules.alias' -exec sed -i.bak -E '/^[[:space:]]*alias[[:space:]]+[^[:space:]]+[[:space:]]+nvme(_core)?$/d' {} \; 2>/dev/null || true
    find "$SURGERY_DIR" -type f -name '*.bak' -delete 2>/dev/null || true

    local compressor
    compressor=$(compressor_for "$scheme")

    local newImg="${img}.nvmebreak.tmp"
    if [ -d "$SURGERY_DIR/early" ] || [ -d "$SURGERY_DIR/main" ]; then
        (cd "$SURGERY_DIR/main" 2>/dev/null && find . 2>/dev/null | cpio -o --quiet -H newc | $compressor) > "$newImg" || return 1
        if [ -d "$SURGERY_DIR/early" ]; then
            local earlyImg="${img}.early.tmp"
            (cd "$SURGERY_DIR/early" && find . | cpio -o --quiet -H newc) > "$earlyImg" || { rm -f "$earlyImg"; return 1; }
            cat "$earlyImg" "$newImg" > "${newImg}.combined" && mv "${newImg}.combined" "$newImg"
            rm -f "$earlyImg" 2>/dev/null || true
        fi
    else
        (cd "$SURGERY_DIR" && find . 2>/dev/null | cpio -o --quiet -H newc | $compressor) > "$newImg" || return 1
    fi

    [ -s "$newImg" ] || { rm -f "$newImg" 2>/dev/null; return 1; }
    mv "$newImg" "$img" || return 1
    return 0
}

Log-Output "Post-rebuild verification and (if necessary) surgical strip..."
POST_IMAGES=("${INITRAMFS_IMAGES[@]}")

VERIFIED_ALL="true"; VERIFY_COUNT=0
i=0
for img in "${POST_IMAGES[@]}"; do
    skipReason="${IMAGE_SKIP_REASON[$i]}"
    if [ -n "$skipReason" ]; then
        POST_BREAK_HAS_NVME+=("")
        POST_BREAK_METHODS+=("")
        i=$((i + 1))
        continue
    fi
    methodFile=$(mktemp)
    if verify_initramfs_has_nvme "$img" "$methodFile"; then
        Log-Warning "  $img still has nvme after rebuild — running surgical strip..."
        if strip_nvme_from_image "$img"; then
            # Re-verify after surgery.
            if verify_initramfs_has_nvme "$img" "$methodFile"; then
                Log-Error "  Surgery did not remove nvme from $img."
                POST_BREAK_HAS_NVME+=("true")
                VERIFIED_ALL="false"
            else
                Log-Info "  VERIFIED $img (post-surgery)"
                POST_BREAK_HAS_NVME+=("false")
            fi
        else
            Log-Error "  Surgery FAILED for $img."
            POST_BREAK_HAS_NVME+=("true")
            VERIFIED_ALL="false"
        fi
    else
        Log-Info "  VERIFIED $img (rebuild-only)"
        POST_BREAK_HAS_NVME+=("false")
    fi
    POST_BREAK_METHODS+=("$(cat "$methodFile")")
    rm -f "$methodFile" 2>/dev/null || true
    VERIFY_COUNT=$((VERIFY_COUNT + 1))
    i=$((i + 1))
done

if [ "$VERIFY_COUNT" -eq 0 ]; then
    Log-Error "Post-break verification set was empty."
    FAILURE_REASON="no-primary-images-to-verify"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR
fi

if [ "$VERIFIED_ALL" != "true" ]; then
    Log-Error "Post-break verification FAILED. Roll back with: --parameters ++Rollback ++${DEVICE_OVERRIDE:-<device>} ++$EVIDENCE_DIR"
    FAILURE_REASON="post-break-verification-failed"
    emit_evidence "Aborted" "$FAILURE_REASON" "$EVIDENCE_DIR"; exit $STATUS_ERROR
fi

OUTCOME="Broken"
Log-Output "VERIFIED: $VERIFY_COUNT primary-boot initramfs image(s) rebuilt without nvme/nvme_core. Rollback dir: $EVIDENCE_DIR"
emit_evidence "$OUTCOME" "" "$EVIDENCE_DIR"
STATUS=$STATUS_SUCCESS
exit $STATUS
