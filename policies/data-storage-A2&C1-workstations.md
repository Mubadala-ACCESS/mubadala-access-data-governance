# Data Storage Guide for Workstation 10.224.41.15 (A2 Workstation) and (C1 Workstation) 

## 1. Purpose

This document defines how data must be stored and organized by users of A2 and C1 workstations `10.224.41.15`.

The goals are to:

1. Prevent the workstation root filesystem from filling again.
2. Reduce the risk of incomplete writes, service failures, filesystem corruption, and data loss.
3. Make Storage NAS2 the authoritative long-term storage location.
4. Keep active projects, shared datasets, user-owned data, archives, and migrated legacy data organized consistently.
5. Ensure that all users follow the same storage structure.

---

## 2. Effective immediately

### Step 1: Stop writing to Storage NAS1

Do not create, modify, or save new data under:

```text
/storagenas1
```

Storage NAS1 is full and is now designated as a read-only legacy storage system.

Existing data will remain available for reference while it is migrated and reviewed.

### Step 2: Use Storage NAS2 for all new long-term data

Storage NAS2 is mounted at:

```text
/mnt/storagenas2
```

All new data that must be retained must be saved within the approved NAS2 structure described below.

### Step 3: Do not use home directories as bulk storage

Do not store large datasets or long-term project data under:

```text
/home/<username>
```

Home directories are located on the workstation root filesystem. They share space with the operating system, system logs, temporary files, services, and user configuration.

On July 22, 2026, workstation `10.224.41.15` became unresponsive because the root filesystem was exhausted. A significant amount of space was occupied by data stored in user home directories. This created a material risk of incomplete writes, service failure, filesystem corruption, and data loss.

---

## 3. Approved NAS2 directory structure

Do not create additional top-level directories under `/mnt/storagenas2`.

Use only the following managed structure:

```text
/mnt/storagenas2/
├── 00_ADMIN/
├── 10_PROJECTS/
├── 20_DATASETS/
├── 30_USERS/
├── 40_SHARED/
├── 50_ARCHIVE/
└── 90_LEGACY/
```

| Directory | Purpose |
|---|---|
| `00_ADMIN` | Administrative policies, migration logs, reports, inventories, manifests, and checksums |
| `10_PROJECTS` | Active and curated project data |
| `20_DATASETS` | Canonical datasets shared across projects or teams |
| `30_USERS` | User-owned long-term data |
| `40_SHARED` | Shared team, laboratory, and collaborative data |
| `50_ARCHIVE` | Completed, retired, frozen, or historical curated data |
| `90_LEGACY` | Unmodified data migrated from older storage systems |

Restricted directories:

```text
/mnt/storagenas2/dataapis-backups
/mnt/storagenas2/dataapis-live
```

---

## 4. How to decide where data belongs

### Step 1: Decide whether the data is temporary or long-term

Use temporary scratch storage when the data can be regenerated:

```text
/fastscratch
/fastscratch2
```

Use NAS2 when the data must be retained:

```text
/mnt/storagenas2
```

### Step 2: Choose the correct NAS2 category

#### Active project data

```text
/mnt/storagenas2/10_PROJECTS/<project-name>/
```

Use this for active project inputs, project-specific outputs, curated files, retained results, and project documentation.

#### Canonical shared datasets

```text
/mnt/storagenas2/20_DATASETS/<dataset-name>/
```

Use this for authoritative datasets, shared reference data, official processed datasets, and validated canonical data products.

#### Individual long-term data

```text
/mnt/storagenas2/30_USERS/<username>/
```

Use this only for retained data that belongs primarily to one user and is not yet assigned to a formal project or shared dataset.

#### Shared team data

```text
/mnt/storagenas2/40_SHARED/users-open/<team-or-project>/<dataset-or-run>/
```

Use this for team working areas, laboratory shared data, collaborative outputs, and files that multiple users must access.

#### Completed or retired data

```text
/mnt/storagenas2/50_ARCHIVE/<project-or-dataset>/
```

Use this for completed projects, retired datasets, former-user data, frozen deliverables, and historical snapshots.

#### Migrated legacy data

```text
/mnt/storagenas2/90_LEGACY/storagenas1/raw/
```

The original NAS1 directory structure will be preserved during migration. Do not reorganize, rename, or delete legacy data until ownership, purpose, retention, and final placement have been confirmed.

---

## 5. Required naming rules

### Step 1: Use descriptive names

Good examples:

```text
ocean-temperature-model
coral-images-v1
telemetry-run-2026-07
cruise-2026-atlantic
```

Avoid vague names such as:

```text
new
misc
data
results
final
final2
latest-copy
```

### Step 2: Prefer lowercase names with hyphens

```text
lowercase-with-hyphens
```

Avoid spaces and special characters.

### Step 3: Use unambiguous dates

```text
YYYY-MM-DD
```

### Step 4: Do not create new NAS2 top-level folders

Do not create:

```text
/mnt/storagenas2/my-project
/mnt/storagenas2/temporary
/mnt/storagenas2/user-data
```

Place the directory inside the correct managed area.

---

## 6. Recommended project structure

```text
/mnt/storagenas2/10_PROJECTS/<project-name>/
├── README.md
├── metadata/
├── raw/
├── staging/
├── processed/
├── outputs/
├── reports/
└── archive/
```

| Directory | Purpose |
|---|---|
| `README.md` | Project description, owner, contacts, sources, and usage notes |
| `metadata` | Schemas, dictionaries, manifests, provenance, and configuration |
| `raw` | Original source data that should not be modified |
| `staging` | Intermediate validation and transformation files |
| `processed` | Cleaned or transformed data |
| `outputs` | Final products, exports, models, and deliverables |
| `reports` | Reports, figures, summaries, and documentation |
| `archive` | Superseded versions retained for reference |

