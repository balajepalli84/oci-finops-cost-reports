--------------------------------------------------------------------------------
-- OCI FinOps Cost Report Loader
-- Design:
--   1) Run 90-day backfill once
--   2) Run 1-day incremental on schedule
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- 1. TARGET TABLE
--------------------------------------------------------------------------------
CREATE TABLE oci_cost_data_new (
  AvailabilityZone             VARCHAR2(4000),
  BilledCost                   NUMBER,
  BillingAccountId             VARCHAR2(4000),
  BillingAccountName           VARCHAR2(4000),
  BillingCurrency              VARCHAR2(4000),
  BillingPeriodEnd             TIMESTAMP(6),
  BillingPeriodStart           TIMESTAMP(6),
  ChargeCategory               VARCHAR2(4000),
  ChargeDescription            VARCHAR2(4000),
  ChargeFrequency              VARCHAR2(4000),
  ChargePeriodEnd              VARCHAR2(4000),
  ChargePeriodStart            VARCHAR2(4000),
  ChargeSubcategory            VARCHAR2(4000),
  CommitmentDiscountCategory   VARCHAR2(4000),
  CommitmentDiscountId         VARCHAR2(4000),
  CommitmentDiscountName       VARCHAR2(4000),
  CommitmentDiscountType       VARCHAR2(4000),
  EffectiveCost                NUMBER,
  InvoiceIssuer                VARCHAR2(4000),
  ListCost                     NUMBER,
  ListUnitPrice                NUMBER,
  PricingCategory              VARCHAR2(4000),
  PricingQuantity              NUMBER,
  PricingUnit                  VARCHAR2(4000),
  Provider                     VARCHAR2(4000),
  Publisher                    VARCHAR2(4000),
  Region                       VARCHAR2(4000),
  ResourceId                   VARCHAR2(4000),
  ResourceName                 VARCHAR2(4000),
  ResourceType                 VARCHAR2(4000),
  ServiceCategory              VARCHAR2(4000),
  ServiceName                  VARCHAR2(4000),
  SkuId                        VARCHAR2(4000),
  SkuPriceId                   VARCHAR2(4000),
  SubAccountId                 VARCHAR2(4000),
  SubAccountName               VARCHAR2(4000),
  Tags                         VARCHAR2(4000),
  UsageQuantity                NUMBER,
  UsageUnit                    VARCHAR2(4000),
  oci_ReferenceNumber          VARCHAR2(4000),
  oci_CompartmentId            VARCHAR2(4000),
  oci_CompartmentName          VARCHAR2(4000),
  oci_OverageFlag              VARCHAR2(4000),
  oci_UnitPriceOverage         VARCHAR2(4000),
  oci_BilledQuantityOverage    VARCHAR2(4000),
  oci_CostOverage              VARCHAR2(4000),
  oci_AttributedUsage          NUMBER,
  oci_AttributedCost           NUMBER,
  oci_BackReferenceNumber      VARCHAR2(4000)
);

--------------------------------------------------------------------------------
-- 2. FILE LOAD LOG
--------------------------------------------------------------------------------
CREATE TABLE loaded_files_log (
  filename   VARCHAR2(500) PRIMARY KEY,
  load_date  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

--------------------------------------------------------------------------------
-- 3. FAILURE LOG
--------------------------------------------------------------------------------
CREATE TABLE load_failures_log (
  filename       VARCHAR2(1000),
  error_message  VARCHAR2(4000),
  error_time     TIMESTAMP
);

--------------------------------------------------------------------------------
-- 4. SHARED LOAD PROCEDURE
--    p_days_back = 90 for backfill
--    p_days_back = 1  for incremental
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE load_oci_cost_files (
  p_days_back IN NUMBER
) AS
  l_uri    VARCHAR2(1000) := 'https://objectstorage.us-ashburn-1.oraclecloud.com/n/bling/b/ocid1.tenancy.oc1..aaaaaaaaa3qmjxr43tjexx75r6gwk6vjw22ermohbw2vbxyhczksgjir7xdq/o/FOCUS%20Reports/';
  l_errmsg VARCHAR2(4000);
BEGIN
  FOR r IN (
    SELECT o.object_name
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri) o
    WHERE o.object_name LIKE '%.csv.gz'
      AND o.last_modified >= (SYSDATE - p_days_back)
      AND NOT EXISTS (
        SELECT 1
        FROM loaded_files_log f
        WHERE f.filename = o.object_name
      )
    ORDER BY o.last_modified, o.object_name
  ) LOOP
    BEGIN
      DBMS_CLOUD.COPY_DATA(
        table_name      => 'OCI_COST_DATA_NEW',
        credential_name => 'OCI$RESOURCE_PRINCIPAL',
        file_uri_list   => l_uri || r.object_name,
        format          => json_object(
                             'type' VALUE 'csv',
                             'delimiter' VALUE ',',
                             'compression' VALUE 'gzip',
                             'skipheaders' VALUE '1',
                             'quote' VALUE '"',
                             'timestampformat' VALUE 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"',
                             'ignoremissingcolumns' VALUE 'true',
                             'trimspaces' VALUE 'lrtrim',
                             'blankasnull' VALUE 'true',
                             'conversionerrors' VALUE 'store_null',
                             'rejectlimit' VALUE '100000'
                           )
      );

      INSERT INTO loaded_files_log (filename, load_date)
      VALUES (r.object_name, SYSTIMESTAMP);

      COMMIT;

    EXCEPTION
      WHEN OTHERS THEN
        l_errmsg := SUBSTR(SQLERRM, 1, 4000);

        INSERT INTO load_failures_log (filename, error_message, error_time)
        VALUES (r.object_name, l_errmsg, SYSTIMESTAMP);

        COMMIT;
    END;
  END LOOP;
