# OCI FOCUS Cost Report Ingestion Pipeline

Automated ingestion of Oracle Cloud Infrastructure (OCI) FOCUS Cost and Usage Reports into Autonomous Database (ADB) using `DBMS_CLOUD`, with scheduled hourly differential loading through `DBMS_SCHEDULER`.

---

## Architecture Overview

```text
OCI Object Storage (FOCUS Reports bucket)
        |
        |  DBMS_CLOUD.LIST_OBJECTS + COPY_DATA
        v
Autonomous Database (ADB)
        |-- OCI_COST_DATA_NEW     -> Main target table
        |-- LOADED_FILES_LOG      -> File-level deduplication tracker
        |-- LOAD_FAILURES_LOG     -> Failed file load tracking
        |
        |-- LOAD_OCI_COST_HOURLY          -> Hourly differential loader
        |-- RELOAD_OCI_COST_UNPROCESSED   -> Recovery loader for missed files
````

This solution supports:

* initial historical backfill for the last 90 days
* hourly differential loading for new files
* file-level idempotency using `LOADED_FILES_LOG`
* failure tracking using `LOAD_FAILURES_LOG`
* a recovery path to reload files that were not processed earlier

---

## How the Pipeline Works

### 1. Initial backfill

A one-time PL/SQL block reads `.csv.gz` files from Object Storage for the last 90 days and loads them into `OCI_COST_DATA_NEW`.

### 2. Differential load

A stored procedure named `LOAD_OCI_COST_HOURLY` runs every hour through `DBMS_SCHEDULER`. It checks for files modified in the last 24 hours that are not already logged in `LOADED_FILES_LOG`.

### 3. Idempotency

A file is considered processed only after it is successfully loaded and inserted into `LOADED_FILES_LOG`. This prevents duplicate loads.

### 4. Failure handling

If a file fails to load, the filename, error message, and timestamp are written to `LOAD_FAILURES_LOG`.

### 5. Recovery / replay

A second procedure named `RELOAD_OCI_COST_UNPROCESSED` can be run as a background job to process any file in the bucket that is still missing from `LOADED_FILES_LOG`.

---

## Prerequisites

### 1. OCI IAM Policy

ADB uses `OCI$RESOURCE_PRINCIPAL` to access the OCI Usage Report bucket. That bucket is owned by the OCI usage-report tenancy. You must create a policy in your tenancy to allow this access.

Example policy:

```hcl
define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq

endorse any-user to read objects in tenancy usage-report
  where request.resource.compartment.id = '<YOUR_ADB_COMPARTMENT_OCID>'
```

You can tighten this further to a specific ADB instance:

```hcl
endorse any-user to read objects in tenancy usage-report
  where request.resource.id = '<YOUR_ADB_INSTANCE_OCID>'
```

### 2. ADB Resource Principal

Resource Principal must be enabled on the Autonomous Database.

Check it:

```sql
SELECT owner, credential_name
FROM dba_credentials
WHERE credential_name = 'OCI$RESOURCE_PRINCIPAL'
  AND owner = 'ADMIN';
```

If no row is returned, enable it:

```sql
EXEC DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL();
```

Re-run the query to confirm the credential exists before continuing.

---

## Database Objects

### `OCI_COST_DATA_NEW`

Main target table that stores FOCUS cost data plus OCI-specific extension columns.

This includes:

* standard FOCUS fields such as `BilledCost`, `EffectiveCost`, `ServiceName`, `Region`, `ResourceId`, `Tags`
* OCI extension fields such as `oci_CompartmentId`, `oci_CompartmentName`, `oci_AttributedCost`, `oci_ReferenceNumber`

### `LOADED_FILES_LOG`

Tracks successfully processed files.

| Column      | Type             | Purpose                               |
| ----------- | ---------------- | ------------------------------------- |
| `filename`  | `VARCHAR2(1000)` | Object name from the bucket           |
| `load_date` | `TIMESTAMP`      | Time the file was successfully loaded |

### `LOAD_FAILURES_LOG`

Tracks failed file loads.

| Column          | Type             | Purpose                           |
| --------------- | ---------------- | --------------------------------- |
| `filename`      | `VARCHAR2(1000)` | Object name that failed           |
| `error_message` | `VARCHAR2(4000)` | Oracle error returned during load |
| `error_time`    | `TIMESTAMP`      | Time of failure                   |

---

## Deployment Steps

### Step 1. Create the tables

Run the SQL script to create:

* `OCI_COST_DATA_NEW`
* `LOADED_FILES_LOG`
* `LOAD_FAILURES_LOG`

### Step 2. Run the initial backfill

Run the backfill PL/SQL block once. This loads up to the last 90 days of `.csv.gz` files that are not already in `LOADED_FILES_LOG`.

### Step 3. Create the hourly loader procedure

Create `LOAD_OCI_COST_HOURLY`.

### Step 4. Create the hourly scheduler job

Create `JOB_LOAD_OCI_COSTS_HOURLY` so new files are loaded every hour.

### Step 5. Create the reload procedure

Create `RELOAD_OCI_COST_UNPROCESSED`.

### Step 6. Create the one-time reload job when needed

Use `JOB_RELOAD_OCI_COST_UNPROCESSED` only when you want to catch up on missed files.

---

## Monitoring and Operations

### Check hourly job history

```sql
SELECT
  log_date,
  status,
  error#,
  run_duration,
  additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_LOAD_OCI_COSTS_HOURLY'
