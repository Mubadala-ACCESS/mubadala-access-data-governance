# NAS2 No-LDAP SMB + NFS Deployment and Administration Runbook

**Environment:** Synology HD6500, A2 and C1 Linux workstations  
**NAS1 mount:** `/storagenas1`  
**NAS2 mount:** `/storagenas2`  
**Script:** `migrate_storagenas1_to_storagenas2_unified_v2.sh` v2.1.1  
**Validated script SHA-256:** `6058a2facb35dc41e1106b91d02f73734ffd6fc54cfc5a4a87faee63fa5a578a`  
**Date:** 2026-07-24

---

## 1. Final architecture decision

Use two access paths with one controlled storage policy:

```text
                         Synology HD6500 / DSM
                    local users, local groups, DSM ACLs
                                  |
              +-------------------+-------------------+
              |                                       |
              | NFS                                   | SMB
              | trusted managed clients only          | human storage access
              v                                       v
        A2 and C1 workstations                users without workstation access
        static UID/GID discipline             DSM local accounts and VPN
```

### NFS

Use NFS only for A2, C1, and other centrally administered Linux systems. NFS
AUTH_SYS permissions depend on numeric identities, not only account names.

### SMB

SMB is the correct primary method for people who need NAS access but must not
have workstation accounts. Create those users as **local DSM users**, add them
to DSM storage/project groups, and let them connect over the institutional VPN.
Do not create A2 or C1 accounts for SMB-only users.

### Permission authority

- The v2 script manages directory structure, coarse POSIX ownership/modes,
  exact Linux GIDs, migration, verification, and audit.
- DSM manages SMB accounts, group membership, shared-folder permissions, and
  subfolder Windows ACLs.
- Do not use `setfacl` from A2 or C1. The observed `Operation not supported`
  result means POSIX default ACLs are not available through this NFS mount.

---

## 2. Non-negotiable storage policy

- NAS2 is authoritative long-term storage.
- NAS1 is legacy and should be read-only during migration.
- `/home` is not bulk storage.
- `/fastscratch` and `/fastscratch2` are temporary and regenerable.
- Do not create arbitrary top-level folders under `/storagenas2`.
- Do not write to `dataapis-live`, `dataapis-backups`, or `00_ADMIN` without
  explicit authorization.
- Never delete the source until the destination has been verified.

Approved structure:

```text
/storagenas2/
├── 00_ADMIN/
├── 10_PROJECTS/
├── 20_DATASETS/
├── 30_USERS/
├── 40_SHARED/
│   └── users-open/
├── 50_ARCHIVE/
├── 90_LEGACY/
│   └── storagenas1/
│       └── raw/
├── dataapis-backups/
├── dataapis-live/
└── #recycle/
```

---

## 3. Important corrections to the earlier plan

### 3.1 The NAS2 mount root is currently unsafe unless DSM ACLs override it

The supplied listing shows:

```text
drwxrwxrwx root root /storagenas2
```

A real POSIX mode of `0777` lets ordinary NFS users create unauthorized
folders at the root, contradicting the policy. Before setup, test with a real
non-administrator account:

```bash
sudo -u ORDINARY_USER sh -c '
  set -eu
  probe=/storagenas2/.nas2-root-write-test-$$
  if touch "$probe" 2>/dev/null; then
    echo "UNSAFE: ordinary user created $probe"
    rm -f "$probe"
    exit 1
  fi
  echo "PASS: ordinary user cannot create NAS2 top-level entries"
'
```

- If the test succeeds in creating the file, fix the DSM share/root ACL before
  continuing.
- If the write is denied but `stat` still displays `0777` because DSM ACLs are
  authoritative, document the test and use `--allow-insecure-root` with the
  v2 script. That option is an audited override, not a permission fix.
- Use `--harden-root-posix` only after confirming the shared folder is intended
  to use Unix permissions. Do not use it blindly on a Windows-ACL-managed
  shared folder.

### 3.2 `setfacl` is not the SMB permission system

The error:

```text
setfacl: Operation not supported
```

means this NFS client interface cannot apply POSIX ACLs. It does not mean DSM
cannot enforce detailed SMB ACLs. Apply fine-grained permissions in DSM/File
Station, then test through both SMB and NFS.

