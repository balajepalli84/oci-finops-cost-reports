SELECT *
FROM user_cloud_pipelines
WHERE pipeline_name = 'OCI_COST_PIPELINE';

SELECT *
FROM user_load_operations
WHERE table_name = 'OCI_COST_DATA'
ORDER BY start_time DESC;

SELECT COUNT(*) FROM OCI_COST_DATA;
