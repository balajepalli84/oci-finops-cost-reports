# OCI FinOps Cost Reports Pipeline

This repository deploys an **end-to-end pipeline for OCI cost reporting and FinOps analytics**.

The solution automates:

1. Copying OCI cost reports from a shared tenancy
2. Processing and enriching the reports
3. Loading the data into Autonomous Database
4. Creating aggregated cost views
5. Connecting the results to Oracle Analytics Cloud (OAC)

The system uses:

* OCI Terraform
* OCI Functions
* OCI Object Storage
* OCI Events
* DBMS_CLOUD_PIPELINE
* Materialized Views
* Oracle Analytics Cloud

---

# End-to-End Architecture

```
OCI Shared Tenancy
      │
      │  (Daily Cost Reports)
      ▼
Terraform Module
tf-oci-copy-focus-reports-main
      │
      ▼
Bucket: Cost_Usage_Reports_Staging
      │
      │  (Object Storage Event)
      ▼
Terraform Module
tf-oci-process-focus-report
      │
      ▼
OCI Function (Processing + Enrichment)
      │
      ▼
Bucket: Cost_Usage_Reports
      │
      ▼
DBMS_CLOUD_PIPELINE
      │
      ▼
Autonomous Database
OCI_COST_DATA
      │
      ▼
OCI_DAILY_COST_MV
      │
      ▼
Oracle Analytics Cloud
```

---

# Solution Flow

The deployment occurs in **three main phases**.

---

# Phase 1 — Copy Cost Reports from Shared Tenancy

Terraform module:

```
tf-oci-copy-focus-reports-main
```

This Terraform module creates infrastructure in the **customer tenancy**.

## What this module deploys

* OCI Function
* OCI Scheduler
* Object Storage bucket

Default bucket created:

```
Cost_Usage_Reports_Staging
```

This bucket stores raw cost report files copied from the shared tenancy.

### Scheduler

The Terraform code creates a **scheduled job** that runs every night.

```
02:00 AM
```

The job invokes the function which copies cost reports from the shared tenancy into the staging bucket.

### Customization

Customers can modify the bucket name during Terraform deployment.

Example variable:

```
bucket_name = "Cost_Usage_Reports_Staging"
```

---

# Phase 2 — Process and Enrich Cost Reports

Terraform module:

```
tf-oci-process-focus-report
```

This module prepares the **data processing pipeline**.

## What this module deploys

* OCI Function
* OCI Events rule
* Processed data bucket

Default bucket created:

```
Cost_Usage_Reports
```

---

## Event Trigger

An **Object Storage Event Rule** triggers when new files are added to:

```
Cost_Usage_Reports_Staging
```

The event invokes the processing function.

---

## Function Processing

The function performs the following tasks:

1. Reads the raw cost report file
2. Extracts the data
3. Enriches the data
4. Removes unnecessary columns
5. Extracts specific tag fields
6. Writes the processed dataset into:

```
Cost_Usage_Reports
```

The output file is optimized for loading into the database.

---

# Important Note on Bucket Names

Default bucket names used by the solution:

```
Cost_Usage_Reports_Staging
Cost_Usage_Reports
```

Customers **can change these bucket names** during Terraform deployment.

However, if bucket names are changed, ensure they are updated in all relevant locations:

* Terraform configuration files
* Function configuration
* Python function code that references the bucket
* Object Storage event rules
* SQL pipeline configuration

If these references are not updated, the pipeline will fail to locate the files.

---

# Phase 3 — Load Cost Data into Autonomous Database

Once the processed files are written into:

```
Cost_Usage_Reports
```

the SQL scripts in this repository load the data into Autonomous Database.

---

# Database Setup

Run the SQL scripts in the following order.

---

## Step 1 — Create Cost Data Table

```
01_create_table.sql
```

Creates the table:

```
OCI_COST_DATA
```

This table stores processed cost report data.

---

## Step 2 — Create Indexes (Optional but Recommended)

```
02_optional_indexes.sql
```

Creates indexes to improve query performance.

Indexes include:

* billing period
* service
* region
* compartment

---

## Step 3 — Create Object Storage Credential

Before creating the pipeline, the database must be able to access Object Storage.

Create an OCI credential in the database:

```sql
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'OBJECT_STORE_CRED',
    username        => '<oci_user_or_auth_token_user>',
    password        => '<auth_token>'
  );
END;
/
```

### Why this is required

The database pipeline reads files directly from **OCI Object Storage**.

The credential allows **DBMS_CLOUD_PIPELINE** to authenticate and access the bucket containing the processed cost report files.

You must create this credential **before running the pipeline setup script**.

---

## Step 4 — Create Data Load Pipeline

```
03_setup_pipeline.sql
```

Creates and starts:

```
OCI_COST_PIPELINE
```

The pipeline continuously loads processed cost files from Object Storage into the database table.

Source location:

```
Cost_Usage_Reports bucket
```

---

## Step 5 — Validate Pipeline (Optional)

```
04_optional_validate_pipeline.sql
```

This script verifies that:

* the pipeline is running
* files are processed
* data is inserted into the table

Example:

```sql
SELECT COUNT(*) FROM OCI_COST_DATA;
```

---

# Materialized View

## Step 6 — Create Aggregated Cost View

```
05_create_materialized_view.sql
```

Creates the materialized view:

```
OCI_DAILY_COST_MV
```

---

## Why a Materialized View is Used

Cost report tables can grow very large over time because they contain detailed usage records.

Queries that aggregate costs across services, regions, compartments, and resources can become slow when scanning the raw data table.

The materialized view solves this problem by:

* Pre-aggregating cost data daily
* Reducing query complexity
* Improving dashboard performance
* Avoiding full table scans on large datasets

This allows analytics tools like **Oracle Analytics Cloud (OAC)** to query summarized cost data efficiently.

---

## Automatic Refresh

A scheduler job refreshes the materialized view automatically.

Default refresh interval:

```
Every 3 hours
```

This keeps the aggregated cost data up to date while maintaining fast query performance.

---

# Monitoring

## Check Pipeline Status

```sql
SELECT *
FROM user_cloud_pipelines
WHERE pipeline_name = 'OCI_COST_PIPELINE';
```

---

## Check Load Operations

```sql
SELECT *
FROM user_load_operations
WHERE table_name = 'OCI_COST_DATA'
ORDER BY start_time DESC;
```

---

## Verify Data Load

```sql
SELECT COUNT(*) FROM OCI_COST_DATA;
```

---

## Check Materialized View Refresh

```sql
SELECT
mview_name,
last_refresh_date
FROM user_mviews
WHERE mview_name = 'OCI_DAILY_COST_MV';
```

---

# Reporting with Oracle Analytics Cloud

Once the pipeline is running:

1. Connect **Oracle Analytics Cloud (OAC)** to the Autonomous Database
2. Use the aggregated table:

```
OCI_DAILY_COST_MV
```

3. Build dashboards for:

* cost by service
* cost by compartment
* regional cost distribution
* tag-based cost allocation
* daily cost trends

---

# Summary

The pipeline provides a fully automated FinOps data platform:

1. Terraform copies cost reports nightly
2. Functions process and enrich the data
3. Processed files are written to Object Storage
4. Database pipelines load the data automatically
5. Materialized views aggregate daily costs
6. OAC dashboards provide cost insights

