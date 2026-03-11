import csv
import gzip
import io
import json
import logging
import os

import oci
from fdk import response

TARGET_BUCKET = os.environ.get("TARGET_BUCKET", "Cost_Usage_Reports")
TAG_SPECIAL1_KEY = os.environ.get("TAG_SPECIAL1_KEY", "Usage-Management/Creator")

OUTPUT_COLUMNS = [
    "Source_Tenant_Name", "Source_File_Id",
    "BillingAccountId", "BillingAccountName", "BillingAccountType",
    "SubAccountId", "SubAccountName", "SubAccountType",
    "InvoiceId", "InvoiceIssuer", "Provider", "Publisher",
    "PricingCategory",
    "PricingCurrencyContractedUnitPrice",
    "PricingCurrencyEffectiveCost",
    "PricingCurrencyListUnitPrice",
    "PricingQuantity", "PricingUnit",
    "BillingPeriodStart", "BillingPeriodEnd",
    "ChargePeriodStart", "ChargePeriodEnd",
    "BilledCost", "BillingCurrency",
    "ConsumedQuantity", "ConsumedUnit",
    "ContractedCost", "ContractedUnitPrice",
    "EffectiveCost", "ListCost", "ListUnitPrice",
    "AvailabilityZone", "Region", "RegionName",
    "ResourceId", "ResourceName", "ResourceType",
    "Tags",
    "ServiceCategory", "ServiceSubCategory", "ServiceName",
    "CapacityReservationId", "CapacityReservationStatus",
    "ChargeCategory", "ChargeClass", "ChargeDescription", "ChargeFrequency",
    "CommitmentDiscountCategory", "CommitmentDiscountId",
    "CommitmentDiscountName", "CommitmentDiscountQuantity",
    "CommitmentDiscountStatus", "CommitmentDiscountType", "CommitmentDiscountUnit",
    "SkuId", "SkuPriceId", "SkuPriceDetails", "SkuMeter",
    "UsageQuantity", "UsageUnit",
    "oci_ReferenceNumber", "oci_CompartmentId", "oci_CompartmentName",
    "oci_CompartmentPath", "oci_OverageFlag",
    "oci_UnitPriceOverage", "oci_BilledQuantityOverage",
    "oci_CostOverage", "oci_AttributedUsage", "oci_AttributedCost",
    "oci_BackReferenceNumber",
    "Tag_Special1", "Tag_Special2", "Tag_Special3", "Tag_Special4",
]


def col(column, row):
    value = row.get(column, "")
    return "" if value is None else value


def safe(value):
    """
    Make values safe for Oracle CSV load:
    - convert None to empty string
    - remove null bytes
    - flatten embedded CR/LF into spaces
    - trim outer whitespace only if needed
    """
    if value is None:
        return ""

    if not isinstance(value, str):
        value = str(value)

    value = value.replace("\x00", "")
    value = value.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")

    return value


def safe_date(value):
    value = safe(value)
    return value[:10] if len(value) >= 10 else value


def safe_datetime_min(value):
    """
    Convert '2025-01-01T12:34:56.000Z' -> '2025-01-01 12:34'
    """
    value = safe(value)
    if len(value) >= 16:
        return f"{value[0:10]} {value[11:16]}"
    return value


def load_compartment_paths(identity, tenancy_id, tenancy_name):
    compartments = {tenancy_id: f"/ {tenancy_name} (root)"}
    try:
        all_comps = oci.pagination.list_call_get_all_results(
            identity.list_compartments,
            tenancy_id,
            compartment_id_in_subtree=True
        ).data

        children_by_parent = {}
        for comp in all_comps:
            parent_id = str(comp.compartment_id)
            children_by_parent.setdefault(parent_id, []).append(comp)

        def build_nested(parent_id, path):
            for comp in children_by_parent.get(str(parent_id), []):
                if comp.lifecycle_state == oci.identity.models.Compartment.LIFECYCLE_STATE_ACTIVE:
                    full = f"{path} / {comp.name}" if path else comp.name
                    compartments[str(comp.id)] = full
                    build_nested(comp.id, full)

        build_nested(tenancy_id, "")
    except Exception as e:
        logging.warning(f"Error loading compartments: {e}")
    return compartments


