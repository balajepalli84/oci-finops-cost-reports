CREATE MATERIALIZED VIEW OCI_DAILY_COST_MV
BUILD IMMEDIATE
REFRESH COMPLETE ON DEMAND
AS
SELECT
    TRUNC(TO_DATE(SUBSTR(ChargePeriodStart, 1, 10), 'YYYY-MM-DD')) AS COST_DAY,
    TRUNC(TO_DATE(SUBSTR(ChargePeriodEnd,   1, 10), 'YYYY-MM-DD')) AS COST_END_DAY,
    ServiceName                                                    AS SERVICENAME,
    ServiceCategory                                                AS SERVICECATEGORY,
    Region                                                         AS REGION,
    AvailabilityZone                                               AS AVAILABILITYZONE,
    ResourceId                                                     AS RESOURCEID,
    ResourceName                                                   AS RESOURCENAME,
    ResourceType                                                   AS RESOURCETYPE,
    oci_CompartmentId                                              AS OCI_COMPARTMENTID,
    oci_CompartmentName                                            AS OCI_COMPARTMENTNAME,
    oci_CompartmentPath                                            AS COMPARTMENTPATH,
    SubAccountId                                                   AS SUBACCOUNTID,
    SubAccountName                                                 AS SUBACCOUNTNAME,
    ChargeCategory                                                 AS CHARGECATEGORY,
    ServiceSubCategory                                             AS CHARGESUBCATEGORY,
    BillingCurrency                                                AS BILLINGCURRENCY,
    Tags                                                           AS TAGS,
    SUM(NVL(EffectiveCost, 0))                                     AS DAILY_EFFECTIVECOST,
    SUM(NVL(BilledCost, 0))                                        AS DAILY_BILLEDCOST,
    SUM(NVL(ListCost, 0))                                          AS DAILY_LISTCOST,
    SUM(NVL(UsageQuantity, 0))                                     AS DAILY_USAGE,
    SUM(NVL(oci_AttributedCost, 0))                                AS DAILY_ATTRIBUTEDCOST
FROM OCI_COST_DATA
GROUP BY
    TRUNC(TO_DATE(SUBSTR(ChargePeriodStart, 1, 10), 'YYYY-MM-DD')),
    TRUNC(TO_DATE(SUBSTR(ChargePeriodEnd,   1, 10), 'YYYY-MM-DD')),
    ServiceName,
    ServiceCategory,
    Region,
    AvailabilityZone,
    ResourceId,
    ResourceName,
    ResourceType,
    oci_CompartmentId,
    oci_CompartmentName,
    oci_CompartmentPath,
    SubAccountId,
    SubAccountName,
    ChargeCategory,
    ServiceSubCategory,
    BillingCurrency,
    Tags;
/

BEGIN
    DBMS_MVIEW.REFRESH('OCI_DAILY_COST_MV', 'C');
END;
/

--Schedule MV refresh every 3 hours
BEGIN
  DBMS_SCHEDULER.create_job (
      job_name        => 'REFRESH_OCI_DAILY_COST_MV',
      job_type        => 'PLSQL_BLOCK',
      job_action      => 'BEGIN DBMS_MVIEW.REFRESH(''OCI_DAILY_COST_MV'',''C''); END;',
      start_date      => SYSTIMESTAMP,
      repeat_interval => 'FREQ=HOURLY;INTERVAL=3',
      enabled         => TRUE
  );
END;
/
