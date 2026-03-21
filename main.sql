--------------------------------------------------------------------------------
-- OCI FinOps Cost Report Loader
-- Design:
--   1) Run 90-day backfill once
--   2) Create/refresh materialized view
--   3) Run 1-day incremental on schedule
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
  l_uri    VARCHAR2(1000) := 'https://objectstorage.us-ashburn-1.oraclecloud.com/n/bling/b/ocid1.tenancy.oc1..xxxxxx/o/FOCUS%20Reports/';
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
-- After first successful backfill, comment out or remove the block above.

--------------------------------------------------------------------------------
-- 8. CREATE DAILY COST MATERIALIZED VIEW
--    Built immediately after the 90-day backfill so the MV is fully populated
--    from the start.  Subsequent refreshes are triggered manually or via the
--    scheduler job added in section 11.
--
--    Prerequisites:
--      • OCI_COST_DATA_NEW  -- populated by step 7
--      • ADMIN.ADB_OCI_COMPARTMENTS -- compartment hierarchy table
--------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW "ADMIN"."OCI_DAILY_COST_MV" (
  "COST_DAY",
  "COST_END_DAY",
  "SERVICENAME",
  "SERVICECATEGORY",
  "REGION",
  "AVAILABILITYZONE",
  "RESOURCEID",
  "RESOURCENAME",
  "RESOURCETYPE",
  "OCI_COMPARTMENTID",
  "OCI_COMPARTMENTNAME",
  "COMPARTMENTPATH",
  "SUBACCOUNTID",
  "SUBACCOUNTNAME",
  "CHARGECATEGORY",
  "CHARGESUBCATEGORY",
  "BILLINGCURRENCY",
  "TAGS",
  "DAILY_EFFECTIVECOST",
  "DAILY_BILLEDCOST",
  "DAILY_LISTCOST",
  "DAILY_USAGE",
  "DAILY_ATTRIBUTEDCOST"
)
DEFAULT COLLATION "USING_NLS_COMP"
SEGMENT CREATION IMMEDIATE
ORGANIZATION HEAP PCTFREE 10 PCTUSED 40 INITRANS 10 MAXTRANS 255
COLUMN STORE COMPRESS FOR QUERY HIGH ROW LEVEL LOCKING LOGGING
STORAGE (
  INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645
  PCTINCREASE 0 FREELISTS 1 FREELIST GROUPS 1
  BUFFER_POOL DEFAULT FLASH_CACHE DEFAULT CELL_FLASH_CACHE DEFAULT
)
TABLESPACE "DATA"
BUILD IMMEDIATE                          -- populate right away from backfill data
USING INDEX
REFRESH COMPLETE ON DEMAND               -- full refresh; switched to incremental later if a MV log is added
USING DEFAULT LOCAL ROLLBACK SEGMENT
USING ENFORCED CONSTRAINTS
DISABLE ON QUERY COMPUTATION
DISABLE QUERY REWRITE
DISABLE CONCURRENT REFRESH
AS
SELECT
    TRUNC(TO_DATE(SUBSTR(c.ChargePeriodStart, 1, 10), 'YYYY-MM-DD')) AS COST_DAY,
    TRUNC(TO_DATE(SUBSTR(c.ChargePeriodEnd,   1, 10), 'YYYY-MM-DD')) AS COST_END_DAY,
    c.ServiceName                                                     AS SERVICENAME,
    c.ServiceCategory                                                 AS SERVICECATEGORY,
    c.Region                                                          AS REGION,
    c.AvailabilityZone                                                AS AVAILABILITYZONE,
    c.ResourceId                                                      AS RESOURCEID,
    c.ResourceName                                                    AS RESOURCENAME,
    c.ResourceType                                                    AS RESOURCETYPE,
    c.OCI_CompartmentId                                               AS OCI_COMPARTMENTID,
    c.OCI_CompartmentName                                             AS OCI_COMPARTMENTNAME,
    cp.HIERARCHY_PATH                                                 AS COMPARTMENTPATH,
    c.SubAccountId                                                    AS SUBACCOUNTID,
    c.SubAccountName                                                  AS SUBACCOUNTNAME,
    c.ChargeCategory                                                  AS CHARGECATEGORY,
    c.ChargeSubCategory                                               AS CHARGESUBCATEGORY,
    c.BillingCurrency                                                 AS BILLINGCURRENCY,
    c.Tags                                                            AS TAGS,
    SUM(NVL(c.EffectiveCost,       0))                                AS DAILY_EFFECTIVECOST,
    SUM(NVL(c.BilledCost,          0))                                AS DAILY_BILLEDCOST,
    SUM(NVL(c.ListCost,            0))                                AS DAILY_LISTCOST,
    SUM(NVL(c.UsageQuantity,       0))                                AS DAILY_USAGE,
    SUM(NVL(c.OCI_AttributedCost,  0))                                AS DAILY_ATTRIBUTEDCOST
