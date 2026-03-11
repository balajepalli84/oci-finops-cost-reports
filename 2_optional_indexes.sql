CREATE INDEX idx_cost_period       ON OCI_COST_DATA (BillingPeriodStart, BillingPeriodEnd);
CREATE INDEX idx_cost_service      ON OCI_COST_DATA (ServiceName, ServiceCategory);
CREATE INDEX idx_cost_region       ON OCI_COST_DATA (Region);
CREATE INDEX idx_cost_compartment  ON OCI_COST_DATA (oci_CompartmentId);
CREATE INDEX idx_cost_tenant       ON OCI_COST_DATA (Source_Tenant_Name);
