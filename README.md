# Mubadala ACCESS Data Governance

This repository contains the policies, standards, procedures, runbooks, and reference material used to manage, store, transfer, retain, archive, and protect data within the Mubadala ACCESS environment. The repository is intended to provide a single, version-controlled source of truth for data owners, data stewards, system administrators, researchers, engineers, and other users who work with ACCESS data.

## Objectives

The documentation in this repository is designed to:

- keep retained data in approved, managed storage locations;
- prevent workstation root and home filesystems from being used as bulk storage;
- define consistent structures for projects, datasets, shared data, archives, and legacy data;
- preserve raw and migrated data until ownership, purpose, retention, and final placement are confirmed;
- make data movement verifiable, repeatable, and auditable;
- document ownership, access, retention, lineage, and operational responsibilities; and
- reduce the risk of incomplete writes, service disruption, filesystem exhaustion, corruption, or data loss.

## Repository Scope

This repository may include documentation for:

- storage policies and approved storage locations;
- project and dataset directory standards;
- file and directory naming conventions;
- data ownership and stewardship;
- data classification and handling requirements;
- access-control and permission procedures;
- data migration and transfer runbooks;
- validation, checksums, inventories, and manifests;
- backup, retention, archival, and deletion procedures;
- legacy-data review and curation;
- incident response and recovery guidance; and
- templates for project, dataset, migration, and governance documentation.

## Repository Structure

```text
mubadala-access-data-governance/
├── README.md
├── policies/
│   ├── data-storage-policy.md
│   ├── data-retention-policy.md
│   ├── access-control-policy.md
│   └── data-classification-policy.md
├── standards/
│   ├── directory-structure.md
│   ├── naming-conventions.md
│   ├── metadata-requirements.md
│   └── checksum-and-validation.md
├── procedures/
│   ├── storing-new-data.md
│   ├── transferring-data.md
│   ├── archiving-data.md
│   └── deleting-data.md
├── runbooks/
│   ├── nas-migration-runbook.md
│   ├── storage-capacity-response.md
│   └── transfer-verification.md
├── environments/
│   ├── workstation-storage-guide.md
│   └── storage-mounts.md
├── templates/
│   ├── project-readme-template.md
│   ├── dataset-readme-template.md
│   ├── migration-plan-template.md
│   └── data-inventory-template.md
├── reports/
│   └── README.md
└── decisions/
    └── README.md
```

The exact structure may evolve, but documents should remain easy to locate and should not be duplicated across several folders without a clear reason.

## Core Storage Principles

### 1. Use managed storage for retained data

Data that must be preserved must be stored in an approved long-term storage location. Workstation root filesystems and user home directories must not be used for large datasets, archives, backups, model checkpoints, instrument collections, or long-term project outputs.

### 2. Use scratch storage only for temporary work

Scratch storage is appropriate for intermediate processing, reproducible caches, temporary transformations, and data that can be regenerated. Scratch storage is not authoritative and must not be the only location of retained data.

### 3. Preserve raw and legacy data

Raw source data and migrated legacy data should remain unchanged until validation, ownership review, retention review, and final placement are complete. Reorganization or deletion must be authorized and documented.

### 4. Separate projects, datasets, shared data, and archives

Data should be placed according to its purpose:

| Data type | Intended location or category |
|---|---|
| Active project data | Managed project area |
| Canonical shared datasets | Managed dataset area |
| User-owned retained data | Managed user area |
| Collaborative data | Managed shared area |
| Completed or frozen data | Archive area |
| Unreviewed migrated data | Legacy area |
| Regenerable working data | Scratch storage |

### 5. Verify before deleting

A source copy must not be removed until the destination has been verified. Verification may include a repeat `rsync` dry run, checksums, file counts, byte totals, manifests, and application-level validation.

### 6. Document ownership and purpose

Every managed project or dataset should identify its owner or steward, purpose, source, sensitivity, retention requirements, access restrictions, current version, and contact information.

## Current ACCESS Storage Model

Where applicable to the documented ACCESS workstation environment, the storage roles are:

```text
NAS2          Authoritative long-term storage
NAS1          Read-only legacy storage
/fastscratch  Temporary working storage
/fastscratch2 Temporary working storage
/home         Source code, configuration, and small files only
/             Operating system and services only
```