ORDER BY log_date DESC;
```

### Check reload job history

```sql
SELECT
  log_date,
  status,
  error#,
  run_duration,
  additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_RELOAD_OCI_COST_UNPROCESSED'
ORDER BY log_date DESC;
```

### Check reconciliation between source, loaded files, and target rows

```sql
SELECT
  (SELECT COUNT(*) FROM OCI_COST_DATA_NEW) AS target_rows,
  (SELECT COUNT(*) FROM loaded_files_log) AS logged_files,
  (
    SELECT COUNT(*)
    FROM DBMS_CLOUD.LIST_OBJECTS(
           'OCI$RESOURCE_PRINCIPAL',
           'https://objectstorage.us-phoenix-1.oraclecloud.com/n/<namespace>/b/<bucket>/o/FOCUS%20Reports/'
         )
    WHERE object_name LIKE '%.csv.gz'
  ) AS source_files,
  (
    SELECT COUNT(*)
    FROM DBMS_CLOUD.LIST_OBJECTS(
           'OCI$RESOURCE_PRINCIPAL',
           'https://objectstorage.us-phoenix-1.oraclecloud.com/n/<namespace>/b/<bucket>/o/FOCUS%20Reports/'
         ) o
    WHERE o.object_name LIKE '%.csv.gz'
      AND NOT EXISTS (
        SELECT 1
        FROM loaded_files_log f
        WHERE f.filename = o.object_name
      )
  ) AS files_not_logged
FROM dual;
```

### Check failed loads

```sql
SELECT *
FROM load_failures_log
ORDER BY error_time DESC;
```

### Check files loaded by day

```sql
SELECT
  TRUNC(load_date) AS load_day,
  COUNT(*) AS files_loaded
FROM loaded_files_log
GROUP BY TRUNC(load_date)
ORDER BY load_day DESC;
```

### Check latest loaded file entries

```sql
SELECT *
FROM loaded_files_log
ORDER BY load_date DESC
FETCH FIRST 50 ROWS ONLY;
```

### Check latest data present in target table

```sql
SELECT
  MAX(BillingPeriodStart) AS max_billing_period_start,
  MAX(BillingPeriodEnd)   AS max_billing_period_end,
  COUNT(*)                AS total_rows
FROM OCI_COST_DATA_NEW;
```

---

## Job Control

### Stop jobs

```sql
BEGIN
  DBMS_SCHEDULER.STOP_JOB('JOB_LOAD_OCI_COSTS_HOURLY', TRUE);
END;
/

BEGIN
  DBMS_SCHEDULER.STOP_JOB('JOB_RELOAD_OCI_COST_UNPROCESSED', TRUE);
END;
/
```

### Disable and enable hourly job

```sql
BEGIN
  DBMS_SCHEDULER.DISABLE('JOB_LOAD_OCI_COSTS_HOURLY');
END;
/

BEGIN
  DBMS_SCHEDULER.ENABLE('JOB_LOAD_OCI_COSTS_HOURLY');
END;
/
```

### Drop jobs

```sql
BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_RELOAD_OCI_COST_UNPROCESSED', TRUE);
END;
/

BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_LOAD_OCI_COSTS_HOURLY', TRUE);
END;
/
```

---

## File Format Used by `DBMS_CLOUD.COPY_DATA`

| Property               | Value                        |
| ---------------------- | ---------------------------- |
| Source format          | CSV                          |
| Compression            | GZIP                         |
| Skip headers           | 1                            |
| Timestamp format       | `YYYY-MM-DD"T"HH24:MI:SS"Z"` |
| Ignore missing columns | true                         |
| Trim spaces            | `lrtrim`                     |
| Blank as null          | true                         |

---

## Important Notes

* `LOADED_FILES_LOG` is the control table for idempotency. Do not truncate it unless you want to reload files again.
* `LOAD_FAILURES_LOG` keeps failed files visible so you can debug bad files or permission issues.
* The hourly loader checks the last 24 hours of object updates. This is intentional so files near day boundaries are not missed.
* The recovery procedure does not depend on `last_modified >= SYSDATE - 1`. It checks the whole bucket and loads any file not yet logged.
* If a file load succeeds but logging fails, that file can be retried later. This is why the filename primary key is important.
* Update the Object Storage URI in the script to match your namespace and bucket.
* Run the backfill only once. After that, let the hourly job handle normal ingestion.

---

## Recommended Run Order

1. create tables
2. run initial backfill
3. create hourly load procedure
4. create hourly scheduler job
5. monitor hourly job
6. use reload procedure only when files were missed or failures occurred

