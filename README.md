# OCI FOCUS Cost Report Ingestion Pipeline

Automated ingestion of Oracle Cloud Infrastructure (OCI) FOCUS Cost and Usage Reports into Autonomous Database (ADB), with compartment hierarchy enrichment, scheduled incremental loading, and a materialized view optimized for Oracle Analytics Cloud (OAC).

---

## Architecture Overview

```text
OCI Object Storage (FOCUS Reports bucket — bling namespace)
        |
        |  DBMS_CLOUD.LIST_OBJECTS + COPY_DATA
        v
ADB — OCI_COST_DATA_NEW          (raw FOCUS cost data)
ADB — LOADED_FILES_LOG           (file-level deduplication)
ADB — LOAD_FAILURES_LOG          (failed file tracking)
        |
        |  LEFT JOIN on oci_CompartmentId
        v
ADB — ADB_OCI_COMPARTMENTS       (compartment hierarchy — name, path, level)
ADB — ADB_OCI_COMPARTMENTS_LOG   (compartment refresh run log)
        |
        |  DBMS_MVIEW.REFRESH (complete, every 4 hours)
        v
ADB — OCI_DAILY_COST_MV          (daily aggregated cost view for OAC)
        |
        v
Oracle Analytics Cloud (OAC)
```

---

## How the Pipeline Works

### 1. Initial backfill

A one-time PL/SQL block reads `.csv.gz` FOCUS report files from Object Storage for the last 90 days and loads them into `OCI_COST_DATA_NEW`. Files already present in `LOADED_FILES_LOG` are skipped.

### 2. Compartment hierarchy load

A stored procedure `REFRESH_OCI_COMPARTMENTS` calls the OCI Identity API via `DBMS_CLOUD_OCI_ID_IDENTITY` to fetch all active compartments, upserts them into `ADB_OCI_COMPARTMENTS`, and computes `HIERARCHY_LEVEL` and `HIERARCHY_PATH` for each compartment using a recursive CTE. Stale entries are soft-deleted.

### 3. Materialized view

`OCI_DAILY_COST_MV` aggregates `OCI_COST_DATA_NEW` by day, service, region, compartment, and charge type. It joins to `ADB_OCI_COMPARTMENTS` to enrich each row with the full compartment path. This view is the primary dataset for OAC dashboards.

### 4. Differential load

`LOAD_OCI_COST_INCREMENTAL_1D` runs every hour via `DBMS_SCHEDULER`. It checks for files modified in the last 24 hours that are not yet in `LOADED_FILES_LOG`.

### 5. Idempotency

A file is considered processed only after it is successfully loaded and inserted into `LOADED_FILES_LOG`. This prevents duplicate loads across runs.

### 6. Failure handling

If a file fails to load, the filename, error message, and timestamp are written to `LOAD_FAILURES_LOG`. Failed files remain visible for debugging and can be retried.

---

## Prerequisites

### 1. OCI IAM Policy

ADB uses `OCI$RESOURCE_PRINCIPAL` to read from the OCI Usage Report bucket (owned by the OCI usage-report tenancy). Create a cross-tenancy policy in your tenancy:

```hcl
define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq

endorse any-user to read objects in tenancy usage-report
  where request.resource.compartment.id = '<YOUR_ADB_COMPARTMENT_OCID>'
```

To scope it to a specific ADB instance:

```hcl
endorse any-user to read objects in tenancy usage-report
  where request.resource.id = '<YOUR_ADB_INSTANCE_OCID>'
```

### 2. ADB Resource Principal

Resource Principal must be enabled on the Autonomous Database instance.

Verify:

```sql
SELECT owner, credential_name
FROM   dba_credentials
WHERE  credential_name = 'OCI$RESOURCE_PRINCIPAL'
  AND  owner = 'ADMIN';
```

If no row is returned, enable it:

```sql
EXEC DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL();
```

---

## Database Objects

### Cost data

| Object | Type | Purpose |
|---|---|---|
| `OCI_COST_DATA_NEW` | Table | Raw FOCUS cost rows loaded from Object Storage |
| `LOADED_FILES_LOG` | Table | Tracks successfully loaded files (deduplication key) |
| `LOAD_FAILURES_LOG` | Table | Records files that failed to load with error details |
| `LOAD_OCI_COST_FILES` | Procedure | Core loader; accepts `p_days_back` parameter |
| `LOAD_OCI_COST_BACKFILL_90D` | Procedure | Wrapper — calls loader with 90 days |
| `LOAD_OCI_COST_INCREMENTAL_1D` | Procedure | Wrapper — calls loader with 1 day |
| `JOB_LOAD_OCI_COSTS_HOURLY` | Scheduler Job | Runs `LOAD_OCI_COST_INCREMENTAL_1D` every hour |

