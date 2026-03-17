------------------------------------------------------------------------------
-- OCI FOCUS Cost Report Ingestion Pipeline
-- Final consolidated script
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- 1. MAIN TARGET TABLE
------------------------------------------------------------------------------

CREATE TABLE oci_cost_data_new (
    -- Standard FOCUS Columns
    AvailabilityZone           VARCHAR2(4000),
    BilledCost                 NUMBER,
    BillingAccountId           VARCHAR2(4000),
    BillingAccountName         VARCHAR2(4000),
    BillingCurrency            VARCHAR2(4000),
    BillingPeriodEnd           TIMESTAMP(6),
    BillingPeriodStart         TIMESTAMP(6),
    ChargeCategory             VARCHAR2(4000),
    ChargeDescription          VARCHAR2(4000),
    ChargeFrequency            VARCHAR2(4000),
    ChargePeriodEnd            VARCHAR2(4000),
    ChargePeriodStart          VARCHAR2(4000),
    ChargeSubcategory          VARCHAR2(4000),
    CommitmentDiscountCategory VARCHAR2(4000),
    CommitmentDiscountId       VARCHAR2(4000),
    CommitmentDiscountName     VARCHAR2(4000),
    CommitmentDiscountType     VARCHAR2(4000),
    EffectiveCost              NUMBER,
    InvoiceIssuer              VARCHAR2(4000),
    ListCost                   NUMBER,
    ListUnitPrice              NUMBER,
    PricingCategory            VARCHAR2(4000),
    PricingQuantity            NUMBER,
    PricingUnit                VARCHAR2(4000),
    Provider                   VARCHAR2(4000),
    Publisher                  VARCHAR2(4000),
    Region                     VARCHAR2(4000),
    ResourceId                 VARCHAR2(4000),
    ResourceName               VARCHAR2(4000),
    ResourceType               VARCHAR2(4000),
    ServiceCategory            VARCHAR2(4000),
    ServiceName                VARCHAR2(4000),
    SkuId                      VARCHAR2(4000),
    SkuPriceId                 VARCHAR2(4000),
    SubAccountId               VARCHAR2(4000),
    SubAccountName             VARCHAR2(4000),
    Tags                       VARCHAR2(4000),
    UsageQuantity              NUMBER,
    UsageUnit                  VARCHAR2(4000),

    -- OCI-specific extension columns
    oci_ReferenceNumber        VARCHAR2(4000),
    oci_CompartmentId          VARCHAR2(4000),
    oci_CompartmentName        VARCHAR2(4000),
    oci_OverageFlag            VARCHAR2(4000),
    oci_UnitPriceOverage       VARCHAR2(4000),
    oci_BilledQuantityOverage  VARCHAR2(4000),
    oci_CostOverage            VARCHAR2(4000),
    oci_AttributedUsage        NUMBER,
    oci_AttributedCost         NUMBER,
    oci_BackReferenceNumber    VARCHAR2(4000)
);

------------------------------------------------------------------------------
-- 2. FILE LOAD TRACKING TABLE
------------------------------------------------------------------------------