def enrich_and_upload(object_storage, namespace, source_bucket,
                      object_name, tenancy_name, compartment_paths):
    file_id = object_name.rsplit("/", 1)[-1].replace(".csv.gz", "")
    output_buffer = io.BytesIO()

    resp = object_storage.get_object(namespace, source_bucket, object_name)
    raw_bytes = resp.data.content

    with gzip.open(io.BytesIO(raw_bytes), mode="rt", encoding="utf-8-sig", newline="") as fin, \
         gzip.open(output_buffer, mode="wt", encoding="utf-8", newline="") as fout:

        reader = csv.DictReader(fin)

        # Standard CSV output. This is what you want for OCI loads.
        writer = csv.DictWriter(
            fout,
            fieldnames=OUTPUT_COLUMNS,
            extrasaction="ignore",
            delimiter=",",
            quotechar='"',
            quoting=csv.QUOTE_ALL,
            lineterminator="\n",
            doublequote=True
        )

        writer.writeheader()
        row_count = 0

        for row in reader:
            cid = safe(col("oci_CompartmentId", row))
            path = safe(compartment_paths.get(cid, ""))

            tags_data = ""
            tag_special1 = ""

            raw_tags = col("Tags", row)
            if raw_tags:
                try:
                    parsed_tags = json.loads(raw_tags)
                    if isinstance(parsed_tags, dict):
                        entries = []
                        for k, v in parsed_tags.items():
                            k = safe(k)
                            v = safe(v)

                            if k == TAG_SPECIAL1_KEY:
                                tag_special1 = v.replace("oracleidentitycloudservice/", "")[:4000]

                            entries.append(f"{k}={v}")

                        tags_data = "#".join(entries)[:4000]
                except Exception as e:
                    logging.warning(f"Could not parse Tags JSON in file {object_name}: {e}")

            out_row = {
                "Source_Tenant_Name": safe(tenancy_name),
                "Source_File_Id": safe(file_id),

                "BillingAccountId": safe(col("BillingAccountId", row)),
                "BillingAccountName": safe(col("BillingAccountName", row)),
                "BillingAccountType": safe(col("BillingAccountType", row)),
                "SubAccountId": safe(col("SubAccountId", row)),
                "SubAccountName": safe(col("SubAccountName", row)),
                "SubAccountType": safe(col("SubAccountType", row)),
                "InvoiceId": safe(col("InvoiceId", row)),
                "InvoiceIssuer": safe(col("InvoiceIssuer", row)),
                "Provider": safe(col("Provider", row)),
                "Publisher": safe(col("Publisher", row)),
                "PricingCategory": safe(col("PricingCategory", row)),
                "PricingCurrencyContractedUnitPrice": safe(col("PricingCurrencyContractedUnitPrice", row)),

                # Handles the bad source key with a trailing space
                "PricingCurrencyEffectiveCost": safe(
                    col("PricingCurrencyEffectiveCost ", row) or col("PricingCurrencyEffectiveCost", row)
                ),

                "PricingCurrencyListUnitPrice": safe(col("PricingCurrencyListUnitPrice", row)),
                "PricingQuantity": safe(col("PricingQuantity", row)),
                "PricingUnit": safe(col("PricingUnit", row)),
                "BillingPeriodStart": safe_date(col("BillingPeriodStart", row)),
                "BillingPeriodEnd": safe_date(col("BillingPeriodEnd", row)),
                "ChargePeriodStart": safe_datetime_min(col("ChargePeriodStart", row)),
                "ChargePeriodEnd": safe_datetime_min(col("ChargePeriodEnd", row)),
                "BilledCost": safe(col("BilledCost", row)),
                "BillingCurrency": safe(col("BillingCurrency", row)),
                "ConsumedQuantity": safe(col("ConsumedQuantity", row)),
                "ConsumedUnit": safe(col("ConsumedUnit", row)),
                "ContractedCost": safe(col("ContractedCost", row)),
                "ContractedUnitPrice": safe(col("ContractedUnitPrice", row)),
                "EffectiveCost": safe(col("EffectiveCost", row)),
                "ListCost": safe(col("ListCost", row)),
                "ListUnitPrice": safe(col("ListUnitPrice", row)),
                "AvailabilityZone": safe(col("AvailabilityZone", row)),
                "Region": safe(col("Region", row)),
                "RegionName": safe(col("RegionName", row)),
                "ResourceId": safe(col("ResourceId", row)),
                "ResourceName": safe(col("ResourceName", row)),
                "ResourceType": safe(col("ResourceType", row)),
                "Tags": safe(tags_data),
                "ServiceCategory": safe(col("ServiceCategory", row)),
                "ServiceSubCategory": safe(col("ServiceSubCategory", row)),
                "ServiceName": safe(col("ServiceName", row)),
                "CapacityReservationId": safe(col("CapacityReservationId", row)),
                "CapacityReservationStatus": safe(col("CapacityReservationStatus", row)),
                "ChargeCategory": safe(col("ChargeCategory", row)),
                "ChargeClass": safe(col("ChargeClass", row)),
                "ChargeDescription": safe(col("ChargeDescription", row)),
                "ChargeFrequency": safe(col("ChargeFrequency", row)),
                "CommitmentDiscountCategory": safe(col("CommitmentDiscountCategory", row)),
                "CommitmentDiscountId": safe(col("CommitmentDiscountId", row)),
                "CommitmentDiscountName": safe(col("CommitmentDiscountName", row)),
                "CommitmentDiscountQuantity": safe(col("CommitmentDiscountQuantity", row)),
                "CommitmentDiscountStatus": safe(col("CommitmentDiscountStatus", row)),
                "CommitmentDiscountType": safe(col("CommitmentDiscountType", row)),
                "CommitmentDiscountUnit": safe(col("CommitmentDiscountUnit", row)),
                "SkuId": safe(col("SkuId", row)),
                "SkuPriceId": safe(col("SkuPriceId", row)),
                "SkuPriceDetails": safe(col("SkuPriceDetails", row)),
                "SkuMeter": safe(col("SkuMeter", row)),
                "UsageQuantity": safe(col("UsageQuantity", row)),
                "UsageUnit": safe(col("UsageUnit", row)),
                "oci_ReferenceNumber": safe(col("oci_ReferenceNumber", row)),
                "oci_CompartmentId": cid,
                "oci_CompartmentName": safe(col("oci_CompartmentName", row)),
                "oci_CompartmentPath": path,
                "oci_OverageFlag": safe(col("oci_OverageFlag", row)),
                "oci_UnitPriceOverage": safe(col("oci_UnitPriceOverage", row)),
                "oci_BilledQuantityOverage": safe(col("oci_BilledQuantityOverage", row)),
                "oci_CostOverage": safe(col("oci_CostOverage", row)),
                "oci_AttributedUsage": safe(col("oci_AttributedUsage", row)),
                "oci_AttributedCost": safe(col("oci_AttributedCost", row)),
                "oci_BackReferenceNumber": safe(col("oci_BackReferenceNumber", row)),
                "Tag_Special1": safe(tag_special1),
                "Tag_Special2": "",
                "Tag_Special3": "",
                "Tag_Special4": "",
            }

            writer.writerow(out_row)
            row_count += 1

    output_buffer.seek(0)
    object_storage.put_object(
        namespace,
        TARGET_BUCKET,
        object_name,
        output_buffer.getvalue(),
        content_type="application/gzip"
    )

    logging.info(f"Uploaded {object_name} -> {TARGET_BUCKET} | {row_count} rows")
    return row_count


