############################################################
# Fixed Bucket Name
############################################################

locals {
  cost_usage_reports_bucket_name = "Cost_Usage_Reports"
}

############################################################
# Object Storage Bucket
############################################################

resource "oci_objectstorage_bucket" "cost_usage_reports" {

  compartment_id = var.compartment_ocid
  name           = local.cost_usage_reports_bucket_name

  namespace = data.oci_objectstorage_namespace.ns.namespace

  access_type  = "NoPublicAccess"
  storage_tier = "Standard"

  versioning   = "Disabled"
  auto_tiering = "Disabled"
}

############################################################
# Outputs
############################################################

output "cost_usage_reports_bucket_name" {
  value = local.cost_usage_reports_bucket_name
}

output "object_storage_namespace" {
  value = data.oci_objectstorage_namespace.ns.namespace
}