### 3.3 Private user folders need administrator access by design

A mode of `0700` gives access to the owner and root, but not to a non-root
`storage-admin` group. The v2 script uses:

```text
normal user folder:  user:nas2users      2755
private user folder: user:storage-admin  2750
```

Use `umask 0022` for normal readable data and `umask 0027` for private data.
Root retains emergency administrative access.

### 3.4 `root:dataapis` mode `2750` is not a writable service model

If the DataAPIs process runs as `ajd11`, changing the top-level directory to
`root:dataapis` mode `2750` would leave the non-root service without owner
write permission. The v2 script therefore:

- preserves the current DataAPIs owner/group by default;
- sets only the two top-level modes to `2750` during initial setup;
- never recursively changes DataAPIs content;
- requires `--dataapis-service-user USER` with `--adopt-dataapis`;
- adopts top-level ownership as `SERVICE_USER:dataapis`, not `root:dataapis`.

---

## 4. Identity model without LDAP

### 4.1 Core groups

Create these local groups in DSM first:

| Group | Purpose |
|---|---|
| `storage-admin` | Storage structure, ACL, provisioning, migration administration |
| `nas2users` | Approved NAS population and baseline read access |
| `dataapis` | Verified DataAPIs service/operators |
| `nas2-prj-<project>` | Write access for one project |

`nas2users` is not a universal project-write group. It answers, “Is this an
approved NAS user?” A project group answers, “May this account modify this
project?”

### 4.2 DSM-first GID workflow

DSM should be the first place each SMB-relevant group is created. DSM assigns
its numeric GID. Query it through a read-only SSH session to the NAS:

```bash
getent group storage-admin
getent group nas2users
getent group dataapis
getent group nas2-prj-regclim-wrf
```

Record the exact numeric GIDs. Do **not** edit `/etc/group` directly on the
Synology.

Then mirror the same group name and GID on A2 and C1 through the v2 script.
The script stops on a GID collision or mismatch rather than silently changing
identity mappings.

### 4.3 UID rules

For NFS AUTH_SYS, account-specific access is based on numeric IDs. Synology's
NFS guidance requires the client and NAS to use the same numerical UID/GID for
the same identity. At minimum, the same workstation user must have the same UID
on A2 and C1:

```bash
# Run on both A2 and C1
id USERNAME
getent passwd USERNAME
```

The same username with a different UID is not the same NFS identity. In this
no-LDAP design, shared project writes are deliberately group-based, so the
project GID is the principal bridge between DSM, A2, and C1. A folder that uses
owner-only semantics across both SMB and NFS needs matching UIDs or a DSM ACL
plus protocol-by-protocol validation.

Do not change existing production UIDs or GIDs casually. Changing an ID after
files exist requires an inventory and controlled ownership migration.

### 4.4 SMB-only users

For a collaborator who has no workstation access:

1. Create a local DSM user.
2. Require a strong unique password.
3. Add the user to `nas2users`.
4. Add the user to required DSM project groups.
5. Do not create an A2 or C1 login account.
6. Do not add the user to workstation login groups.
7. Grant only SMB/shared-folder access needed for the project.
8. Require VPN for remote access.

SMB-only accounts do not need matching Linux UIDs on A2/C1 when they work in
DSM-ACL-managed project/shared areas. Avoid using POSIX owner-only semantics as
the sole control for those users.

---

## 5. DSM configuration

The exact DSM menu labels can differ slightly by DSM release. Use the current
HD6500 DSM interface and record screenshots/exports before changes.

### 5.1 Snapshot and export current state

Before changing permissions:

1. Confirm the storage pool and volume are healthy.
2. Take a Btrfs/Snapshot Replication snapshot of the NAS2 shared folder if the
   current volume and package configuration support it.
3. Export or record existing shared-folder and subfolder ACLs.
4. Record current ownership/modes:

```bash
findmnt -T /storagenas2
stat -c '%a %U:%G %n' \
  /storagenas2 \
  /storagenas2/dataapis-live \
  /storagenas2/dataapis-backups
```

### 5.2 SMB service settings

In DSM Control Panel > File Services > SMB:

- Enable SMB.
- Minimum SMB protocol: SMB2.
- Maximum SMB protocol: SMB3.
- Disable SMB1.
- Disable the guest account and anonymous access.
- Set SMB transport encryption to `Auto` or `Force` according to client support
  and institutional policy.
- Configure SMB signing according to institutional security policy; do not
  disable it merely for speed without a documented risk decision.
- Restrict DSM firewall rules so SMB is reachable only from approved LAN and
  VPN address ranges.

### 5.3 Remote access

Use the institutional VPN, then connect to the NAS:

```text
Windows: \\NAS-HOST\SHARE-NAME
macOS:   smb://NAS-HOST/SHARE-NAME
Linux:   smb://NAS-HOST/SHARE-NAME
```

Do not expose TCP port 445 directly to the public Internet.

### 5.4 NFS export

In DSM shared-folder NFS permissions:

- Allow only A2, C1, and specifically approved managed Linux clients.
- Use the narrowest host/IP or subnet rules possible.
- Use `No mapping` only after numeric UID/GID consistency is verified.
- Do not use `Map all users to admin` for a multi-user permission model.
- Prefer synchronous writes for mission-critical data unless the performance
  tradeoff is explicitly accepted and protected by other controls.
- Do not provide NFS directly to unmanaged external laptops.

---

## 6. DSM ACL design

Apply the coarse POSIX setup first. Apply DSM ACLs second. After DSM ACLs are in
production, do not run the script with `--repair-permissions` unless the effect
has been reviewed and a rollback snapshot exists.

**Critical NFS limitation:** without POSIX ACL support, an OPEN-READ directory
implemented as mode `2775` or `2755` grants read/traverse through the Unix
`other` bits. That means every local account on a trusted NFS client can read
OPEN-READ content, even when that account is not a member of `nas2users`.
`nas2users` is therefore the administrative roster and SMB baseline group; it
cannot be the sole NFS read gate on this mount. Keep NFS exports and workstation
accounts tightly controlled, and use `RESTRICTED` mode `2770` for anything that
must not be readable by every local account on A2/C1.

Avoid a broad explicit **Deny/No access** entry on `nas2users` inside a project
when project members also belong to `nas2users`. A deny can override the
project-group allow. Remove unwanted inherited entries and grant only the
required principals.

### 6.1 Share root `/storagenas2`

| Principal | Access |
|---|---|
| `storage-admin` | Full control |
| `nas2users` | Read/traverse as required |
| guest/anonymous | No access |
| Everyone | No write |

Ordinary users must not be able to create new top-level folders.

### 6.2 `00_ADMIN`

| Principal | Access |
|---|---|
| `storage-admin` | Full control |
| `nas2users` | Read only to the published policy files, not identity/log data |
| others | No access |

The v2 script uses a traversable `00_ADMIN` parent and a readable `policies`
subdirectory while keeping identity, audit, operation, and migration records
administrator-only.

### 6.3 Open-read project

Example: `/storagenas2/10_PROJECTS/coral-monitoring`

| Principal | Access |
|---|---|
| `storage-admin` | Full control |
| `nas2-prj-coral-monitoring` | Modify |
| `nas2users` | Read |

POSIX mode: `root:nas2-prj-coral-monitoring 2775`

### 6.4 Restricted project

| Principal | Access |
|---|---|
| `storage-admin` | Full control |
| `nas2-prj-sensitive` | Modify |
| optional `nas2-prj-sensitive-ro` | Read |
| baseline `nas2users` | No grant |

POSIX mode: `root:nas2-prj-sensitive 2770`

### 6.5 Normal user area

Example: `/storagenas2/30_USERS/alice`

| Principal | Access |
|---|---|
| `alice` | Modify |
| `storage-admin` | Full control |
| `nas2users` | Read |

### 6.6 Private user area

| Principal | Access |
|---|---|
| named user | Modify |
| `storage-admin` | Full control |
| `nas2users` | No grant |

### 6.7 Shared collaboration area

`/storagenas2/40_SHARED/users-open`

| Principal | Access |
|---|---|
| `storage-admin` | Full control |
| `nas2users` | Modify |

POSIX mode: `root:nas2users 2770`. Linux writers must use `umask 0002`.