FROM ADMIN.OCI_COST_DATA_NEW c
LEFT JOIN (
    SELECT
        COMPARTMENT_OCID,
        MAX(HIERARCHY_PATH) AS HIERARCHY_PATH
    FROM ADMIN.ADB_OCI_COMPARTMENTS
    GROUP BY COMPARTMENT_OCID
) cp ON cp.COMPARTMENT_OCID = c.OCI_COMPARTMENTID
GROUP BY
    TRUNC(TO_DATE(SUBSTR(c.ChargePeriodStart, 1, 10), 'YYYY-MM-DD')),
    TRUNC(TO_DATE(SUBSTR(c.ChargePeriodEnd,   1, 10), 'YYYY-MM-DD')),
    c.ServiceName,
    c.ServiceCategory,
    c.Region,
    c.AvailabilityZone,
    c.ResourceId,
    c.ResourceName,
    c.ResourceType,
    c.OCI_CompartmentId,
    c.OCI_CompartmentName,
    cp.HIERARCHY_PATH,
    c.SubAccountId,
    c.SubAccountName,
    c.ChargeCategory,
    c.ChargeSubCategory,
    c.BillingCurrency,
    c.Tags;

--------------------------------------------------------------------------------
-- 9. DROP OLD JOB IF IT EXISTS
--------------------------------------------------------------------------------
BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_LOAD_OCI_COSTS_HOURLY', TRUE);
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END;
/

--------------------------------------------------------------------------------
-- 10. DROP OLD MV REFRESH JOB IF IT EXISTS
--------------------------------------------------------------------------------
BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_REFRESH_OCI_DAILY_COST_MV', TRUE);
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END;
/

--------------------------------------------------------------------------------
-- 11. CREATE HOURLY INCREMENTAL DATA LOAD JOB
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
-- 12. CREATE DAILY MV REFRESH JOB
--     Runs once per day, offset by 30 min after midnight to let any late
--     arriving hourly loads complete before the MV is rebuilt.
--     Adjust BYHOUR/BYMINUTE to match your preferred refresh window.
--------------------------------------------------------------------------------
BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'JOB_REFRESH_OCI_DAILY_COST_MV',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN DBMS_MVIEW.REFRESH(''OCI_DAILY_COST_MV'', method => ''C'', atomic_refresh => FALSE); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY; BYHOUR=0; BYMINUTE=30; BYSECOND=0',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Full refresh of OCI_DAILY_COST_MV once per day at 00:30 UTC'
  );
END;
/

--------------------------------------------------------------------------------
-- 13. VALIDATION QUERIES
--------------------------------------------------------------------------------
SELECT COUNT(*) AS target_rows     FROM oci_cost_data_new;
SELECT COUNT(*) AS logged_files    FROM loaded_files_log;
SELECT COUNT(*) AS failed_files    FROM load_failures_log;
SELECT COUNT(*) AS mv_rows         FROM oci_daily_cost_mv;

-- Scheduler job status
SELECT job_name, state, last_start_date, last_run_duration
FROM user_scheduler_jobs
WHERE job_name IN ('JOB_LOAD_OCI_COSTS_HOURLY', 'JOB_REFRESH_OCI_DAILY_COST_MV');

-- Recent job run history
SELECT job_name, log_date, status, error#, run_duration, additional_info
FROM user_scheduler_job_run_details
WHERE job_name IN ('JOB_LOAD_OCI_COSTS_HOURLY', 'JOB_REFRESH_OCI_DAILY_COST_MV')
ORDER BY log_date DESC;

-- MV metadata
SELECT mview_name, last_refresh_date, last_refresh_type, staleness
FROM user_mviews
WHERE mview_name = 'OCI_DAILY_COST_MV';

--------------------------------------------------------------------------------
-- 14. OPTIONAL: FILES NOT YET LOGGED
--------------------------------------------------------------------------------
SELECT COUNT(*) AS files_not_logged
FROM DBMS_CLOUD.LIST_OBJECTS(
       'OCI$RESOURCE_PRINCIPAL',
       'https://objectstorage.us-ashburn-1.oraclecloud.com/n/bling/b/ocid1.tenancy.oc1..xxx/o/FOCUS%20Reports/'
     ) o
WHERE o.object_name LIKE '%.csv.gz'
  AND NOT EXISTS (
    SELECT 1
    FROM loaded_files_log f
    WHERE f.filename = o.object_name
  );