END;
/
SHOW ERRORS;

--------------------------------------------------------------------------------
-- 5. ONE-TIME 90-DAY BACKFILL PROCEDURE
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE load_oci_cost_backfill_90d AS
BEGIN
  load_oci_cost_files(90);
END;
/
SHOW ERRORS;

--------------------------------------------------------------------------------
-- 6. SCHEDULED 1-DAY INCREMENTAL PROCEDURE
--------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE load_oci_cost_incremental_1d AS
BEGIN
  load_oci_cost_files(1);
END;
/
SHOW ERRORS;

--------------------------------------------------------------------------------
-- 7. RUN THE 90-DAY BACKFILL ONCE
--    Uncomment this block the first time you deploy.
--------------------------------------------------------------------------------
BEGIN
  load_oci_cost_backfill_90d;
END;
/
-- After first successful backfill, you can comment out or remove the block above.

--------------------------------------------------------------------------------
-- 8. DROP OLD JOB IF IT EXISTS
--------------------------------------------------------------------------------
BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_LOAD_OCI_COSTS_HOURLY', TRUE);
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END;
/

--------------------------------------------------------------------------------
-- 9. CREATE HOURLY INCREMENTAL JOB
--------------------------------------------------------------------------------
BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'JOB_LOAD_OCI_COSTS_HOURLY',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'LOAD_OCI_COST_INCREMENTAL_1D',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=HOURLY; INTERVAL=1',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Loads new OCI cost report files from the last 1 day every hour'
  );
END;
/

--------------------------------------------------------------------------------
-- 10. VALIDATION QUERIES
--------------------------------------------------------------------------------
SELECT COUNT(*) AS target_rows
FROM oci_cost_data_new;

SELECT COUNT(*) AS logged_files
FROM loaded_files_log;

SELECT COUNT(*) AS failed_files
FROM load_failures_log;

SELECT job_name, state, last_start_date, last_run_duration
FROM user_scheduler_jobs
WHERE job_name = 'JOB_LOAD_OCI_COSTS_HOURLY';

SELECT log_date, status, error#, run_duration, additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_LOAD_OCI_COSTS_HOURLY'
ORDER BY log_date DESC;

--------------------------------------------------------------------------------
-- 11. OPTIONAL: SEE WHAT FILES ARE STILL NOT LOGGED
--------------------------------------------------------------------------------
SELECT COUNT(*) AS files_not_logged
FROM DBMS_CLOUD.LIST_OBJECTS(
       'OCI$RESOURCE_PRINCIPAL',
       'https://objectstorage.us-ashburn-1.oraclecloud.com/n/bling/b/ocid1.tenancy.oc1..aaaaaaaaa3qmjxr43tjexx75r6gwk6vjw22ermohbw2vbxyhczksgjir7xdq/o/FOCUS%20Reports/'
     ) o
WHERE o.object_name LIKE '%.csv.gz'
  AND NOT EXISTS (
    SELECT 1
    FROM loaded_files_log f
    WHERE f.filename = o.object_name
  );