### Compartments

| Object | Type | Purpose |
|---|---|---|
| `ADB_OCI_COMPARTMENTS` | Table | Compartment metadata with hierarchy path and level |
| `ADB_OCI_COMPARTMENTS_LOG` | Table | Run log for each compartment refresh execution |
| `REFRESH_OCI_COMPARTMENTS` | Procedure | Fetches compartments from OCI Identity API and upserts |
| `JOB_REFRESH_OCI_COMPARTMENTS` | Scheduler Job | Runs `REFRESH_OCI_COMPARTMENTS` every hour |

### Materialized view

| Object | Type | Purpose |
|---|---|---|
| `OCI_DAILY_COST_MV` | Materialized View | Daily cost aggregation enriched with compartment path; OAC source |
| `JOB_REFRESH_OCI_DAILY_COST_MV` | Scheduler Job | Complete refresh of `OCI_DAILY_COST_MV` every 4 hours |

---

## Deployment Steps

Run the master SQL script in order. Each phase includes validation queries — review them before proceeding to the next phase.

### Phase 1 — Cleanup

Drops all existing objects (jobs, MV, tables, procedures, `COPY$` tables). Safe to re-run. Verify all counts return `0` before proceeding.

### Phase 2 — Compartments

Creates `ADB_OCI_COMPARTMENTS` and `ADB_OCI_COMPARTMENTS_LOG`, deploys `REFRESH_OCI_COMPARTMENTS`, and runs it once.

**Must complete successfully before the MV can be created.** Validate that `total_compartments > 0` and `missing_path = 0`.

### Phase 3 — Cost tables and procedures

Creates `OCI_COST_DATA_NEW`, `LOADED_FILES_LOG`, `LOAD_FAILURES_LOG`, and all three load procedures.

### Phase 4 — 1-day test load

Loads only the last 1 day of files. Validates row counts, date ranges, column parsing, and compartment join coverage. **Do not proceed to Phase 5 until this looks correct.**

### Phase 5 — 90-day backfill

Runs `LOAD_OCI_COST_BACKFILL_90D`. Files already loaded in Phase 4 are automatically skipped via `LOADED_FILES_LOG`. Validate date range spans ~90 days and failure count is acceptable.

### Phase 6 — Materialized view

Creates `OCI_DAILY_COST_MV`. **Requires both `ADB_OCI_COMPARTMENTS` and `OCI_COST_DATA_NEW` to be populated first.**

Validate with the cross-check query — effective cost totals in the MV and raw table must match. Check `missing_path = 0` before connecting OAC.

### Phase 7 — Schedule jobs

Creates all three scheduler jobs. Only run after Phase 6 validation passes.

| Job | Runs | Action |
|---|---|---|
| `JOB_LOAD_OCI_COSTS_HOURLY` | Every 1 hour | Incremental cost file load |
| `JOB_REFRESH_OCI_COMPARTMENTS` | Every 1 hour | Compartment upsert and hierarchy rebuild |
| `JOB_REFRESH_OCI_DAILY_COST_MV` | Every 4 hours | Complete MV refresh |

### Phase 8 — Final sanity check

Confirm all jobs are `ENABLED`, row counts are non-zero, and `FAILED_FILES` is at an acceptable level.

---

## Key Validation Queries

### MV vs raw table cost cross-check

```sql
SELECT 'RAW_TABLE' AS source, ROUND(SUM(EffectiveCost),       2) AS total_effective_cost FROM oci_cost_data_new
UNION ALL
SELECT 'MV'        AS source, ROUND(SUM(DAILY_EFFECTIVECOST), 2) AS total_effective_cost FROM ADMIN.OCI_DAILY_COST_MV;
```

### Compartment join coverage (should be 0 or near 0)

```sql
SELECT COUNT(*) AS cost_rows_with_no_compartment_match
FROM   oci_cost_data_new c
WHERE  NOT EXISTS (
         SELECT 1 FROM adb_oci_compartments cp
         WHERE  cp.compartment_ocid = c.oci_CompartmentId
       )
  AND  c.oci_CompartmentId IS NOT NULL;
```

### MV freshness

```sql
SELECT mview_name, last_refresh_date, staleness, compile_state
FROM   user_mviews
WHERE  mview_name = 'OCI_DAILY_COST_MV';
```

### Scheduler job health

```sql
SELECT job_name, enabled, state, last_start_date, last_run_duration
FROM   user_scheduler_jobs
WHERE  job_name IN (
         'JOB_LOAD_OCI_COSTS_HOURLY',
         'JOB_REFRESH_OCI_COMPARTMENTS',
         'JOB_REFRESH_OCI_DAILY_COST_MV'
       );
```