CREATE TABLE loaded_files_log (
    filename  VARCHAR2(1000) PRIMARY KEY,
    load_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

------------------------------------------------------------------------------
-- 3. FAILURE LOG TABLE
------------------------------------------------------------------------------

CREATE TABLE load_failures_log (
    filename      VARCHAR2(1000),
    error_message VARCHAR2(4000),
    error_time    TIMESTAMP
);

------------------------------------------------------------------------------
-- 4. INITIAL BACKFILL - LAST 90 DAYS
--    Run once for first-time historical load
------------------------------------------------------------------------------

DECLARE
  l_uri    VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/axvl7chrr9th/b/internal-ocid1.tenancy.oc1..aaaaaaaamy3a46ljb5gdtruftfg7xtuatc5ymgeob3sivuuao34sjbx3tk3q/o/FOCUS%20Reports/';
  l_errmsg VARCHAR2(4000);
BEGIN
  FOR r IN (
    SELECT object_name
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri)
    WHERE object_name LIKE '%.csv.gz'
      AND last_modified >= (SYSDATE - 90)
      AND NOT EXISTS (
        SELECT 1
        FROM loaded_files_log f
        WHERE f.filename = object_name
      )
    ORDER BY object_name
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

      INSERT INTO loaded_files_log (filename, load_date)
      VALUES (r.object_name, SYSTIMESTAMP);

      COMMIT;

    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN
        ROLLBACK;
      WHEN OTHERS THEN
        l_errmsg := SUBSTR(SQLERRM, 1, 4000);

        INSERT INTO load_failures_log (filename, error_message, error_time)
        VALUES (r.object_name, l_errmsg, SYSTIMESTAMP);

        COMMIT;
    END;
  END LOOP;
END;
/
    
------------------------------------------------------------------------------
-- 5. HOURLY DIFFERENTIAL LOAD PROCEDURE
------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE load_oci_cost_hourly AS
  l_uri    VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/axvl7chrr9th/b/internal-ocid1.tenancy.oc1..aaaaaaaamy3a46ljb5gdtruftfg7xtuatc5ymgeob3sivuuao34sjbx3tk3q/o/FOCUS%20Reports/';
  l_count  NUMBER;
  l_errmsg VARCHAR2(4000);
BEGIN
  FOR r IN (
    SELECT object_name
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri)
    WHERE object_name LIKE '%.csv.gz'
      AND last_modified >= (SYSDATE - 1)
      AND NOT EXISTS (
        SELECT 1
        FROM loaded_files_log f
        WHERE f.filename = object_name
      )
    ORDER BY object_name
  ) LOOP

    SELECT COUNT(*)
    INTO l_count
    FROM loaded_files_log
    WHERE filename = r.object_name;

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

        INSERT INTO loaded_files_log (filename, load_date)
        VALUES (r.object_name, SYSTIMESTAMP);

        COMMIT;

      EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
          ROLLBACK;
        WHEN OTHERS THEN
          l_errmsg := SUBSTR(SQLERRM, 1, 4000);

          INSERT INTO load_failures_log (filename, error_message, error_time)
          VALUES (r.object_name, l_errmsg, SYSTIMESTAMP);

          COMMIT;
      END;
    END IF;

  END LOOP;
END;
/
    
------------------------------------------------------------------------------
-- 6. CREATE HOURLY SCHEDULER JOB
------------------------------------------------------------------------------

BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'JOB_LOAD_OCI_COSTS_HOURLY',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN load_oci_cost_hourly; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=HOURLY; INTERVAL=1',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Loads new OCI Cost Reports every hour'
  );
END;
/
    
------------------------------------------------------------------------------
-- 7. RELOAD UNPROCESSED FILES PROCEDURE
--    Useful for recovery if some files were skipped or failed earlier
------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE reload_oci_cost_unprocessed AS
  l_uri    VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/axvl7chrr9th/b/internal-ocid1.tenancy.oc1..aaaaaaaamy3a46ljb5gdtruftfg7xtuatc5ymgeob3sivuuao34sjbx3tk3q/o/FOCUS%20Reports/';
  l_errmsg VARCHAR2(4000);
BEGIN
  FOR r IN (
    SELECT o.object_name
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri) o
    WHERE o.object_name LIKE '%.csv.gz'
      AND NOT EXISTS (
        SELECT 1
        FROM loaded_files_log f
        WHERE f.filename = o.object_name
      )
    ORDER BY o.object_name
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

      INSERT INTO loaded_files_log (filename, load_date)
      VALUES (r.object_name, SYSTIMESTAMP);

      COMMIT;

    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN
        ROLLBACK;
      WHEN OTHERS THEN
        l_errmsg := SUBSTR(SQLERRM, 1, 4000);

        INSERT INTO load_failures_log (filename, error_message, error_time)
        VALUES (r.object_name, l_errmsg, SYSTIMESTAMP);

        COMMIT;
    END;
  END LOOP;
END;
/
    
------------------------------------------------------------------------------
-- 8. CREATE ONE-TIME RELOAD JOB
--    Run this only when you want to process remaining/unlogged files
------------------------------------------------------------------------------

BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'JOB_RELOAD_OCI_COST_UNPROCESSED',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'RELOAD_OCI_COST_UNPROCESSED',
    start_date      => SYSTIMESTAMP,
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Reload remaining OCI cost files in background'
  );
END;
/
    
------------------------------------------------------------------------------
-- 9. MONITOR HOURLY JOB
------------------------------------------------------------------------------

SELECT
  log_date,
  status,
  error#,
  run_duration,
  additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_LOAD_OCI_COSTS_HOURLY'
