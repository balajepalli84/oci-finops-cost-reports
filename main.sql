```sql
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
    
    -- OCI-Specific Extension Columns
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

CREATE TABLE loaded_files_log (
    filename VARCHAR2(500) PRIMARY KEY,
    load_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

DECLARE
  l_uri VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/<namespace>/b/<tenancy-ocid>/o/FOCUS%20Reports/';
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
                            'type' VALUE 'csv', 
                            'compression' VALUE 'gzip',
                            'skipheaders' VALUE '1',
                            'timestampformat' VALUE 'YYYY-MM-DD"T"HH24:MI:SS"Z"',
                            'ignoremissingcolumns' VALUE 'true',
                            'trimspaces' VALUE 'lrtrim',
                            'blankasnull' VALUE 'true'
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

CREATE OR REPLACE PROCEDURE load_oci_cost_hourly AS
  l_uri VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/<namespace>/b/<tenancy-coid>/o/FOCUS%20Reports/';
  l_count NUMBER;
BEGIN
  FOR r IN (
    SELECT object_name 
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri)
    WHERE object_name LIKE '%.csv.gz' 
      AND last_modified >= (SYSDATE - 1)
      AND object_name NOT IN (SELECT filename FROM loaded_files_log)
  ) LOOP
    
    SELECT count(*) INTO l_count FROM loaded_files_log WHERE filename = r.object_name;
    
    IF l_count = 0 THEN
      BEGIN
        DBMS_CLOUD.COPY_DATA(
          table_name      => 'OCI_COST_DATA_NEW',
          credential_name => 'OCI$RESOURCE_PRINCIPAL',
          file_uri_list   => l_uri || r.object_name,
          format          => json_object(
                              'type' VALUE 'csv', 
                              'compression' VALUE 'gzip',
                              'skipheaders' VALUE '1',
                              'timestampformat' VALUE 'YYYY-MM-DD"T"HH24:MI:SS"Z"',
                              'ignoremissingcolumns' VALUE 'true',
                              'trimspaces' VALUE 'lrtrim',
                              'blankasnull' VALUE 'true'
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

SELECT log_date, status, error#, run_duration, additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_LOAD_OCI_COSTS_HOURLY'
ORDER BY log_date DESC;

DECLARE
  l_uri VARCHAR2(1000) := 'https://objectstorage.us-phoenix-1.oraclecloud.com/n/axvl7chrr9th/b/internal-ocid1.tenancy.oc1..aaaaaaaamy3a46ljb5gdtruftfg7xtuatc5ymgeob3sivuuao34sjbx3tk3q/o/FOCUS%20Reports/';
BEGIN
  FOR r IN (
    SELECT object_name
    FROM DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL', l_uri)
    WHERE object_name LIKE '%.csv.gz'
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

      INSERT INTO loaded_files_log (filename)
      VALUES (r.object_name);

      COMMIT;

    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Skipped ' || r.object_name || ': ' || SQLERRM);
        ROLLBACK;
    END;
  END LOOP;
END;
/

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

CREATE TABLE load_failures_log (
  filename      VARCHAR2(1000),
  error_message VARCHAR2(4000),
  error_time    TIMESTAMP
);

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
      WHEN OTHERS THEN
        l_errmsg := SUBSTR(SQLERRM, 1, 4000);

        INSERT INTO load_failures_log (filename, error_message, error_time)
        VALUES (r.object_name, l_errmsg, SYSTIMESTAMP);

        COMMIT;
    END;
  END LOOP;
END;
/

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

SELECT
  log_date,
  status,
  error#,
  run_duration,
  additional_info
FROM user_scheduler_job_run_details
WHERE job_name = 'JOB_RELOAD_OCI_COST_UNPROCESSED'
ORDER BY log_date DESC;

SELECT COUNT(*) AS logged_files
FROM loaded_files_log;

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

BEGIN
  DBMS_SCHEDULER.STOP_JOB('JOB_RELOAD_OCI_COST_UNPROCESSED', TRUE);
END;
/

BEGIN
  DBMS_SCHEDULER.DROP_JOB('JOB_RELOAD_OCI_COST_UNPROCESSED', TRUE);
END;
/
```