Environment-specific mount points, restrictions, and procedures must be maintained in the relevant document under `environments/`, `policies/`, or `runbooks/`.

## Project and Dataset Documentation

Each project or dataset should contain a `README.md` that records, at minimum:

1. name and description;
2. owner or data steward;
3. source and collection or creation date;
4. storage location;
5. current version and version history;
6. file formats and approximate size;
7. processing history and provenance;
8. access and usage restrictions;
9. retention or archival requirements;
10. validation or checksum information; and
11. support or contact information.

Canonical datasets should be versioned. Existing versions must not be silently overwritten; a new version should be created, validated, and promoted through a documented process.

## Naming Conventions

Use names that are descriptive, stable, and easy to process in scripts.

Recommended:

```text
ocean-temperature-model
coral-images-v1
telemetry-run-2026-07
cruise-2026-atlantic
```

Avoid:

```text
new
misc
data
results
final
final2
latest-copy
```

General rules:

- use lowercase names with hyphens where practical;
- avoid spaces and unnecessary special characters;
- use ISO dates in `YYYY-MM-DD` format;
- include versions where versioning is required; and
- do not place credentials, secrets, or sensitive personal information in names.

### Expected transfer ranges

For a transfer over a shared **1 Gbps network path**, the absolute line-rate ceiling is approximately **125 MB/s** before protocol overhead. A well-performing sustained transfer will normally remain below that ceiling.

| Workload | Reasonable sustained planning range | Approximate data per hour | Approximate time for 1 TB |
|---|---:|---:|---:|
| Large sequential files under favorable conditions | **80-110 MB/s** | **288-396 GB/hour** | **2.5-3.5 hours** |
| Mixed research files and normal shared usage | **40-80 MB/s** | **144-288 GB/hour** | **3.5-7 hours** |
| Very large collections of small files | **10-40 MB/s** | **36-144 GB/hour** | **7-28 hours** |
| Congested network or busy destination storage | **Below 30 MB/s** | **Below 108 GB/hour** | **More than 9 hours** |

These ranges describe transfer time only. Inventory generation, checksum calculation, verification, retries, permissions review, and final promotion can add significant time to the complete migration window.

### Quick planning table

| Sustained rate | Data per hour | Data per 24 hours | Approximate time for 1 TB |
|---:|---:|---:|---:|
| **100 MB/s** | **360 GB** | **8.64 TB** | **2 hours 46 minutes** |
| **80 MB/s** | **288 GB** | **6.91 TB** | **3 hours 28 minutes** |
| **50 MB/s** | **180 GB** | **4.32 TB** | **5 hours 33 minutes** |
| **25 MB/s** | **90 GB** | **2.16 TB** | **11 hours 6 minutes** |
| **10 MB/s** | **36 GB** | **0.86 TB** | **27 hours 46 minutes** |

The table uses decimal units: **1 TB = 1,000 GB** and **1 MB = 1,000,000 bytes**. A simple estimate is:

```text
estimated seconds = total size in MB / sustained MB/s
```

Add a planning margin of at least **20-30%** for normal variability. Use a larger margin for millions of small files, heavily shared storage, or transfers that require complete checksum verification.

### Recommended transfer windows

Network and storage contention are usually highest while researchers, services, backups, and analysis jobs are active. Until local monitoring establishes more precise site-specific peak periods, use the following scheduling assumptions:

| Period | General expectation | Recommended use |
|---|---|---|
| Weekday working hours, approximately **08:00-18:00** | Highest contention and most variable throughput | Small transfers, urgent work, or transfers that can tolerate slowdown |
| Early evening, approximately **18:00-22:00** | Usage often begins to decline | Medium transfers and resumable jobs |
| Overnight, approximately **22:00-07:00** | Usually the most stable weekday window | Large migrations, archive transfers, and validation runs |
| Weekends and approved maintenance windows | Often lower interactive demand, but backups may still run | Multi-terabyte transfers after checking for scheduled maintenance or backup activity |

These time windows are initial operational guidance, not proof of actual peak usage. Administrators should review network and NAS monitoring data periodically and update the documented preferred windows. Researchers should also check whether backup, replication, maintenance, or other large migration jobs are scheduled during the proposed window.