### 6.8 DataAPIs

`/storagenas2/dataapis-live` and `/storagenas2/dataapis-backups`

| Principal | Access |
|---|---|
| `storage-admin` | Full control |
| verified DataAPIs service account | Required service access |
| `dataapis` | Only required operator/service access |
| `nas2users` | No grant |

Do not recursively change ownership until the service identity, containers,
scheduled jobs, and backup jobs have been verified.

### 6.9 Legacy data

During migration, the v2 script keeps the raw destination administrator-only.
After successful verification it publishes the raw directory as read-only to
ordinary users while root retains write authority for controlled curation.

---

## 7. Install and validate the v2 script

On A2:

```bash
cd ~/admin
install -m 0750 \
  /path/to/migrate_storagenas1_to_storagenas2_unified_v2.sh \
  ./migrate_storagenas1_to_storagenas2_unified_v2.sh

bash -n ./migrate_storagenas1_to_storagenas2_unified_v2.sh
./migrate_storagenas1_to_storagenas2_unified_v2.sh --version
./migrate_storagenas1_to_storagenas2_unified_v2.sh --help
sha256sum ./migrate_storagenas1_to_storagenas2_unified_v2.sh
```

Running the script with no arguments only displays help and changes nothing.

---

## 8. Record the DSM-assigned core GIDs

On the Synology through SSH:

```bash
getent group storage-admin
getent group nas2users
getent group dataapis
```

On both A2 and C1, check for conflicts before setup:

```bash
getent group storage-admin
getent group nas2users
getent group dataapis

getent group | sort -t: -k3,3n | tail -50
id ptr226
```

Set shell variables using the **actual DSM GIDs**, not example values:

```bash
ADMIN_GID=DSM_STORAGE_ADMIN_GID
USERS_GID=DSM_NAS2USERS_GID
DATAAPIS_GID=DSM_DATAAPIS_GID
```

---

## 9. Preflight and initial setup on A2

### 9.1 Preflight

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --preflight \
  --admin-user ptr226 \
  --admin-gid "$ADMIN_GID" \
  --users-gid "$USERS_GID" \
  --dataapis-gid "$DATAAPIS_GID"
```

If the root write test proved DSM denies ordinary-user writes even though the
mode displays `0777`, add the documented override:

```bash
  --allow-insecure-root
```

Do not use that override merely to bypass an unresolved write exposure.

### 9.2 Initial setup

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --setup-only \
  --admin-user ptr226 \
  --admin-gid "$ADMIN_GID" \
  --users-gid "$USERS_GID" \
  --dataapis-gid "$DATAAPIS_GID"
```

Add `--allow-insecure-root` only under the documented DSM-ACL condition above.

The first v2 setup:

- creates/verifies exact core GIDs;
- adds `ptr226` to `storage-admin`, `nas2users`, and `dataapis`;
- creates the managed structure;
- writes policy, identity registries, operation logs, and DSM ACL plans;
- applies only top-level/coarse permissions;
- preserves current DataAPIs ownership and sets top-level mode `2750`;
- writes a marker so later setup runs do not rewrite existing directory modes
  unless `--repair-permissions` is explicit.

Log out and back in before testing new supplementary groups:

```bash
id ptr226
```

---

## 10. Synchronize C1

Copy the same verified script to C1 and run:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --sync-groups-only \
  --admin-user ptr226 \
  --admin-gid "$ADMIN_GID" \
  --users-gid "$USERS_GID" \
  --dataapis-gid "$DATAAPIS_GID"
```

Then verify on both A2 and C1:

```bash
getent group storage-admin
getent group nas2users
getent group dataapis
id ptr226
```

The group name and numeric GID must be identical on both systems and DSM.

---

## 11. Administer NAS users

### 11.1 Workstation/NFS user

The user must already exist locally with the expected UID.

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --add-nas-user mk7641
```

Create a normal readable retained-data area:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --create-user mk7641
```

Create a private area instead:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --create-user mk7641 \
  --private-user
```

Apply the matching DSM ACL if the folder will also be accessed over SMB.

### 11.2 SMB-only user