### Job run history

```sql
SELECT log_date, job_name, status, error#, run_duration, additional_info
FROM   user_scheduler_job_run_details
WHERE  job_name IN (
         'JOB_LOAD_OCI_COSTS_HOURLY',
         'JOB_REFRESH_OCI_COMPARTMENTS',
         'JOB_REFRESH_OCI_DAILY_COST_MV'
       )
ORDER  BY log_date DESC
FETCH  FIRST 30 ROWS ONLY;
```

### Files not yet loaded

```sql
SELECT COUNT(*) AS files_not_yet_loaded
FROM   DBMS_CLOUD.LIST_OBJECTS(
         'OCI$RESOURCE_PRINCIPAL',
         'https://objectstorage.us-ashburn-1.oraclecloud.com/n/bling/b/<YOUR_TENANCY_OCID>/o/FOCUS%20Reports/'
       ) o
WHERE  o.object_name LIKE '%.csv.gz'
  AND  NOT EXISTS (SELECT 1 FROM loaded_files_log f WHERE f.filename = o.object_name);
```

### Failed loads

```sql
SELECT filename, error_message, error_time
FROM   load_failures_log
ORDER  BY error_time DESC;
```

### Compartment refresh log

```sql
SELECT status, rows_loaded, run_start_ts, run_end_ts, error_message
FROM   adb_oci_compartments_log
ORDER  BY run_id DESC
FETCH  FIRST 10 ROWS ONLY;
```

---

## Job Control

### Stop a running job

```sql
BEGIN DBMS_SCHEDULER.STOP_JOB('JOB_LOAD_OCI_COSTS_HOURLY', TRUE); END;
/
BEGIN DBMS_SCHEDULER.STOP_JOB('JOB_REFRESH_OCI_COMPARTMENTS', TRUE); END;
/
BEGIN DBMS_SCHEDULER.STOP_JOB('JOB_REFRESH_OCI_DAILY_COST_MV', TRUE); END;
/
```

### Disable / enable hourly cost job

```sql
BEGIN DBMS_SCHEDULER.DISABLE('JOB_LOAD_OCI_COSTS_HOURLY'); END;
/
BEGIN DBMS_SCHEDULER.ENABLE('JOB_LOAD_OCI_COSTS_HOURLY'); END;
/
```

### Manually trigger MV refresh

```sql
BEGIN DBMS_MVIEW.REFRESH('ADMIN.OCI_DAILY_COST_MV', 'C'); END;
/
```

---

## File Format Used by `DBMS_CLOUD.COPY_DATA`

| Property | Value |
|---|---|
| Source format | CSV |
| Compression | GZIP |
| Delimiter | `,` |
| Skip headers | 1 |
| Quote character | `"` |
| Timestamp format | `YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"` |
| Ignore missing columns | true |
| Trim spaces | `lrtrim` |
| Blank as null | true |
| Conversion errors | `store_null` |
| Reject limit | 100000 |

---

## Important Notes

- `LOADED_FILES_LOG` is the idempotency control table. Do not truncate it unless you intend to reload all files from scratch.
- `ADB_OCI_COMPARTMENTS` must be populated before `OCI_DAILY_COST_MV` is created. The MV DDL references this table directly.
- The MV uses `REFRESH COMPLETE ON DEMAND`. It does not support fast (incremental) refresh due to the aggregation and outer join.
- The hourly cost loader checks the last 24 hours of object modifications. This intentionally overlaps day boundaries to avoid missing files.
- `SQLERRM` cannot be used directly inside a SQL `UPDATE` statement in Oracle — it must be captured into a PL/SQL variable first before being passed to a DML statement.
- Update the Object Storage URI in the script to match your namespace and tenancy OCID before deploying.
- Run the 90-day backfill only once. After that, the hourly job handles normal ingestion.
- A 1-day test load (Phase 4) is strongly recommended before running the full 90-day backfill to validate column alignment and compartment join coverage early.

---

## Recommended Run Order

1. Run cleanup (Phase 1) — confirm all counts are 0
2. Create compartments and run once (Phase 2) — confirm rows loaded, hierarchy built
3. Create cost tables and procedures (Phase 3)
4. Run 1-day test load and validate (Phase 4) — confirm data looks correct
5. Run 90-day backfill (Phase 5) — confirm date range and row counts
6. Create and validate materialized view (Phase 6) — confirm cost totals match raw table
7. Schedule all three jobs (Phase 7)
8. Run final sanity check (Phase 8)
