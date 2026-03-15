# OCI FOCUS Cost Report Ingestion Pipeline

Automated ingestion of Oracle Cloud Infrastructure (OCI) FOCUS Cost & Usage Reports into an Autonomous Database (ADB) using `DBMS_CLOUD`, with scheduled differential loading via `DBMS_SCHEDULER`.

---

## Architecture Overview

```
OCI Object Storage (FOCUS Reports bucket)
        │
        │  DBMS_CLOUD.LIST_OBJECTS + COPY_DATA
        ▼
Autonomous Database (ADB)
        ├── OCI_COST_DATA_NEW     ← Fact table (FOCUS schema + OCI extensions)
        └── LOADED_FILES_LOG      ← Deduplication / idempotency tracker
```

- **Initial backfill** loads all `.csv.gz` files from the last 90 days.
- **Differential load** runs hourly via a scheduler job, picking up only new files not yet logged.
- **Idempotency** is enforced via `loaded_files_log` — a file is never loaded twice.

---

## Prerequisites

### 1. OCI IAM Policy (Tenancy Admin required)

The ADB instance uses `OCI$RESOURCE_PRINCIPAL` to authenticate against the Usage Report bucket. The Usage Report bucket is owned by a special OCI tenancy (`usage-report`). The following cross-tenancy policy must be created **in your tenancy**:

```hcl
define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq

endorse any-user to read objects in tenancy usage-report
  where request.resource.compartment.id = '<YOUR_ADB_COMPARTMENT_OCID>'
```

> **Tip:** You can tighten the policy further by filtering to a specific ADB resource:
> ```hcl
> endorse any-user to read objects in tenancy usage-report
>   where request.resource.id = '<YOUR_ADB_INSTANCE_OCID>'
> ```

### 2. ADB Resource Principal

Resource Principal must be enabled on your ADB instance so that `OCI$RESOURCE_PRINCIPAL` is a valid credential.

**Verify** it is enabled by running the following as `ADMIN`:

```sql
SELECT owner, credential_name FROM dba_credentials
WHERE credential_name = 'OCI$RESOURCE_PRINCIPAL' AND owner = 'ADMIN';
```

Expected output:

```
OWNER   CREDENTIAL_NAME
-----   ---------------------
ADMIN   OCI$RESOURCE_PRINCIPAL
```

If the query returns no rows, **enable** Resource Principal:

```sql
EXEC DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL();
```

Then re-run the verification query to confirm the credential appears before proceeding.

---

## Database Objects

### Tables

#### `OCI_COST_DATA_NEW`
Stores the ingested FOCUS-compliant cost records, including OCI-specific extension columns.

| Column Group | Description |
|---|---|
| Standard FOCUS columns | `BilledCost`, `EffectiveCost`, `ListCost`, `ServiceName`, `Region`, `ResourceId`, `Tags`, etc. |
| OCI Extension columns | `oci_CompartmentId`, `oci_CompartmentName`, `oci_AttributedCost`, `oci_ReferenceNumber`, etc. |

#### `LOADED_FILES_LOG`
Tracks every successfully loaded file by name. Acts as the deduplication guard for all load operations.

| Column | Type | Description |
|---|---|---|
| `filename` | `VARCHAR2(500) PK` | Object name from the storage bucket |
| `load_date` | `TIMESTAMP` | Timestamp when the file was loaded |

---

## Usage

### Step 1 — Initial Backfill (Last 90 Days)

Run the anonymous PL/SQL block once to bootstrap the table with historical data:

```sql
DECLARE
  l_uri VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/<namespace>/b/<bucket>/o/FOCUS%20Reports/';
BEGIN
  FOR r IN (
    SELECT object_name
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri)
    WHERE object_name LIKE '%.csv.gz'
      AND last_modified >= (SYSDATE - 90)
      AND object_name NOT IN (SELECT filename FROM loaded_files_log)
  ) LOOP
    BEGIN
      DBMS_CLOUD.COPY_DATA(
        table_name      => 'OCI_COST_DATA_NEW',
        credential_name => 'OCI$RESOURCE_PRINCIPAL',
        file_uri_list   => l_uri || r.object_name,
        format          => json_object(
                            'type'                 VALUE 'csv',
                            'compression'          VALUE 'gzip',
                            'skipheaders'          VALUE '1',
                            'timestampformat'      VALUE 'YYYY-MM-DD"T"HH24:MI:SS"Z"',
                            'ignoremissingcolumns' VALUE 'true',
                            'trimspaces'           VALUE 'lrtrim',
                            'blankasnull'          VALUE 'true'
                           )
      );
      INSERT INTO loaded_files_log (filename) VALUES (r.object_name);
      COMMIT;
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Skipped ' || r.object_name || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/
```

