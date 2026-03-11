# Copyright (c) 2025, Oracle and/or its affiliates. All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# ORM injects this automatically; not shown in the UI form
variable "tenancy_ocid" {}

variable "region" {
  description = "OCI region identifier (e.g. us-ashburn-1)"
  type        = string
}

# ── Network ──────────────────────────────────────────────────────────────────
variable "compartment_ocid" {
  description = "Compartment where all resources are created"
  type        = string
}

variable "vcn_ocid" {
  description = "VCN OCID (UI dropdown)"
  type        = string
}

variable "subnet_ocid" {
  description = "Subnet OCID for the Functions Application (UI dropdown)"
  type        = string
}

# ── OCIR ─────────────────────────────────────────────────────────────────────
variable "ocir_username" {
  description = "OCIR login username (e.g. oracleidentitycloudservice/<email>)"
  type        = string
}

variable "ocir_password" {
  description = "OCI Auth Token for OCIR"
  type        = string
  sensitive   = true
}

variable "repository_name" {
  description = "OCIR repository name"
  type        = string
  default     = "focus-reports-repo"
}

# ── Functions Application & Function names ────────────────────────────────────
variable "app_display_name" {
  description = "Display name for the OCI Functions Application"
  type        = string
  default     = "focus-reports-app"
}

variable "create_functions_application" {
  description = "Set to true to create a new Functions Application, false to use an existing one"
  type        = bool
  default     = true
}

variable "existing_application_ocid" {
  description = "OCID of an existing Functions Application (used when create_functions_application = false)"
  type        = string
  default     = ""
}

variable "function_display_name" {
  description = "Display name for the OCI Function"
  type        = string
  default     = "process-focus-reports"
}

# ── Function tuning ───────────────────────────────────────────────────────────
variable "function_memory_in_mbs" {
  description = "Memory allocated to the function (MB) – overridden by func.yaml if set"
  type        = number
  default     = 2048
}

variable "function_timeout_in_seconds" {
  description = "Function execution timeout (seconds) – overridden by func.yaml if set"
  type        = number
  default     = 300
}

variable "function_parameters_json_string" {
  description = "Optional JSON string of extra function config key-value pairs"
  type        = string
  default     = ""
}

# ── Events Rule ───────────────────────────────────────────────────────────────
variable "event_rule_display_name" {
  description = "Display name for the OCI Events rule"
  type        = string
  default     = "focus-report-staging-trigger"
}

variable "event_rule_is_enabled" {
  description = "Whether the Events rule is active immediately after creation"
  type        = bool
  default     = true
}

variable "staging_bucket_name" {
  description = "Object Storage bucket name to watch for new FOCUS report uploads"
  type        = string
  default     = "Cost_Usage_Reports_Staging"
}

# ── Internal – not shown in UI ────────────────────────────────────────────────
variable "function_working_dir" {
  description = "Path to the directory containing func.py, func.yaml, requirements.txt"
  type        = string
  default     = "./function"
}