ORDER BY log_date DESC;

------------------------------------------------------------------------------
-- 10. MONITOR RELOAD JOB
------------------------------------------------------------------------------

SELECT
  log_date,
  status,
  error#,
  run_duration,
  additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_RELOAD_OCI_COST_UNPROCESSED'
ORDER BY log_date DESC;

------------------------------------------------------------------------------
-- 11. CHECK PROGRESS / RECONCILIATION
------------------------------------------------------------------------------

SELECT
  (SELECT COUNT(*) FROM OCI_COST_DATA_NEW) AS target_rows,
  (SELECT COUNT(*) FROM loaded_files_log) AS logged_files,
  (
    SELECT COUNT(*)
    FROM DBMS_CLOUD.LIST_OBJECTS(
           'OCI$RESOURCE_PRINCIPAL',
           'https://objectstorage.us-phoenix-1.oraclecloud.com/n/axvl7chrr9th/b/internal-ocid1.tenancy.oc1..aaaaaaaamy3a46ljb5gdtruftfg7xtuatc5ymgeob3sivuuao34sjbx3tk3q/o/FOCUS%20Reports/'
         )
    WHERE object_name LIKE '%.csv.gz'
  ) AS source_files,
  (
    SELECT COUNT(*)
    FROM DBMS_CLOUD.LIST_OBJECTS(
           'OCI$RESOURCE_PRINCIPAL',
           'https://objectstorage.us-phoenix-1.oraclecloud.com/n/axvl7chrr9th/b/internal-ocid1.tenancy.oc1..aaaaaaaamy3a46ljb5gdtruftfg7xtuatc5ymgeob3sivuuao34sjbx3tk3q/o/FOCUS%20Reports/'
         ) o
    WHERE o.object_name LIKE '%.csv.gz'
      AND NOT EXISTS (
        SELECT 1
        FROM loaded_files_log f
        WHERE f.filename = o.object_name
      )
  ) AS files_not_logged
FROM dual;

------------------------------------------------------------------------------
-- 12. CHECK FAILURE LOG
------------------------------------------------------------------------------

SELECT *
FROM load_failures_log
ORDER BY error_time DESC;

------------------------------------------------------------------------------
-- 13. CHECK FILES LOADED BY DAY
------------------------------------------------------------------------------

SELECT
  TRUNC(load_date) AS load_day,
  COUNT(*) AS files_loaded
FROM loaded_files_log
GROUP BY TRUNC(load_date)
ORDER BY load_day DESC;

------------------------------------------------------------------------------
-- 14. CHECK LATEST LOAD TIMES
------------------------------------------------------------------------------

SELECT *
FROM loaded_files_log
ORDER BY load_date DESC
FETCH FIRST 50 ROWS ONLY;

------------------------------------------------------------------------------
-- 15. CHECK LATEST DATA LANDED IN TARGET TABLE
--     Uses BillingPeriodStart / BillingPeriodEnd since table has no audit column
------------------------------------------------------------------------------

SELECT
  MAX(BillingPeriodStart) AS max_billing_period_start,
  MAX(BillingPeriodEnd)   AS max_billing_period_end,
  COUNT(*)                AS total_rows
FROM OCI_COST_DATA_NEW;

------------------------------------------------------------------------------
-- 16. STOP JOBS IF NEEDED
------------------------------------------------------------------------------

BEGIN
  DBMS_SCHEDULER.STOP_JOB('JOB_LOAD_OCI_COSTS_HOURLY', TRUE);
END;
/

BEGIN
  DBMS_SCHEDULER.STOP_JOB('JOB_RELOAD_OCI_COST_UNPROCESSED', TRUE);
END;
/

------------------------------------------------------------------------------
-- 17. DISABLE / ENABLE HOURLY JOB
------------------------------------------------------------------------------

BEGIN
  DBMS_SCHEDULER.DISABLE('JOB_LOAD_OCI_COSTS_HOURLY');
END;
/

BEGIN
  DBMS_SCHEDULER.ENABLE('JOB_LOAD_OCI_COSTS_HOURLY');
END;
/

------------------------------------------------------------------------------
-- 18. DROP JOBS IF NEEDED
------------------------------------------------------------------------------

BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_RELOAD_OCI_COST_UNPROCESSED', TRUE);
END;
/

BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_LOAD_OCI_COSTS_HOURLY', TRUE);
END;
/