### Step 2 — Create the Differential Load Procedure

```sql
CREATE OR REPLACE PROCEDURE load_oci_cost_hourly AS
  l_uri   VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/<namespace>/b/<bucket>/o/FOCUS%20Reports/';
  l_count NUMBER;
BEGIN
  FOR r IN (
    SELECT object_name
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri)
    WHERE object_name LIKE '%.csv.gz'
      AND last_modified >= (SYSDATE - 1)
      AND object_name NOT IN (SELECT filename FROM loaded_files_log)
  ) LOOP
    SELECT COUNT(*) INTO l_count FROM loaded_files_log WHERE filename = r.object_name;
    IF l_count = 0 THEN
      BEGIN
        DBMS_CLOUD.COPY_DATA(
          table_name      => 'OCI_COST_DATA_NEW',
          credential_name => 'OCI$RESOURCE_PRINCIPAL',
          file_uri_list   => l_uri || r.object_name,
          format          => json_object(
                              'type'                 VALUE 'csv',
                              'compression'          VALUE 'gzip',
                              'skipheaders'          VALUE '1',
                              'timestampformat'      VALUE 'YYYY-MM-DD"T"HH24:MI:SS"Z"',
                              'ignoremissingcolumns' VALUE 'true',
                              'trimspaces'           VALUE 'lrtrim',
                              'blankasnull'          VALUE 'true'
                             )
        );
        INSERT INTO loaded_files_log (filename) VALUES (r.object_name);
        COMMIT;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error loading ' || r.object_name || ': ' || SQLERRM);
      END;
    END IF;
  END LOOP;
END;
/
```

### Step 3 — Schedule the Hourly Job

```sql
BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'JOB_LOAD_OCI_COSTS_HOURLY',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN load_oci_cost_hourly; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=HOURLY; INTERVAL=1',
    enabled         => TRUE,
    comments        => 'Loads new OCI Cost Reports every hour'
  );
END;
/
```

---

## Monitoring & Debugging

### Check Scheduler Job History

```sql
SELECT log_date, status, error#, run_duration, additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_LOAD_OCI_COSTS_HOURLY'
ORDER BY log_date DESC;
```

### Inspect Loaded Files

```sql
-- Count of files loaded per day
SELECT TRUNC(load_date) AS load_day, COUNT(*) AS files_loaded
FROM loaded_files_log
GROUP BY TRUNC(load_date)
ORDER BY 1 DESC;
```

### Verify Row Counts

```sql
SELECT COUNT(*) FROM oci_cost_data_new;
```

### Manually Disable / Enable the Scheduler Job

```sql
-- Disable
EXEC DBMS_SCHEDULER.DISABLE('JOB_LOAD_OCI_COSTS_HOURLY');

-- Enable
EXEC DBMS_SCHEDULER.ENABLE('JOB_LOAD_OCI_COSTS_HOURLY');
```

---

## File Format Details

| Property | Value |
|---|---|
| Source format | CSV (FOCUS 1.0) |
| Compression | GZIP (`.csv.gz`) |
| Timestamp format | `YYYY-MM-DD"T"HH24:MI:SS"Z"` |
| Headers | Skipped (row 1) |
| Missing columns | Ignored |
| Blank values | Treated as NULL |

---

## Notes

- The `LOADED_FILES_LOG` table is the single source of truth for idempotency. Do **not** truncate it unless you intend to reload all historical data.
- The `load_oci_cost_hourly` procedure includes a concurrency check (`l_count = 0`) to prevent duplicate loads if the job overlaps with a manual run.
- Update the `l_uri` variable in both the backfill block and the **procedure to match your tenancy's namespace and bucket name.**
- FOCUS report files are typically published once per day; the 24-hour lookback window in the differential load is intentionally conservative to avoid missing files near day boundaries.