### How to improve transfer speed without hardware changes

Researchers can often improve effective throughput by changing how and when the transfer is performed:

1. **Transfer outside peak hours.** Schedule large jobs after normal working hours, overnight, or during an approved low-usage window.
2. **Run a representative pilot.** Test a sample that includes the same file types and file-size distribution as the full dataset.
3. **Avoid competing transfers.** Do not start several large migrations to the same NAS volume at the same time unless coordinated by an administrator.
4. **Use limited parallelism.** One transfer stream may underuse the path, but too many streams can reduce total performance. Start with one job and increase cautiously, generally to no more than two to four coordinated streams after testing.
5. **Handle small files efficiently.** Millions of small files create metadata overhead. Where scientifically and operationally appropriate, package a stable directory into a documented archive for transfer, preserve a manifest, and validate the archive before deleting any source files.
6. **Do not compress already compressed data.** Compression commonly provides little benefit for formats such as ZIP, JPEG, PNG, MP4, Parquet, HDF5 with compression, and compressed scientific archives, while consuming CPU time.
7. **Keep source data stable.** Avoid writing to files while they are being copied. Exclude temporary, lock, cache, and incomplete files.
8. **Use resumable transfer options.** Preserve partial files when appropriate so interrupted transfers do not always restart from zero.
9. **Separate transfer from deep verification.** First complete the controlled copy, then run the required verification. Account for both phases in the schedule rather than interpreting verification time as poor transfer performance.
10. **Confirm available destination capacity.** Low free space, quotas, snapshots, and storage cleanup activity can delay or interrupt a transfer.

### Measuring a transfer correctly

Do not use a short-lived peak rate as the expected speed for the entire migration. Record both sustained average throughput and peak throughput, and calculate performance over a meaningful interval.

## Safe Transfer Pattern

A typical retained-data workflow is:

1. prepare or process data in an approved working location;
2. validate that expected outputs exist and incomplete files are excluded;
3. copy into a temporary or `.partial` destination;
4. verify file counts, sizes, metadata, and checksums where appropriate;
5. rename or promote the verified destination atomically where possible;
6. record the migration or transfer outcome; and
7. remove the source only after verification and authorization.

Example:

```bash
rsync -aH --info=progress2 \
  /path/to/source/ \
  /path/to/destination.partial/

rsync -aH --dry-run --itemize-changes \
  /path/to/source/ \
  /path/to/destination.partial/

mv /path/to/destination.partial /path/to/destination
```

Commands must be reviewed for the relevant environment before use. Destructive options should not be added unless the deletion behavior is understood, approved, and recoverable.

## Document Standards

All governance documents should:

- use Markdown;
- have a clear title and purpose;
- identify the intended audience;
- state the document owner;
- include an effective or last-reviewed date;
- distinguish mandatory requirements from recommendations;
- include examples where they reduce ambiguity;
- link to related policies, standards, procedures, and runbooks; and
- avoid embedding passwords, tokens, credentials, or unnecessary sensitive data.

Recommended document header:

```markdown
# Document Title

- **Owner:** Team or role
- **Status:** Draft | Approved | Superseded
- **Effective date:** YYYY-MM-DD
- **Last reviewed:** YYYY-MM-DD
- **Review cycle:** Annual or as required
```

## Making Changes

Changes should be made through a pull request so they can be reviewed for technical accuracy, operational impact, security, and consistency with existing policy.

A pull request should explain:

- what is changing;
- why the change is needed;
- which systems or users are affected;
- whether migration or communication is required; and
- which related documents must also be updated.

Urgent operational changes should be documented retrospectively as soon as the immediate risk has been controlled.

## Governance and Exceptions

Exceptions to an approved storage or data-handling policy must be documented and approved before implementation whenever possible. An exception request should include:

- business or technical justification;
- data owner;
- affected systems and data;
- expected size and duration;
- security and access requirements;
- risks and compensating controls;
- expiration or review date; and
- approver.

## Getting Started

Users should begin with the applicable storage policy and environment guide, then consult the relevant procedure or runbook before moving, reorganizing, archiving, or deleting data.

Repository maintainers should keep this README aligned with the current folder structure and use it as the primary navigation page for the documentation set.