# OCI clients — initialized once per warm container
_signer = _object_storage = _identity = None
_tenancy_id = _tenancy_name = _compartment_paths = None


def _init():
    global _signer, _object_storage, _identity
    global _tenancy_id, _tenancy_name, _compartment_paths

    if _signer is not None:
        return

    _signer = oci.auth.signers.get_resource_principals_signer()
    _object_storage = oci.object_storage.ObjectStorageClient(config={}, signer=_signer)
    _identity = oci.identity.IdentityClient(config={}, signer=_signer)
    _tenancy_id = _signer.tenancy_id
    _tenancy_name = _identity.get_tenancy(_tenancy_id).data.name
    _compartment_paths = load_compartment_paths(_identity, _tenancy_id, _tenancy_name)

    logging.info(f"Init complete: {len(_compartment_paths)} compartments")


def handler(ctx, data: io.BytesIO = None):
    logging.getLogger().setLevel(logging.INFO)
    try:
        _init()

        body = json.loads(data.getvalue())
        object_name = body["data"]["resourceName"]
        namespace = body["data"]["additionalDetails"]["namespace"]
        source_bucket = body["data"]["additionalDetails"]["bucketName"]

        logging.info(f"Processing: {object_name}")

        if not object_name.endswith(".csv.gz"):
            return response.Response(ctx, response_data="skipped", status_code=200)

        rows = enrich_and_upload(
            _object_storage,
            namespace,
            source_bucket,
            object_name,
            _tenancy_name,
            _compartment_paths
        )

        return response.Response(
            ctx,
            response_data=json.dumps({"status": "ok", "rows": rows, "file": object_name}),
            headers={"Content-Type": "application/json"},
            status_code=200
        )

    except Exception as e:
        logging.exception("Handler failed")
        return response.Response(
            ctx,
            response_data=json.dumps({"status": "error", "message": str(e)}),
            headers={"Content-Type": "application/json"},
            status_code=500
        )