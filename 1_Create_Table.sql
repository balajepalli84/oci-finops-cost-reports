CREATE TABLE OCI_COST_DATA (
    Source_Tenant_Name                  VARCHAR2(256),
    Source_File_Id                      VARCHAR2(512),

    BillingAccountId                    VARCHAR2(256),
    BillingAccountName                  VARCHAR2(256),
    BillingAccountType                  VARCHAR2(128),

    SubAccountId                        VARCHAR2(256),
    SubAccountName                      VARCHAR2(256),
    SubAccountType                      VARCHAR2(128),

    InvoiceId                           VARCHAR2(256),
    InvoiceIssuer                       VARCHAR2(256),
    Provider                            VARCHAR2(128),
    Publisher                           VARCHAR2(256),

    PricingCategory                     VARCHAR2(128),
    PricingCurrencyContractedUnitPrice  NUMBER,
    PricingCurrencyEffectiveCost        NUMBER,
    PricingCurrencyListUnitPrice        NUMBER,
    PricingQuantity                     NUMBER,
    PricingUnit                         VARCHAR2(128),

    BillingPeriodStart                  DATE,
    BillingPeriodEnd                    DATE,

    ChargePeriodStart                   VARCHAR2(20),
    ChargePeriodEnd                     VARCHAR2(20),

    BilledCost                          NUMBER,
    BillingCurrency                     VARCHAR2(16),
    ConsumedQuantity                    NUMBER,
    ConsumedUnit                        VARCHAR2(128),
    ContractedCost                      NUMBER,
    ContractedUnitPrice                 NUMBER,
    EffectiveCost                       NUMBER,
    ListCost                            NUMBER,
    ListUnitPrice                       NUMBER,

    AvailabilityZone                    VARCHAR2(128),
    Region                              VARCHAR2(128),
    RegionName                          VARCHAR2(256),

    ResourceId                          VARCHAR2(1024),
    ResourceName                        VARCHAR2(512),
    ResourceType                        VARCHAR2(256),

    Tags                                VARCHAR2(4000),

    ServiceCategory                     VARCHAR2(256),
    ServiceSubCategory                  VARCHAR2(256),
    ServiceName                         VARCHAR2(256),

    CapacityReservationId               VARCHAR2(512),
    CapacityReservationStatus           VARCHAR2(128),

    ChargeCategory                      VARCHAR2(128),
    ChargeClass                         VARCHAR2(128),
    ChargeDescription                   VARCHAR2(1024),
    ChargeFrequency                     VARCHAR2(128),

    CommitmentDiscountCategory          VARCHAR2(128),
    CommitmentDiscountId                VARCHAR2(512),
    CommitmentDiscountName              VARCHAR2(512),
    CommitmentDiscountQuantity          NUMBER,
    CommitmentDiscountStatus            VARCHAR2(128),
    CommitmentDiscountType              VARCHAR2(128),
    CommitmentDiscountUnit              VARCHAR2(128),

    SkuId                               VARCHAR2(256),
    SkuPriceId                          VARCHAR2(256),
    SkuPriceDetails                     VARCHAR2(1024),
    SkuMeter                            VARCHAR2(256),

    UsageQuantity                       NUMBER,
    UsageUnit                           VARCHAR2(128),

    oci_ReferenceNumber                 VARCHAR2(256),
    oci_CompartmentId                   VARCHAR2(512),
    oci_CompartmentName                 VARCHAR2(512),
    oci_CompartmentPath                 VARCHAR2(2000),
    oci_OverageFlag                     VARCHAR2(16),
    oci_UnitPriceOverage                NUMBER,
    oci_BilledQuantityOverage           NUMBER,
    oci_CostOverage                     NUMBER,
    oci_AttributedUsage                 NUMBER,
    oci_AttributedCost                  NUMBER,
    oci_BackReferenceNumber             VARCHAR2(256),

    Tag_Special1                        VARCHAR2(4000),
    Tag_Special2                        VARCHAR2(4000),
    Tag_Special3                        VARCHAR2(4000),
    Tag_Special4                        VARCHAR2(4000)
);
/