Do not run `--create-user` for an account that does not exist on the workstation.
Create the local DSM user and assign DSM group/ACL access. Prefer project/shared
areas for SMB-only collaboration. DSM user homes can be considered for personal
SMB storage if enabled and governed separately.

### 11.3 Remove workstation baseline membership

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --remove-nas-user USERNAME
```

This changes only the current workstation. Repeat on every NFS client where the
user exists, and separately update DSM membership.

---

## 12. Administer projects

### 12.1 Create the DSM group first

In DSM create:

```text
nas2-prj-regclim-wrf
```

Add SMB-only project members there, then query its GID:

```bash
getent group nas2-prj-regclim-wrf
```

### 12.2 Create the project on A2

```bash
PROJECT_GID=DSM_PROJECT_GID

sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --create-project regclim-wrf \
  --owner ptr226 \
  --members mk7641,ak11283 \
  --smb-members external-collaborator \
  --project-gid "$PROJECT_GID"
```

For a restricted project:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --create-project sensitive-study \
  --owner ptr226 \
  --members mk7641 \
  --smb-members external-collaborator \
  --project-gid "$PROJECT_GID" \
  --restricted-project
```

The `--smb-members` option records the intended users in the DSM ACL plan. It
does not create DSM accounts or change DSM group membership.

### 12.3 Synchronize the project group on C1

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --sync-project-group regclim-wrf \
  --project-gid "$PROJECT_GID" \
  --members mk7641,ak11283
```

### 12.4 Add or remove a local project member

Run on every NFS workstation where the user exists:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --add-project-member regclim-wrf USERNAME

sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --remove-project-member regclim-wrf USERNAME
```

Update DSM project-group membership separately for SMB access.

### 12.5 Linux writer umask

Before collaborative writes:

```bash
source /storagenas2/00_ADMIN/policies/nas2-project-umask.sh
```

This sets `umask 0002`. Put the same `umask 0002` explicitly in cron jobs,
notebooks, services, containers, and batch jobs that write collaborative data.

---

## 13. DataAPIs change procedure

Do not adopt DataAPIs ownership merely because the directory currently shows
`ajd11:ajd11`.

### 13.1 Identify the real service identity

Inspect processes, services, containers, timers, cron, and backup jobs:

```bash
ps -eo user,group,pid,ppid,cmd | grep -i dataapi
systemctl list-units --type=service | grep -i dataapi
systemctl list-timers --all | grep -i dataapi
sudo crontab -l
sudo -u ajd11 crontab -l
find /storagenas2/dataapis-live /storagenas2/dataapis-backups \
  -maxdepth 2 -printf '%u:%g %m %p\n' | head -200
```

Also inspect container volume mappings and application configuration.

### 13.2 Conservative default

The normal v2 setup preserves `ajd11:ajd11` and changes only the top-level mode
to `2750`. No recursive ownership change occurs.

### 13.3 Explicit adoption after approval

If `ajd11` is confirmed as the service account:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --setup-only \
  --admin-user ptr226 \
  --admin-gid "$ADMIN_GID" \
  --users-gid "$USERS_GID" \
  --dataapis-gid "$DATAAPIS_GID" \
  --dataapis-service-user ajd11 \
  --adopt-dataapis
```

This changes only the two top-level directories to `ajd11:dataapis` mode `2750`.
Add `--dataapis-group-write` only if the `dataapis` operator group truly needs
write access, producing mode `2770`.

Afterward, test every DataAPIs write, backup, restore, restart, and scheduled job.

---

## 14. Migration procedure

### 14.1 Freeze NAS1 writes

Coordinate a maintenance window. Stop jobs and user writes to NAS1. Verify the
mount:

```bash
findmnt -T /storagenas1 -o TARGET,SOURCE,FSTYPE,OPTIONS
```

A real `--run` refuses a read-write source unless `--allow-rw-source` is used.
The override is only for a controlled exception and weakens verification.

### 14.2 Audit

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh --audit
```

Exit code `2` means critical audit findings exist.

### 14.3 Dry run

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh --dry-run
```

Review the generated rsync log, source inventory, space estimate, mount details,
and any permission warnings under:

```text
/storagenas2/00_ADMIN/migrations/storagenas1/<RUN_ID>/
```

The script includes the source top-level `#recycle` by default. Exclude it only
after a documented retention decision:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --dry-run \
  --skip-recycle