---

## 7. Recommended dataset structure

```text
/mnt/storagenas2/20_DATASETS/<dataset-name>/
├── README.md
├── metadata/
├── versions/
│   ├── v1/
│   └── v2/
├── current -> versions/v2
└── checksums/
```

Each dataset README must identify:

1. Dataset name
2. Owner or steward
3. Source
4. Description
5. Collection or creation date
6. Current version
7. File formats
8. Usage restrictions
9. Processing history
10. Contact information

Do not silently overwrite an existing canonical version. Create a new version and update `current` only after validation.

---

## 8. How to save new work safely

### Step 1: Process temporary data on scratch storage

```text
/fastscratch/<username>/<job-id>/
/fastscratch2/<username>/<job-id>/
```

### Step 2: Validate the outputs

Confirm that:

- The job completed successfully
- Expected files exist
- File sizes are reasonable
- Required metadata is present
- Temporary and incomplete files are excluded

### Step 3: Copy into a partial directory

```bash
rsync -aH --info=progress2 \
  /fastscratch/<username>/<job-id>/ \
  /mnt/storagenas2/10_PROJECTS/<project-name>/staging/<job-id>.partial/
```

### Step 4: Verify the copy

```bash
rsync -aH --dry-run --itemize-changes \
  /fastscratch/<username>/<job-id>/ \
  /mnt/storagenas2/10_PROJECTS/<project-name>/staging/<job-id>.partial/
```

### Step 5: Rename the completed directory

```bash
mv \
  /mnt/storagenas2/10_PROJECTS/<project-name>/staging/<job-id>.partial \
  /mnt/storagenas2/10_PROJECTS/<project-name>/processed/<job-id>
```

### Step 6: Remove scratch data only after verification

Do not delete scratch data until the NAS2 copy has been confirmed.

---

## 9. How to access NAS2

### Step 1: Confirm that NAS2 is mounted

```bash
df -h /mnt/storagenas2
```

or:

```bash
findmnt /mnt/storagenas2
```

### Step 2: List the managed directories

```bash
ls -lah /mnt/storagenas2
```

### Step 3: Navigate to the correct area

```bash
cd /mnt/storagenas2/10_PROJECTS
cd /mnt/storagenas2/20_DATASETS
cd /mnt/storagenas2/30_USERS/$USER
cd /mnt/storagenas2/40_SHARED/users-open
```

### Step 4: Do not write to restricted directories

Do not use:

```text
/mnt/storagenas2/dataapis-backups
/mnt/storagenas2/dataapis-live
/mnt/storagenas2/00_ADMIN
```

unless explicitly authorized.

### Step 5: Report access problems

If NAS2 is unavailable, do not save retained data to `/home` as a fallback. Use `/fastscratch` or `/fastscratch2` temporarily and report the issue.

---

## 10. Correct use of home directories

Home directories may contain:

- Source code
- Scripts
- Configuration files
- Small notebooks
- Small documents
- SSH keys
- User settings
- Small temporary files

Home directories must not contain:

- Large datasets
- Model checkpoints
- Simulation outputs
- Image, video, or instrument collections
- Long-term backups
- Large Conda package caches
- Large Conda environments
- Duplicate NAS datasets
- Multi-gigabyte project outputs

---

## 11. Correct use of scratch storage

Use `/fastscratch` and `/fastscratch2` for temporary processing, intermediate outputs, model training workspaces, transformations, reproducible caches, and data that can be regenerated.

Do not treat scratch as permanent storage. Anything that must be retained must be copied to NAS2.

---

## 12. Storage policy summary

```text
NAS2          Authoritative long-term storage
NAS1          Read-only legacy storage
/fastscratch  Temporary working storage
/fastscratch2 Temporary working storage
/home         Code, configuration, and small files only
/             Operating system only
```

---

## 13. Required actions for every user

### Step 1

Stop all new writes to:

```text
/storagenas1
```

### Step 2

Review home-directory usage:

```bash
du -xhd1 "$HOME" 2>/dev/null | sort -h
```

### Step 3

Identify files larger than 1 GB:

```bash
find "$HOME" -xdev -type f -size +1G \
  -printf '%s\t%p\n' 2>/dev/null |
  sort -nr |
  numfmt --field=1 --to=iec
```

### Step 4

Classify each large file or directory as:

- Active project data
- Shared dataset
- Individual long-term data
- Shared team data
- Archive data
- Temporary scratch data
- Data that can be deleted

### Step 5

Move or copy retained data into the correct NAS2 managed directory.

### Step 6

Verify the NAS2 copy before deleting the source.

### Step 7

Update scripts, notebooks, scheduled jobs, and pipelines that currently write to:

```text
/storagenas1
/home/<username>
```

### Step 8

Use NAS2 for all future retained outputs.

---

## 14. Activities that are not permitted

Users must not:

1. Write new data to NAS1.
2. Use home directories as bulk storage.
3. Create new top-level directories under NAS2.
4. Store long-term data only on scratch disks.
5. Write into restricted application or administrative directories.
6. Reorganize legacy migration data without approval.
7. Delete source data before confirming the NAS2 copy.
8. Create undocumented copies of large datasets across multiple locations.
9. Bypass the directory structure for convenience.
10. Use the workstation root filesystem for project data.

---

## 15. Administrative requests and exceptions

Any exception must be approved before data is written outside this policy.

Requests for new project directories, canonical datasets, permission changes, shared areas, archive placement, legacy-data curation, or large migrations should include:

1. Project or dataset name
2. Owner
3. Expected size
4. Retention period
5. Required users or groups
6. Read/write requirements
