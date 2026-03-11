# Copyright (c) 2025, Oracle and/or its affiliates. All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# ─────────────────────────────────────────────────────────────────────────────
# events.tf
#
# Creates an OCI Events rule that fires on Object Storage "createobject" events
# scoped to the staging bucket (Cost_Usage_Reports_Staging) and invokes the
# process-focus-reports OCI Function as the action.
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_events_rule" "focus_report_trigger" {
  compartment_id = var.compartment_ocid
  display_name   = var.event_rule_display_name
  description    = "Triggers the process-focus-reports function when a new .csv.gz file lands in the staging bucket"
  is_enabled     = var.event_rule_is_enabled

  # ── Event condition ────────────────────────────────────────────────────────
  # Matches only ObjectStorage createobject events where the bucket name equals
  # the configured staging bucket name.  The namespace filter is intentionally
  # omitted so the rule works across namespace renames.
  condition = jsonencode({
    eventType = ["com.oraclecloud.objectstorage.createobject"]
    data = {
      additionalDetails = {
        bucketName = [var.staging_bucket_name]
      }
    }
  })

  # ── Actions ───────────────────────────────────────────────────────────────
  actions {
    actions {
      action_type = "FAAS"
      is_enabled  = true
      function_id = oci_functions_function.this.id
      description = "Invoke process-focus-reports to enrich and copy the FOCUS report"
    }
  }

  lifecycle {
    ignore_changes = [defined_tags]
  }
}