```

### 14.4 Real run with content verification

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --run \
  --checksums
```

The script:

- probes destination ownership, mode, timestamps, hard links, and symlinks;
- estimates transfer size and requires free-space headroom;
- preserves regular archive metadata, numeric IDs, hard links, and sparse files;
- keeps partial data administrator-only;
- never deletes destination data during copy;
- performs a post-copy rsync comparison;
- compares source and destination SHA-256 manifests when requested;
- publishes the raw legacy tree only after verification succeeds.

Do not add `--preserve-posix-acls` on the current mount; the capability probe is
expected to fail because `setfacl` is unsupported. Use DSM ACLs server-side.
Use `--preserve-xattrs` only after a successful preflight and a confirmed need.

### 14.5 Independent verification

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh \
  --verify-only \
  --verify-checksum
```

Do not delete or repurpose NAS1 until the verification reports are reviewed and
formally accepted.

---

## 15. Access validation matrix

Create five test identities where applicable:

1. `storage-admin` member.
2. Project member in `nas2-prj-test`.
3. Approved `nas2users` member who is not in the project.
4. SMB-only external collaborator in the project.
5. Unauthorized/non-NAS account.

Test from SMB, A2 NFS, and C1 NFS:

| Path/class | Admin | Project member | NAS nonmember | SMB-only member | Unauthorized |
|---|---|---|---|---|---|
| NAS2 root create | controlled | deny | deny | deny | deny |
| open project read | allow | allow | allow | allow | deny |
| open project create/modify/delete | allow | allow | deny | allow | deny |
| restricted project read | allow | allow | deny | allow if member | deny |
| private user area | allow | owner only | deny | owner only | deny |
| `users-open` write | allow | allow if nas2users | allow | allow if nas2users | deny |
| DataAPIs | allow | deny | deny | deny | deny |
| legacy after verification | allow | read | read | read if granted | deny |

For every writable location test:

```text
list, open/read, create, overwrite, rename, delete, create subdirectory
```

Do not accept an ACL based only on a successful directory listing.

---

## 16. Registry and routine administration

The v2 script records identity and provisioning data under:

```text
/storagenas2/00_ADMIN/identity/gid-registry.tsv
/storagenas2/00_ADMIN/identity/projects.tsv
/storagenas2/00_ADMIN/identity/users.tsv
```

It writes pending DSM ACL plans under:

```text
/storagenas2/00_ADMIN/smb-acl-plans/
```

Monthly or after every access change:

```bash
sudo ./migrate_storagenas1_to_storagenas2_unified_v2.sh --audit
```

Quarterly:

- reconcile DSM group membership with project owners;
- compare core/project GIDs on DSM, A2, and C1;
- review dormant SMB accounts;
- review DSM firewall and VPN ranges;
- test a sample open, restricted, private, system, and legacy path;
- confirm snapshots and backups are restorable.

---

## 17. Offboarding

For a departing user:

1. Disable the DSM local account immediately.
2. Remove DSM project-group membership.
3. Remove local A2/C1 group membership where the user exists.
4. Stop scheduled jobs, API tokens, SSH keys, and service credentials.
5. Transfer project stewardship and document the new owner.
6. Move personal retained data to archive or a successor under an approved
   retention decision.
7. Do not recursively rewrite ownership until an inventory and rollback plan
   have been approved.
8. Retain audit evidence of the access removal.

---

## 18. Stop conditions

Stop and investigate rather than overriding when:

- an ordinary account can create files directly under `/storagenas2`;
- the same group name has different GIDs on DSM, A2, or C1;
- A2 and C1 report different UIDs for the same owner-based NFS user;
- the source is changing during migration;
- destination root-squash prevents numeric ownership preservation;
- free-space or inode checks fail;
- DataAPIs service identity is unconfirmed;
- a DSM ACL change causes different results over SMB and NFS;
- verification reports any source/destination difference;
- the SHA-256 manifests differ;
- a permission repair would affect a production DSM ACL tree without a snapshot.

In a mixed SMB/NFS design, protocol-by-protocol testing is part of the access
control, not an optional final check.
