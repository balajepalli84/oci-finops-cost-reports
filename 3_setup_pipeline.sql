BEGIN
    DBMS_CLOUD_PIPELINE.CREATE_PIPELINE(
        pipeline_name => 'OCI_COST_PIPELINE',
        pipeline_type => 'LOAD',
        description   => 'Load enriched FOCUS cost reports (CSV, QUOTE_ALL) from Object Storage into OCI_COST_DATA'
    );
END;
/
-- Replace Namespace and Bucket Name values
BEGIN
    DBMS_CLOUD_PIPELINE.SET_ATTRIBUTE(
        pipeline_name => 'OCI_COST_PIPELINE',
        attributes    => JSON_OBJECT(
            'credential_name' VALUE 'MY_OCI_CRED',
            'table_owner'     VALUE 'ADMIN',
            'table_name'      VALUE 'OCI_COST_DATA',
            'location'        VALUE 'https://objectstorage.us-ashburn-1.oraclecloud.com/n/ociateam/b/Cost_Usage_Reports/o/FOCUS%20Reports/',
            'format'          VALUE '{"type":"csv","delimiter":",","quote":"\"","skipheaders":"1","compression":"gzip","blankasnull":true,"dateformat":"YYYY-MM-DD","rejectlimit":"unlimited","readsize":134217728}',
            'interval'        VALUE '1',
            'priority'        VALUE 'HIGH'
        )
    );
END;
/

BEGIN
    DBMS_CLOUD_PIPELINE.START_PIPELINE(
        pipeline_name => 'OCI_COST_PIPELINE'
    );
END;
/
