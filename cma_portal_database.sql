-- =====================================================================
-- CMA Online Regulatory and Licensing Portal — Physical Database Schema
-- Group 11 · Database Design Specification, Appendix A
-- Target DBMS: PostgreSQL 16 or later
-- One schema per subsystem (M1–M9) plus the audit store and reporting.
-- Run as a database owner on an empty database:  psql -f cma_portal_database.sql
-- =====================================================================

\set ON_ERROR_STOP on
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- fuzzy search on the public register

CREATE SCHEMA iam;   -- M1 Identity and Account Management
CREATE SCHEMA cfg;   -- M9 Configuration (categories, checklists, fees, workflow, returns)
CREATE SCHEMA app;   -- M2 Application and Approval Management
CREATE SCHEMA doc;   -- M3 Document Management
CREATE SCHEMA wf;    -- M4 Workflow and Case Management
CREATE SCHEMA fin;   -- M5 Fee Assessment and Payment
CREATE SCHEMA lic;   -- M6 Licence and Register Management
CREATE SCHEMA cmp;   -- M7 Regulatory Returns and Compliance
CREATE SCHEMA ntf;   -- M8 Communication and Notification
CREATE SCHEMA aud;   -- Audit Log Store (append-only)
CREATE SCHEMA rpt;   -- M9 Reporting views

-- =====================================================================
-- M1  IDENTITY AND ACCOUNT MANAGEMENT  (iam)
-- =====================================================================

CREATE TABLE iam.person (
    person_id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name               varchar(200) NOT NULL,
    national_id_type        varchar(12)  NOT NULL DEFAULT 'NATIONAL_ID'
                            CHECK (national_id_type IN ('NATIONAL_ID','PASSPORT','ALIEN_ID')),
    national_id_number      varchar(30)  NOT NULL,
    nationality             char(2)      NOT NULL DEFAULT 'KE',
    date_of_birth           date,
    email_address           varchar(254) NOT NULL,
    mobile_number           varchar(16)  NOT NULL CHECK (mobile_number ~ '^\+[1-9][0-9]{7,14}$'),
    id_verification_status  varchar(10)  NOT NULL DEFAULT 'PENDING'
                            CHECK (id_verification_status IN ('PENDING','VERIFIED','FAILED')),
    created_at              timestamptz  NOT NULL DEFAULT now(),
    updated_at              timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_person_identity UNIQUE (national_id_type, national_id_number)
);
CREATE UNIQUE INDEX uq_person_email ON iam.person (lower(email_address));

CREATE TABLE iam.entity (
    entity_id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    registered_name         varchar(250) NOT NULL,
    registration_number     varchar(50)  NOT NULL UNIQUE,
    kra_pin                 char(11)     NOT NULL UNIQUE CHECK (kra_pin ~ '^[A-Z][0-9]{9}[A-Z]$'),
    entity_form             varchar(20)  NOT NULL
                            CHECK (entity_form IN ('PRIVATE_COMPANY','PUBLIC_COMPANY','LLP','PARTNERSHIP','FOREIGN_COMPANY','OTHER')),
    registered_office       varchar(500) NOT NULL,
    paid_up_capital         numeric(18,2) CHECK (paid_up_capital >= 0),
    verification_status     varchar(10)  NOT NULL DEFAULT 'PENDING'
                            CHECK (verification_status IN ('PENDING','VERIFIED','FAILED')),
    created_at              timestamptz  NOT NULL DEFAULT now(),
    updated_at              timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX ix_entity_name_trgm ON iam.entity USING gin (registered_name gin_trgm_ops);

CREATE TABLE iam.entity_key_person (
    entity_key_person_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id               uuid NOT NULL REFERENCES iam.entity,
    person_id               uuid NOT NULL REFERENCES iam.person,
    key_person_role         varchar(25) NOT NULL
                            CHECK (key_person_role IN ('DIRECTOR','CHIEF_EXECUTIVE','COMPLIANCE_OFFICER','SIGNIFICANT_SHAREHOLDER','OTHER_KEY_PERSON')),
    shareholding_percent    numeric(5,2) CHECK (shareholding_percent BETWEEN 0 AND 100),
    approval_status         varchar(10) NOT NULL DEFAULT 'PENDING'
                            CHECK (approval_status IN ('PENDING','APPROVED','REJECTED','CEASED')),
    approved_by_application_id uuid,                 -- FK added after app.application
    appointed_on            date,
    ceased_on               date,
    CHECK (ceased_on IS NULL OR ceased_on >= appointed_on)
);
CREATE UNIQUE INDEX uq_entity_key_person_current
    ON iam.entity_key_person (entity_id, person_id, key_person_role) WHERE ceased_on IS NULL;
CREATE INDEX ix_entity_key_person_person ON iam.entity_key_person (person_id);

CREATE TABLE iam.account (
    account_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id               uuid NOT NULL REFERENCES iam.person,
    entity_id               uuid REFERENCES iam.entity,
    account_type            varchar(10) NOT NULL CHECK (account_type IN ('INDIVIDUAL','CORPORATE','INTERNAL','SYSTEM')),
    parent_account_id       uuid REFERENCES iam.account,       -- subordinate user of a corporate account
    password_hash           varchar(255),                      -- argon2id; NULL for SSO-only internal users
    mfa_secret_enc          bytea,                             -- encrypted by the Identity Service key
    status                  varchar(22) NOT NULL DEFAULT 'PENDING_VERIFICATION'
                            CHECK (status IN ('PENDING_VERIFICATION','ACTIVE','SUSPENDED','CLOSED')),
    email_verified_at       timestamptz,
    mobile_verified_at      timestamptz,
    failed_login_count      smallint NOT NULL DEFAULT 0,
    locked_until            timestamptz,
    suspended_reason        varchar(500),
    last_login_at           timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_account_corporate_scope CHECK ((account_type = 'CORPORATE') = (entity_id IS NOT NULL)),
    CONSTRAINT ck_account_activation      CHECK (status <> 'ACTIVE' OR account_type IN ('INTERNAL','SYSTEM')
                                                 OR (email_verified_at IS NOT NULL AND mobile_verified_at IS NOT NULL)),
    CONSTRAINT ck_account_suspension      CHECK (status <> 'SUSPENDED' OR suspended_reason IS NOT NULL),
    CONSTRAINT uq_account_person_entity   UNIQUE NULLS NOT DISTINCT (person_id, entity_id, account_type)
);
CREATE INDEX ix_account_entity ON iam.account (entity_id);

CREATE TABLE iam.role (
    role_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role_code               varchar(30) NOT NULL UNIQUE,
    role_name               varchar(100) NOT NULL,
    is_internal             boolean NOT NULL
);

CREATE TABLE iam.permission (
    permission_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    permission_code         varchar(50) NOT NULL UNIQUE,
    description             varchar(200) NOT NULL
);

CREATE TABLE iam.role_permission (
    role_id                 uuid NOT NULL REFERENCES iam.role,
    permission_id           uuid NOT NULL REFERENCES iam.permission,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE iam.account_role (
    account_id              uuid NOT NULL REFERENCES iam.account,
    role_id                 uuid NOT NULL REFERENCES iam.role,
    granted_by_account_id   uuid REFERENCES iam.account,
    granted_at              timestamptz NOT NULL DEFAULT now(),
    revoked_at              timestamptz,
    PRIMARY KEY (account_id, role_id)
);

CREATE TABLE iam.adviser_authorisation (
    authorisation_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    adviser_account_id      uuid NOT NULL REFERENCES iam.account,
    entity_id               uuid NOT NULL REFERENCES iam.entity,
    granted_by_account_id   uuid NOT NULL REFERENCES iam.account,
    can_prepare             boolean NOT NULL DEFAULT false,
    can_submit              boolean NOT NULL DEFAULT false,
    can_pay                 boolean NOT NULL DEFAULT false,
    can_view                boolean NOT NULL DEFAULT true,
    valid_from              date NOT NULL,
    valid_to                date NOT NULL,
    revoked_at              timestamptz,
    CHECK (valid_to >= valid_from),
    CHECK (can_prepare OR can_submit OR can_pay OR can_view)
);
CREATE INDEX ix_adviser_auth_lookup ON iam.adviser_authorisation (adviser_account_id, entity_id);

CREATE TABLE iam.external_verification (
    verification_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id               uuid REFERENCES iam.person,
    entity_id               uuid REFERENCES iam.entity,
    service_code            varchar(5) NOT NULL CHECK (service_code IN ('IPRS','BRS','KRA')),
    status                  varchar(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','VERIFIED','FAILED')),
    request_reference       varchar(64),
    requested_at            timestamptz NOT NULL DEFAULT now(),
    responded_at            timestamptz,
    result_summary          jsonb,
    CHECK (num_nonnulls(person_id, entity_id) = 1),
    CHECK (status = 'PENDING' OR responded_at IS NOT NULL)
);
CREATE INDEX ix_ext_verif_person ON iam.external_verification (person_id);
CREATE INDEX ix_ext_verif_entity ON iam.external_verification (entity_id);

-- =====================================================================
-- M9  CONFIGURATION  (cfg)
-- =====================================================================

CREATE TABLE cfg.licence_category (
    category_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_code           varchar(30)  NOT NULL UNIQUE,
    category_name           varchar(150) NOT NULL,
    legal_basis             varchar(300) NOT NULL,
    authorisation_kind      varchar(8)   NOT NULL CHECK (authorisation_kind IN ('LICENCE','APPROVAL')),
    applicant_kind          varchar(6)   NOT NULL CHECK (applicant_kind IN ('ENTITY','PERSON','EITHER')),
    validity_months         smallint     NOT NULL CHECK (validity_months > 0),
    eligibility_criteria    jsonb,
    is_active               boolean      NOT NULL DEFAULT true,
    created_at              timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE cfg.category_version (
    category_version_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id             uuid NOT NULL REFERENCES cfg.licence_category,
    version_no              integer NOT NULL CHECK (version_no > 0),
    status                  varchar(9) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PUBLISHED','RETIRED')),
    effective_from          date NOT NULL,
    effective_to            date,
    sla_target_days         smallint NOT NULL CHECK (sla_target_days > 0),
    sla_warning_pct         smallint NOT NULL DEFAULT 80 CHECK (sla_warning_pct BETWEEN 1 AND 100),
    created_by_account_id   uuid NOT NULL REFERENCES iam.account,
    created_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (category_id, version_no),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);
CREATE UNIQUE INDEX uq_category_one_published ON cfg.category_version (category_id) WHERE status = 'PUBLISHED';

CREATE TABLE cfg.document_type (
    document_type_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    type_code               varchar(40)  NOT NULL UNIQUE,
    type_name               varchar(150) NOT NULL,
    permitted_formats       text[]       NOT NULL DEFAULT ARRAY['application/pdf'],
    max_size_mb             smallint     NOT NULL DEFAULT 20 CHECK (max_size_mb BETWEEN 1 AND 200),
    retention_years         smallint     NOT NULL DEFAULT 7 CHECK (retention_years >= 1),
    validity_months         smallint     CHECK (validity_months > 0)
);

CREATE TABLE cfg.checklist_item (
    checklist_item_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_version_id     uuid NOT NULL REFERENCES cfg.category_version,
    item_code               varchar(20)  NOT NULL,
    description             varchar(500) NOT NULL,
    document_type_id        uuid NOT NULL REFERENCES cfg.document_type,
    is_mandatory            boolean NOT NULL DEFAULT true,
    statutory_reference     varchar(200),
    display_order           smallint NOT NULL,
    UNIQUE (category_version_id, item_code)
);

CREATE TABLE cfg.form_field (
    form_field_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_version_id     uuid NOT NULL REFERENCES cfg.category_version,
    field_code              varchar(40)  NOT NULL,
    label                   varchar(200) NOT NULL,
    data_type               varchar(7)   NOT NULL CHECK (data_type IN ('TEXT','NUMBER','DATE','BOOLEAN','CHOICE')),
    is_mandatory            boolean NOT NULL DEFAULT false,
    validation_regex        varchar(300),
    min_value               numeric(20,4),
    max_value               numeric(20,4),
    choice_values           text[],
    display_order           smallint NOT NULL,
    UNIQUE (category_version_id, field_code),
    CHECK (min_value IS NULL OR max_value IS NULL OR max_value >= min_value),
    CHECK (data_type <> 'CHOICE' OR choice_values IS NOT NULL)
);

CREATE TABLE cfg.fee_schedule (
    fee_schedule_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_version_id     uuid NOT NULL REFERENCES cfg.category_version,
    application_type        varchar(22) NOT NULL,
    fee_type                varchar(18) NOT NULL CHECK (fee_type IN ('APPLICATION','LICENCE','RENEWAL','ANNUAL_SUPERVISORY')),
    calculation_basis       varchar(18) NOT NULL CHECK (calculation_basis IN ('FIXED','PERCENT_OF_CAPITAL')),
    fixed_amount            numeric(14,2) CHECK (fixed_amount >= 0),
    rate_percent            numeric(7,4)  CHECK (rate_percent >= 0),
    minimum_amount          numeric(14,2),
    maximum_amount          numeric(14,2),
    late_penalty_percent    numeric(5,2) NOT NULL DEFAULT 0 CHECK (late_penalty_percent >= 0),
    invoice_lead_days       smallint NOT NULL DEFAULT 30 CHECK (invoice_lead_days >= 0),
    currency                char(3) NOT NULL DEFAULT 'KES',
    UNIQUE (category_version_id, application_type, fee_type),
    CHECK ((calculation_basis = 'FIXED' AND fixed_amount IS NOT NULL)
        OR (calculation_basis = 'PERCENT_OF_CAPITAL' AND rate_percent IS NOT NULL))
);

CREATE TABLE cfg.workflow_stage (
    workflow_stage_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_version_id     uuid NOT NULL REFERENCES cfg.category_version,
    stage_code              varchar(16) NOT NULL
                            CHECK (stage_code IN ('REVIEW','RECOMMENDATION','LEGAL_CLEARANCE','APPROVAL','COMMITTEE','BOARD')),
    sequence_no             smallint NOT NULL CHECK (sequence_no > 0),
    is_mandatory            boolean  NOT NULL DEFAULT true,
    required_role_id        uuid NOT NULL REFERENCES iam.role,
    UNIQUE (category_version_id, sequence_no),
    UNIQUE (category_version_id, stage_code)
);

CREATE TABLE cfg.return_type (
    return_type_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    return_code             varchar(30)  NOT NULL UNIQUE,
    return_name             varchar(150) NOT NULL,
    is_quantitative         boolean NOT NULL,
    frequency               varchar(11)  NOT NULL CHECK (frequency IN ('MONTHLY','QUARTERLY','SEMI_ANNUAL','ANNUAL','AD_HOC')),
    days_after_period_end   smallint NOT NULL DEFAULT 0 CHECK (days_after_period_end >= 0)
);

CREATE TABLE cfg.returns_profile (
    category_version_id     uuid NOT NULL REFERENCES cfg.category_version,
    return_type_id          uuid NOT NULL REFERENCES cfg.return_type,
    PRIMARY KEY (category_version_id, return_type_id)
);

CREATE TABLE cfg.return_template_field (
    template_field_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    return_type_id          uuid NOT NULL REFERENCES cfg.return_type,
    field_code              varchar(40)  NOT NULL,
    label                   varchar(200) NOT NULL,
    data_type               varchar(6)   NOT NULL CHECK (data_type IN ('NUMBER','TEXT','DATE')),
    is_mandatory            boolean NOT NULL DEFAULT true,
    display_order           smallint NOT NULL,
    UNIQUE (return_type_id, field_code)
);

CREATE TABLE cfg.validation_rule (
    validation_rule_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    return_type_id          uuid NOT NULL REFERENCES cfg.return_type,
    rule_code               varchar(30)  NOT NULL,
    rule_kind               varchar(11)  NOT NULL CHECK (rule_kind IN ('ARITHMETIC','CONSISTENCY','THRESHOLD')),
    expression              text NOT NULL,
    failure_message         varchar(300) NOT NULL,
    on_failure              varchar(9)   NOT NULL CHECK (on_failure IN ('REJECT','EXCEPTION')),
    UNIQUE (return_type_id, rule_code)
);

CREATE TABLE cfg.notification_template (
    template_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type              varchar(40) NOT NULL,
    channel                 varchar(5)  NOT NULL CHECK (channel IN ('EMAIL','SMS')),
    version_no              integer NOT NULL DEFAULT 1,
    subject                 varchar(200),
    body                    text NOT NULL,
    is_statutory            boolean NOT NULL DEFAULT false,
    is_active               boolean NOT NULL DEFAULT true,
    UNIQUE (event_type, channel, version_no),
    CHECK (channel <> 'EMAIL' OR subject IS NOT NULL)
);
CREATE UNIQUE INDEX uq_template_active ON cfg.notification_template (event_type, channel) WHERE is_active;

CREATE TABLE cfg.status_transition (
    object_type             varchar(12) NOT NULL,
    from_status             varchar(22) NOT NULL,
    to_status               varchar(22) NOT NULL,
    PRIMARY KEY (object_type, from_status, to_status)
);

CREATE TABLE cfg.config_change (
    config_change_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_table            varchar(60) NOT NULL,
    object_id               uuid NOT NULL,
    change_type             varchar(7)  NOT NULL CHECK (change_type IN ('CREATE','UPDATE','RETIRE')),
    change_summary          varchar(500) NOT NULL,
    before_value            jsonb,
    after_value             jsonb,
    changed_by_account_id   uuid NOT NULL REFERENCES iam.account,
    changed_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_config_change_object ON cfg.config_change (object_table, object_id);

-- =====================================================================
-- M2  APPLICATION AND APPROVAL MANAGEMENT  (app)
-- =====================================================================

CREATE SEQUENCE app.application_ref_seq;

CREATE TABLE app.application (
    application_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reference_number        varchar(24) UNIQUE,                      -- issued on submission
    applicant_entity_id     uuid REFERENCES iam.entity,
    applicant_person_id     uuid REFERENCES iam.person,
    category_version_id     uuid NOT NULL REFERENCES cfg.category_version,
    application_type        varchar(22) NOT NULL
                            CHECK (application_type IN ('NEW','RENEWAL','VARIATION','ADDITIONAL_CATEGORY',
                                                        'CHANGE_OF_CONTROL','CHANGE_OF_KEY_PERSON','SURRENDER')),
    related_licence_id      uuid,                                    -- FK added after lic.licence
    status                  varchar(18) NOT NULL DEFAULT 'DRAFT'
                            CHECK (status IN ('DRAFT','SUBMITTED','PAID','UNDER_REVIEW','AWAITING_APPLICANT',
                                              'APPROVED','REJECTED','WITHDRAWN')),
    created_by_account_id   uuid NOT NULL REFERENCES iam.account,
    submitted_by_account_id uuid REFERENCES iam.account,
    created_at              timestamptz NOT NULL DEFAULT now(),
    last_saved_at           timestamptz NOT NULL DEFAULT now(),
    submitted_at            timestamptz,
    expected_decision_date  date,
    decided_at              timestamptz,
    retention_until         date,
    CONSTRAINT ck_application_applicant CHECK (num_nonnulls(applicant_entity_id, applicant_person_id) = 1),
    CONSTRAINT ck_application_submitted CHECK (status IN ('DRAFT','WITHDRAWN')
                                               OR (submitted_at IS NOT NULL AND reference_number IS NOT NULL)),
    CONSTRAINT ck_application_related   CHECK (application_type IN ('NEW','ADDITIONAL_CATEGORY')
                                               OR related_licence_id IS NOT NULL),
    CONSTRAINT ck_application_decided   CHECK (status NOT IN ('APPROVED','REJECTED') OR decided_at IS NOT NULL)
);
CREATE INDEX ix_application_entity  ON app.application (applicant_entity_id);
CREATE INDEX ix_application_person  ON app.application (applicant_person_id);
CREATE INDEX ix_application_status  ON app.application (status, submitted_at);
CREATE INDEX ix_application_version ON app.application (category_version_id);

CREATE TABLE app.application_field_value (
    application_id          uuid NOT NULL REFERENCES app.application ON DELETE CASCADE,
    form_field_id           uuid NOT NULL REFERENCES cfg.form_field,
    value_text              text,
    updated_at              timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (application_id, form_field_id)
);

CREATE TABLE app.key_person_declaration (
    declaration_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id          uuid NOT NULL REFERENCES app.application,
    person_id               uuid NOT NULL REFERENCES iam.person,
    key_person_role         varchar(25) NOT NULL
                            CHECK (key_person_role IN ('DIRECTOR','CHIEF_EXECUTIVE','COMPLIANCE_OFFICER','SIGNIFICANT_SHAREHOLDER','OTHER_KEY_PERSON')),
    shareholding_percent    numeric(5,2) CHECK (shareholding_percent BETWEEN 0 AND 100),
    has_criminal_conviction boolean NOT NULL,
    has_been_bankrupt       boolean NOT NULL,
    has_regulatory_sanction boolean NOT NULL,
    is_disqualified_director boolean NOT NULL,
    disclosure_notes        text,
    reused_from_declaration_id uuid REFERENCES app.key_person_declaration,
    confirmed_by_applicant  boolean NOT NULL DEFAULT false,
    declared_at             timestamptz NOT NULL DEFAULT now(),
    fit_proper_outcome      varchar(18) NOT NULL DEFAULT 'PENDING'
                            CHECK (fit_proper_outcome IN ('PENDING','FIT_AND_PROPER','NOT_FIT_AND_PROPER')),
    assessed_by_account_id  uuid REFERENCES iam.account,
    assessed_at             timestamptz,
    assessment_remarks      text,
    UNIQUE (application_id, person_id, key_person_role),
    CHECK (reused_from_declaration_id IS NULL OR confirmed_by_applicant),
    CHECK (fit_proper_outcome = 'PENDING' OR (assessed_by_account_id IS NOT NULL AND assessed_at IS NOT NULL))
);
CREATE INDEX ix_declaration_person ON app.key_person_declaration (person_id);

ALTER TABLE iam.entity_key_person
    ADD CONSTRAINT fk_ekp_application FOREIGN KEY (approved_by_application_id) REFERENCES app.application;

-- =====================================================================
-- M6  LICENCE AND REGISTER MANAGEMENT  (lic)
-- =====================================================================

CREATE TABLE lic.licence (
    licence_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_number          varchar(30) NOT NULL UNIQUE,
    holder_entity_id        uuid REFERENCES iam.entity,
    holder_person_id        uuid REFERENCES iam.person,
    category_id             uuid NOT NULL REFERENCES cfg.licence_category,
    issuing_decision_id     uuid UNIQUE,                    -- FK added after wf.decision
    previous_licence_id     uuid REFERENCES lic.licence,    -- the licence this one renews
    issue_date              date NOT NULL,
    expiry_date             date NOT NULL,
    status                  varchar(11) NOT NULL DEFAULT 'ACTIVE'
                            CHECK (status IN ('ACTIVE','SUSPENDED','REVOKED','SURRENDERED','LAPSED','RENEWED')),
    conditions              text,
    status_reason           varchar(500),
    status_effective_date   date,
    published_at            timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_licence_holder CHECK (num_nonnulls(holder_entity_id, holder_person_id) = 1),
    CONSTRAINT ck_licence_dates  CHECK (expiry_date > issue_date)
);
CREATE INDEX ix_licence_holder_entity ON lic.licence (holder_entity_id);
CREATE INDEX ix_licence_holder_person ON lic.licence (holder_person_id);
CREATE INDEX ix_licence_category_status ON lic.licence (category_id, status);
CREATE INDEX ix_licence_expiry_active ON lic.licence (expiry_date) WHERE status = 'ACTIVE';

CREATE TABLE lic.licence_status_history (
    history_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_id              uuid NOT NULL REFERENCES lic.licence,
    from_status             varchar(11),
    to_status               varchar(11) NOT NULL,
    reason                  varchar(500) NOT NULL,
    effective_date          date NOT NULL,
    changed_by_account_id   uuid NOT NULL REFERENCES iam.account,
    recorded_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_licence_history ON lic.licence_status_history (licence_id, recorded_at);

CREATE TABLE lic.certificate (
    certificate_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_id              uuid NOT NULL REFERENCES lic.licence,
    certificate_version     smallint NOT NULL DEFAULT 1,
    verification_code       varchar(32) NOT NULL UNIQUE,
    signature_value         text NOT NULL,
    signing_key_ref         varchar(100) NOT NULL,
    storage_key             varchar(500) NOT NULL,
    is_current              boolean NOT NULL DEFAULT true,
    generated_at            timestamptz NOT NULL DEFAULT now(),
    delivered_at            timestamptz,
    UNIQUE (licence_id, certificate_version)
);
CREATE UNIQUE INDEX uq_certificate_current ON lic.certificate (licence_id) WHERE is_current;

ALTER TABLE app.application
    ADD CONSTRAINT fk_application_related_licence FOREIGN KEY (related_licence_id) REFERENCES lic.licence;

-- =====================================================================
-- M3  DOCUMENT MANAGEMENT  (doc)   — file bytes live in the Document Store
-- =====================================================================

CREATE TABLE doc.document (
    document_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id          uuid REFERENCES app.application,
    return_id               uuid,                                 -- FK added after cmp.regulatory_return
    entity_id               uuid REFERENCES iam.entity,           -- owner, enables reuse
    checklist_item_id       uuid REFERENCES cfg.checklist_item,
    document_type_id        uuid NOT NULL REFERENCES cfg.document_type,
    current_version_no      smallint NOT NULL DEFAULT 1,
    review_status           varchar(22) NOT NULL DEFAULT 'PENDING'
                            CHECK (review_status IN ('PENDING','ACCEPTED','REJECTED','CLARIFICATION_REQUIRED')),
    review_comment          text,
    reviewed_by_account_id  uuid REFERENCES iam.account,
    reviewed_at             timestamptz,
    valid_until             date,
    retention_until         date,
    reused_from_document_id uuid REFERENCES doc.document,
    disposed_at             timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_document_parent    CHECK (num_nonnulls(application_id, return_id) = 1),
    CONSTRAINT ck_document_checklist CHECK (checklist_item_id IS NULL OR application_id IS NOT NULL),
    CONSTRAINT ck_document_comment   CHECK (review_status IN ('PENDING','ACCEPTED') OR review_comment IS NOT NULL)
);
CREATE INDEX ix_document_application ON doc.document (application_id, checklist_item_id);
CREATE INDEX ix_document_return      ON doc.document (return_id);
CREATE INDEX ix_document_entity      ON doc.document (entity_id, document_type_id);

CREATE TABLE doc.document_version (
    document_id             uuid NOT NULL REFERENCES doc.document,
    version_no              smallint NOT NULL CHECK (version_no > 0),
    storage_key             varchar(500) NOT NULL,
    file_name               varchar(255) NOT NULL,
    mime_type               varchar(100) NOT NULL,
    size_bytes              bigint NOT NULL CHECK (size_bytes > 0),
    sha256_hash             char(64) NOT NULL,
    scan_status             varchar(11) NOT NULL DEFAULT 'PENDING' CHECK (scan_status IN ('PENDING','CLEAN','QUARANTINED')),
    scanned_at              timestamptz,
    uploaded_by_account_id  uuid NOT NULL REFERENCES iam.account,
    uploaded_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, version_no)
);

-- =====================================================================
-- M4  WORKFLOW AND CASE MANAGEMENT  (wf)
-- =====================================================================

CREATE TABLE wf.queue (
    queue_id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    queue_name              varchar(100) NOT NULL UNIQUE,
    queue_kind              varchar(11) NOT NULL CHECK (queue_kind IN ('APPLICATION','COMPLIANCE')),
    category_id             uuid UNIQUE REFERENCES cfg.licence_category,
    supervisor_account_id   uuid NOT NULL REFERENCES iam.account,
    CHECK (queue_kind = 'COMPLIANCE' OR category_id IS NOT NULL)
);

CREATE TABLE wf.queue_member (
    queue_id                uuid NOT NULL REFERENCES wf.queue,
    account_id              uuid NOT NULL REFERENCES iam.account,
    competence_level        smallint NOT NULL DEFAULT 1 CHECK (competence_level BETWEEN 1 AND 3),
    is_active               boolean NOT NULL DEFAULT true,
    PRIMARY KEY (queue_id, account_id)
);

CREATE SEQUENCE wf.case_number_seq;

CREATE TABLE wf.case_file (
    case_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_number             varchar(24) NOT NULL UNIQUE
                            DEFAULT 'CASE/' || to_char(now(),'YYYY') || '/' || lpad(nextval('wf.case_number_seq')::text, 6, '0'),
    case_type               varchar(11) NOT NULL CHECK (case_type IN ('APPLICATION','COMPLIANCE')),
    application_id          uuid UNIQUE REFERENCES app.application,
    compliance_exception_id uuid UNIQUE,                        -- FK added after cmp.compliance_exception
    queue_id                uuid NOT NULL REFERENCES wf.queue,
    assigned_officer_id     uuid REFERENCES iam.account,
    current_workflow_stage_id uuid REFERENCES cfg.workflow_stage,
    status                  varchar(18) NOT NULL DEFAULT 'OPEN'
                            CHECK (status IN ('OPEN','AWAITING_APPLICANT','ESCALATED','CLOSED')),
    opened_at               timestamptz NOT NULL DEFAULT now(),
    sla_due_at              timestamptz NOT NULL,
    sla_clock_seconds       integer NOT NULL DEFAULT 0 CHECK (sla_clock_seconds >= 0),
    sla_clock_resumed_at    timestamptz DEFAULT now(),          -- NULL while the clock is stopped
    closed_at               timestamptz,
    CONSTRAINT ck_case_source CHECK (
        (case_type = 'APPLICATION' AND application_id IS NOT NULL AND compliance_exception_id IS NULL) OR
        (case_type = 'COMPLIANCE'  AND compliance_exception_id IS NOT NULL AND application_id IS NULL)),
    CONSTRAINT ck_case_closed CHECK ((status = 'CLOSED') = (closed_at IS NOT NULL))
);
CREATE INDEX ix_case_queue_status ON wf.case_file (queue_id, status);
CREATE INDEX ix_case_officer_open ON wf.case_file (assigned_officer_id) WHERE status <> 'CLOSED';

CREATE TABLE wf.case_assignment (
    assignment_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 uuid NOT NULL REFERENCES wf.case_file,
    officer_account_id      uuid NOT NULL REFERENCES iam.account,
    assignment_method       varchar(13) NOT NULL CHECK (assignment_method IN ('AUTO','MANUAL','BULK_REASSIGN')),
    assigned_by_account_id  uuid REFERENCES iam.account,
    assigned_at             timestamptz NOT NULL DEFAULT now(),
    ended_at                timestamptz,
    CHECK (assignment_method = 'AUTO' OR assigned_by_account_id IS NOT NULL)
);
CREATE INDEX ix_case_assignment ON wf.case_assignment (case_id, assigned_at);

CREATE TABLE wf.case_stage (
    case_stage_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 uuid NOT NULL REFERENCES wf.case_file,
    workflow_stage_id       uuid NOT NULL REFERENCES cfg.workflow_stage,
    attempt_no              smallint NOT NULL DEFAULT 1,
    status                  varchar(11) NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING','IN_PROGRESS','COMPLETED','RETURNED')),
    outcome                 varchar(17)
                            CHECK (outcome IN ('RECOMMEND_APPROVE','RECOMMEND_REJECT','CLEARED','NOT_CLEARED',
                                               'APPROVE','REJECT','REFER_UP','REVIEWED')),
    actor_account_id        uuid REFERENCES iam.account,
    remarks                 text,
    started_at              timestamptz,
    completed_at            timestamptz,
    UNIQUE (case_id, workflow_stage_id, attempt_no),
    CHECK (status <> 'COMPLETED' OR (outcome IS NOT NULL AND actor_account_id IS NOT NULL AND completed_at IS NOT NULL))
);

CREATE TABLE wf.checklist_review (
    case_id                 uuid NOT NULL REFERENCES wf.case_file,
    checklist_item_id       uuid NOT NULL REFERENCES cfg.checklist_item,
    document_id             uuid REFERENCES doc.document,
    result                  varchar(14) NOT NULL CHECK (result IN ('MET','NOT_MET','NOT_APPLICABLE')),
    remarks                 text,
    reviewed_by_account_id  uuid NOT NULL REFERENCES iam.account,
    reviewed_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (case_id, checklist_item_id),
    CHECK (result <> 'NOT_MET' OR remarks IS NOT NULL)
);

CREATE TABLE wf.case_query (
    query_id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 uuid NOT NULL REFERENCES wf.case_file,
    raised_by_account_id    uuid NOT NULL REFERENCES iam.account,
    raised_at               timestamptz NOT NULL DEFAULT now(),
    non_compliance_details  text NOT NULL,
    response_due_date       date NOT NULL,
    status                  varchar(9) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RESPONDED','CLOSED')),
    response_text           text,
    responded_by_account_id uuid REFERENCES iam.account,
    responded_at            timestamptz,
    CHECK (status = 'OPEN' OR (response_text IS NOT NULL AND responded_at IS NOT NULL))
);
CREATE INDEX ix_case_query ON wf.case_query (case_id, raised_at);

CREATE TABLE wf.escalation (
    escalation_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 uuid NOT NULL REFERENCES wf.case_file,
    sla_used_pct            smallint NOT NULL CHECK (sla_used_pct > 0),
    escalated_to_account_id uuid NOT NULL REFERENCES iam.account,
    raised_at               timestamptz NOT NULL DEFAULT now(),
    acknowledged_at         timestamptz
);
CREATE INDEX ix_escalation_case ON wf.escalation (case_id);

CREATE TABLE wf.decision (
    decision_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 uuid NOT NULL UNIQUE REFERENCES wf.case_file,
    outcome                 varchar(23) NOT NULL
                            CHECK (outcome IN ('APPROVED','REJECTED','RESOLVED','REFERRED_TO_ENFORCEMENT')),
    decision_maker_account_id uuid NOT NULL REFERENCES iam.account,
    authority_level         varchar(10) NOT NULL CHECK (authority_level IN ('OFFICER','MANAGEMENT','COMMITTEE','BOARD')),
    basis                   text NOT NULL,
    conditions_imposed      text,
    rejection_reason        text,
    decided_at              timestamptz NOT NULL DEFAULT now(),
    effective_date          date NOT NULL DEFAULT current_date,
    CHECK (outcome <> 'REJECTED' OR rejection_reason IS NOT NULL)
);

ALTER TABLE lic.licence
    ADD CONSTRAINT fk_licence_decision FOREIGN KEY (issuing_decision_id) REFERENCES wf.decision;

-- =====================================================================
-- M5  FEE ASSESSMENT AND PAYMENT  (fin)
-- =====================================================================

CREATE SEQUENCE fin.invoice_seq;

CREATE TABLE fin.fee (
    fee_id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_number          varchar(24) NOT NULL UNIQUE
                            DEFAULT 'INV/' || to_char(now(),'YYYY') || '/' || lpad(nextval('fin.invoice_seq')::text, 7, '0'),
    application_id          uuid REFERENCES app.application,
    licence_id              uuid REFERENCES lic.licence,
    fee_schedule_id         uuid NOT NULL REFERENCES cfg.fee_schedule,
    fee_type                varchar(18) NOT NULL CHECK (fee_type IN ('APPLICATION','LICENCE','RENEWAL','ANNUAL_SUPERVISORY')),
    amount                  numeric(14,2) NOT NULL CHECK (amount > 0),
    penalty_amount          numeric(14,2) NOT NULL DEFAULT 0 CHECK (penalty_amount >= 0),
    currency                char(3) NOT NULL DEFAULT 'KES',
    payment_reference       varchar(30) NOT NULL UNIQUE,
    status                  varchar(9) NOT NULL DEFAULT 'INVOICED'
                            CHECK (status IN ('INVOICED','PAID','OVERDUE','CANCELLED')),
    issued_at               timestamptz NOT NULL DEFAULT now(),
    due_date                date NOT NULL,
    paid_at                 timestamptz,
    CONSTRAINT ck_fee_subject CHECK (num_nonnulls(application_id, licence_id) >= 1),
    CONSTRAINT ck_fee_paid    CHECK ((status = 'PAID') = (paid_at IS NOT NULL))
);
CREATE INDEX ix_fee_application ON fin.fee (application_id);
CREATE INDEX ix_fee_licence ON fin.fee (licence_id);
CREATE INDEX ix_fee_open_due ON fin.fee (due_date) WHERE status IN ('INVOICED','OVERDUE');

CREATE TABLE fin.payment (
    payment_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fee_id                  uuid REFERENCES fin.fee,                -- NULL until matched
    source                  varchar(9) NOT NULL CHECK (source IN ('GATEWAY','BANK_FILE')),
    external_transaction_id varchar(64) NOT NULL,
    payment_reference       varchar(30) NOT NULL,                   -- as quoted by the payer
    amount                  numeric(14,2) NOT NULL CHECK (amount > 0),
    currency                char(3) NOT NULL DEFAULT 'KES',
    payer_account_id        uuid REFERENCES iam.account,
    status                  varchar(9) NOT NULL DEFAULT 'INITIATED'
                            CHECK (status IN ('INITIATED','SETTLED','FAILED','REVERSED')),
    match_status            varchar(16) NOT NULL DEFAULT 'UNMATCHED'
                            CHECK (match_status IN ('MATCHED','UNMATCHED','MANUALLY_MATCHED')),
    initiated_at            timestamptz NOT NULL DEFAULT now(),
    settled_at              timestamptz,
    CONSTRAINT uq_payment_idempotency UNIQUE (source, external_transaction_id),
    CONSTRAINT ck_payment_match CHECK ((match_status = 'UNMATCHED') = (fee_id IS NULL)),
    CONSTRAINT ck_payment_settled CHECK (status <> 'SETTLED' OR settled_at IS NOT NULL)
);
CREATE INDEX ix_payment_fee ON fin.payment (fee_id);
CREATE INDEX ix_payment_reference ON fin.payment (payment_reference);
CREATE INDEX ix_payment_unmatched ON fin.payment (settled_at) WHERE match_status = 'UNMATCHED';

CREATE TABLE fin.receipt (
    receipt_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_number          varchar(24) NOT NULL UNIQUE,
    payment_id              uuid NOT NULL UNIQUE REFERENCES fin.payment,
    storage_key             varchar(500),
    issued_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE fin.reconciliation_run (
    reconciliation_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    business_date           date NOT NULL UNIQUE,
    total_assessed          numeric(16,2) NOT NULL,
    total_collected         numeric(16,2) NOT NULL,
    total_unmatched         numeric(16,2) NOT NULL,
    total_outstanding       numeric(16,2) NOT NULL,
    generated_at            timestamptz NOT NULL DEFAULT now(),
    exported_to_finance_at  timestamptz
);

-- =====================================================================
-- M7  REGULATORY RETURNS AND COMPLIANCE  (cmp)
-- =====================================================================

CREATE TABLE cmp.filing_obligation (
    obligation_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_id              uuid NOT NULL REFERENCES lic.licence,
    return_type_id          uuid NOT NULL REFERENCES cfg.return_type,
    period_start            date NOT NULL,
    period_end              date NOT NULL,
    due_date                date NOT NULL,
    status                  varchar(8) NOT NULL DEFAULT 'UPCOMING'
                            CHECK (status IN ('UPCOMING','FILED','OVERDUE','WAIVED')),
    reminder_sent_at        timestamptz,
    UNIQUE (licence_id, return_type_id, period_end),
    CHECK (period_end >= period_start AND due_date >= period_end)
);
CREATE INDEX ix_obligation_due ON cmp.filing_obligation (due_date) WHERE status IN ('UPCOMING','OVERDUE');

CREATE TABLE cmp.regulatory_return (
    return_id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_id              uuid NOT NULL REFERENCES lic.licence,
    return_type_id          uuid NOT NULL REFERENCES cfg.return_type,
    obligation_id           uuid REFERENCES cmp.filing_obligation,
    filing_kind             varchar(17) NOT NULL CHECK (filing_kind IN ('PERIODIC','AD_HOC_DISCLOSURE','MATERIAL_CHANGE')),
    due_date                date,
    filed_date              date NOT NULL DEFAULT current_date,
    filed_by_account_id     uuid NOT NULL REFERENCES iam.account,
    validation_status       varchar(7) NOT NULL DEFAULT 'PENDING' CHECK (validation_status IN ('PENDING','PASSED','FAILED')),
    created_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_return_periodic CHECK ((filing_kind = 'PERIODIC') = (obligation_id IS NOT NULL)),
    CONSTRAINT ck_return_due      CHECK (filing_kind <> 'PERIODIC' OR due_date IS NOT NULL)
);
CREATE INDEX ix_return_licence ON cmp.regulatory_return (licence_id, filed_date);
CREATE INDEX ix_return_obligation ON cmp.regulatory_return (obligation_id);

CREATE TABLE cmp.return_value (
    return_id               uuid NOT NULL REFERENCES cmp.regulatory_return,
    template_field_id       uuid NOT NULL REFERENCES cfg.return_template_field,
    value_numeric           numeric(20,4),
    value_text              text,
    value_date              date,
    PRIMARY KEY (return_id, template_field_id),
    CHECK (num_nonnulls(value_numeric, value_text, value_date) = 1)
);

CREATE TABLE cmp.return_validation_result (
    return_id               uuid NOT NULL REFERENCES cmp.regulatory_return,
    validation_rule_id      uuid NOT NULL REFERENCES cfg.validation_rule,
    passed                  boolean NOT NULL,
    message                 varchar(300),
    evaluated_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (return_id, validation_rule_id)
);

CREATE TABLE cmp.compliance_exception (
    exception_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    licence_id              uuid NOT NULL REFERENCES lic.licence,
    obligation_id           uuid REFERENCES cmp.filing_obligation,
    return_id               uuid REFERENCES cmp.regulatory_return,
    exception_type          varchar(18) NOT NULL CHECK (exception_type IN ('LATE_FILING','VALIDATION_FAILURE','THRESHOLD_BREACH')),
    details                 text NOT NULL,
    status                  varchar(23) NOT NULL DEFAULT 'OPEN'
                            CHECK (status IN ('OPEN','UNDER_REVIEW','RESOLVED','REFERRED_TO_ENFORCEMENT')),
    raised_at               timestamptz NOT NULL DEFAULT now(),
    resolved_at             timestamptz,
    CHECK (exception_type <> 'LATE_FILING' OR obligation_id IS NOT NULL),
    CHECK (exception_type = 'LATE_FILING' OR return_id IS NOT NULL),
    CHECK (status NOT IN ('RESOLVED','REFERRED_TO_ENFORCEMENT') OR resolved_at IS NOT NULL)
);
CREATE INDEX ix_exception_licence ON cmp.compliance_exception (licence_id, raised_at);

ALTER TABLE doc.document
    ADD CONSTRAINT fk_document_return FOREIGN KEY (return_id) REFERENCES cmp.regulatory_return;
ALTER TABLE wf.case_file
    ADD CONSTRAINT fk_case_exception FOREIGN KEY (compliance_exception_id) REFERENCES cmp.compliance_exception;

-- =====================================================================
-- M8  COMMUNICATION AND NOTIFICATION  (ntf)
-- =====================================================================

CREATE TABLE ntf.notification (
    notification_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id             uuid NOT NULL REFERENCES cfg.notification_template,
    recipient_account_id    uuid NOT NULL REFERENCES iam.account,
    channel                 varchar(5) NOT NULL CHECK (channel IN ('EMAIL','SMS')),
    event_type              varchar(40) NOT NULL,
    case_id                 uuid REFERENCES wf.case_file,
    related_table           varchar(60),
    related_id              uuid,
    rendered_subject        varchar(200),
    rendered_body           text NOT NULL,
    is_statutory            boolean NOT NULL DEFAULT false,
    status                  varchar(9) NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','SENT','DELIVERED','FAILED')),
    gateway_message_id      varchar(100),
    failure_reason          varchar(300),
    queued_at               timestamptz NOT NULL DEFAULT now(),
    sent_at                 timestamptz,
    delivered_at            timestamptz,
    CHECK (status <> 'DELIVERED' OR delivered_at IS NOT NULL)
);
CREATE INDEX ix_notification_recipient ON ntf.notification (recipient_account_id, queued_at);
CREATE INDEX ix_notification_pending ON ntf.notification (queued_at) WHERE status = 'QUEUED';

CREATE TABLE ntf.correspondence (
    correspondence_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id                 uuid NOT NULL REFERENCES wf.case_file,
    direction               varchar(8) NOT NULL CHECK (direction IN ('INBOUND','OUTBOUND')),
    author_account_id       uuid NOT NULL REFERENCES iam.account,
    subject                 varchar(200) NOT NULL,
    body                    text NOT NULL,
    query_id                uuid REFERENCES wf.case_query,
    notification_id         uuid REFERENCES ntf.notification,
    document_id             uuid REFERENCES doc.document,
    created_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_correspondence_case ON ntf.correspondence (case_id, created_at);

-- =====================================================================
-- AUDIT LOG STORE  (aud)  — append-only; no FKs so it outlives archived rows
-- =====================================================================

CREATE TABLE aud.audit_event (
    audit_event_id          bigint GENERATED ALWAYS AS IDENTITY,
    occurred_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    acting_account_id       uuid NOT NULL,
    action                  varchar(30) NOT NULL,
    object_type             varchar(60) NOT NULL,
    object_id               text,
    before_value            jsonb,
    after_value             jsonb,
    client_ip               inet,
    event_hash              bytea NOT NULL,
    PRIMARY KEY (audit_event_id, occurred_at)
) PARTITION BY RANGE (occurred_at);

CREATE INDEX ix_audit_object ON aud.audit_event (object_type, object_id);
CREATE INDEX ix_audit_actor  ON aud.audit_event (acting_account_id, occurred_at);

DO $$
DECLARE m date := date '2026-01-01';
BEGIN
    WHILE m < date '2028-01-01' LOOP
        EXECUTE format('CREATE TABLE aud.audit_event_%s PARTITION OF aud.audit_event FOR VALUES FROM (%L) TO (%L)',
                       to_char(m, 'YYYY_MM'), m, (m + interval '1 month')::date);
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;
CREATE TABLE aud.audit_event_default PARTITION OF aud.audit_event DEFAULT;

CREATE TABLE aud.audit_seal (
    seal_id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_event_id           bigint NOT NULL,
    to_event_id             bigint NOT NULL,
    previous_seal_hash      bytea,
    seal_hash               bytea NOT NULL,
    sealed_at               timestamptz NOT NULL DEFAULT now(),
    CHECK (to_event_id >= from_event_id)
);

CREATE TABLE aud.interface_message (
    message_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    interface_code          varchar(10) NOT NULL,           -- SRS-IF-05 … SRS-IF-11
    direction               varchar(8)  NOT NULL CHECK (direction IN ('OUTBOUND','INBOUND')),
    correlation_id          varchar(64) NOT NULL,
    http_status             smallint,
    payload_sha256          char(64) NOT NULL,
    outcome                 varchar(8)  NOT NULL CHECK (outcome IN ('SUCCESS','FAILURE','TIMEOUT')),
    occurred_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_interface_message ON aud.interface_message (interface_code, occurred_at);

-- =====================================================================
-- BUSINESS-RULE ENFORCEMENT  (functions and triggers)
-- =====================================================================

-- Data-driven state machines (application, case, licence, fee)
CREATE FUNCTION cfg.fn_enforce_transition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cfg.status_transition
                   WHERE object_type = TG_ARGV[0] AND from_status = OLD.status AND to_status = NEW.status) THEN
        RAISE EXCEPTION '% status change % -> % is not permitted', TG_ARGV[0], OLD.status, NEW.status
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_10_transition BEFORE UPDATE OF status ON app.application
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION cfg.fn_enforce_transition('APPLICATION');
CREATE TRIGGER trg_10_transition BEFORE UPDATE OF status ON wf.case_file
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION cfg.fn_enforce_transition('CASE');
CREATE TRIGGER trg_10_transition BEFORE UPDATE OF status ON lic.licence
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION cfg.fn_enforce_transition('LICENCE');
CREATE TRIGGER trg_10_transition BEFORE UPDATE OF status ON fin.fee
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION cfg.fn_enforce_transition('FEE');

-- BR-08 / BR-09 / SRS-FR-M2-05, M2-06: submission gate, reference issue, immutability
CREATE FUNCTION app.fn_application_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE missing text;
BEGIN
    IF OLD.submitted_at IS NOT NULL AND NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
        RAISE EXCEPTION 'submitted_at is immutable once set' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.reference_number IS NOT NULL AND NEW.reference_number IS DISTINCT FROM OLD.reference_number THEN
        RAISE EXCEPTION 'reference_number is immutable once issued' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'DRAFT' AND NEW.status = 'SUBMITTED' THEN
        SELECT string_agg(ci.item_code, ', ' ORDER BY ci.display_order) INTO missing
          FROM cfg.checklist_item ci
         WHERE ci.category_version_id = NEW.category_version_id
           AND ci.is_mandatory
           AND NOT EXISTS (
               SELECT 1 FROM doc.document d
                 JOIN doc.document_version v ON v.document_id = d.document_id AND v.version_no = d.current_version_no
                WHERE d.application_id = NEW.application_id
                  AND d.checklist_item_id = ci.checklist_item_id
                  AND v.scan_status = 'CLEAN');
        IF missing IS NOT NULL THEN
            RAISE EXCEPTION 'Mandatory checklist documents missing: %', missing USING ERRCODE = 'check_violation';
        END IF;
        NEW.submitted_at     := now();
        NEW.reference_number := 'CMA/APP/' || to_char(now(), 'YYYY') || '/' ||
                                lpad(nextval('app.application_ref_seq')::text, 6, '0');
    END IF;
    IF NEW.status IN ('APPROVED','REJECTED') AND NEW.decided_at IS NULL THEN
        NEW.decided_at := now();
    END IF;
    NEW.last_saved_at := now();
    RETURN NEW;
END $$;
CREATE TRIGGER trg_20_rules BEFORE UPDATE ON app.application
    FOR EACH ROW EXECUTE FUNCTION app.fn_application_rules();

-- BRU-02 / SRS-FR-M4-01: an application case exists only once the fee is paid
CREATE FUNCTION wf.fn_case_requires_payment() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.case_type = 'APPLICATION' AND NOT EXISTS (
        SELECT 1 FROM app.application WHERE application_id = NEW.application_id AND status = 'PAID') THEN
        RAISE EXCEPTION 'Case cannot be opened: application is not submitted and paid' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_20_requires_payment BEFORE INSERT ON wf.case_file
    FOR EACH ROW EXECUTE FUNCTION wf.fn_case_requires_payment();

-- BR-18 / SRS-FR-M4-05, M4-07: SLA clock stops while awaiting the applicant; closure needs a decision
CREATE FUNCTION wf.fn_case_status_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.sla_clock_resumed_at IS NOT NULL AND NEW.status IN ('AWAITING_APPLICANT','CLOSED') THEN
        NEW.sla_clock_seconds    := OLD.sla_clock_seconds + extract(epoch FROM now() - OLD.sla_clock_resumed_at)::int;
        NEW.sla_clock_resumed_at := NULL;
    ELSIF OLD.status = 'AWAITING_APPLICANT' AND NEW.status IN ('OPEN','ESCALATED') THEN
        NEW.sla_clock_resumed_at := now();
    END IF;
    IF NEW.status = 'CLOSED' THEN
        IF NOT EXISTS (SELECT 1 FROM wf.decision WHERE case_id = NEW.case_id) THEN
            RAISE EXCEPTION 'Case % cannot be closed without a decision record', NEW.case_number
                  USING ERRCODE = 'check_violation';
        END IF;
        NEW.closed_at := coalesce(NEW.closed_at, now());
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_20_status_rules BEFORE UPDATE OF status ON wf.case_file
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION wf.fn_case_status_rules();

-- BR-04 / BR-19 / SRS-FR-M1-06, M4-04: stage sequencing and segregation of duties
CREATE FUNCTION wf.fn_case_stage_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cur cfg.workflow_stage; case_version uuid; pending text;
BEGIN
    SELECT * INTO cur FROM cfg.workflow_stage WHERE workflow_stage_id = NEW.workflow_stage_id;
    SELECT a.category_version_id INTO case_version
      FROM wf.case_file c JOIN app.application a ON a.application_id = c.application_id
     WHERE c.case_id = NEW.case_id;
    IF case_version IS NOT NULL AND case_version <> cur.category_version_id THEN
        RAISE EXCEPTION 'Workflow stage does not belong to the category version of this case' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status IN ('IN_PROGRESS','COMPLETED') THEN
        SELECT string_agg(ws.stage_code, ', ' ORDER BY ws.sequence_no) INTO pending
          FROM cfg.workflow_stage ws
         WHERE ws.category_version_id = cur.category_version_id
           AND ws.is_mandatory AND ws.sequence_no < cur.sequence_no
           AND NOT EXISTS (SELECT 1 FROM wf.case_stage cs
                            WHERE cs.case_id = NEW.case_id AND cs.workflow_stage_id = ws.workflow_stage_id
                              AND cs.status = 'COMPLETED');
        IF pending IS NOT NULL THEN
            RAISE EXCEPTION 'Stage % cannot start: prior mandatory stage(s) % incomplete', cur.stage_code, pending
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF NEW.status = 'COMPLETED' AND cur.stage_code IN ('APPROVAL','COMMITTEE','BOARD') AND EXISTS (
        SELECT 1 FROM wf.case_stage cs JOIN cfg.workflow_stage ws ON ws.workflow_stage_id = cs.workflow_stage_id
         WHERE cs.case_id = NEW.case_id AND cs.status = 'COMPLETED'
           AND ws.stage_code = 'RECOMMENDATION' AND cs.actor_account_id = NEW.actor_account_id) THEN
        RAISE EXCEPTION 'Segregation of duties: the recommender cannot approve the same case'
              USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_20_stage_rules BEFORE INSERT OR UPDATE ON wf.case_stage
    FOR EACH ROW EXECUTE FUNCTION wf.fn_case_stage_rules();

CREATE FUNCTION wf.fn_decision_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM wf.case_stage cs JOIN cfg.workflow_stage ws ON ws.workflow_stage_id = cs.workflow_stage_id
                WHERE cs.case_id = NEW.case_id AND cs.status = 'COMPLETED'
                  AND ws.stage_code = 'RECOMMENDATION' AND cs.actor_account_id = NEW.decision_maker_account_id) THEN
        RAISE EXCEPTION 'Segregation of duties: the recommender cannot record the decision'
              USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_20_decision_rules BEFORE INSERT OR UPDATE ON wf.decision
    FOR EACH ROW EXECUTE FUNCTION wf.fn_decision_rules();

-- BR-26 / SRS-FR-M6-03: every licence status change carries a reason and effective date, kept as history
CREATE FUNCTION lic.fn_licence_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status_reason IS NULL OR NEW.status_effective_date IS NULL
       OR (NEW.status_reason IS NOT DISTINCT FROM OLD.status_reason
           AND NEW.status_effective_date IS NOT DISTINCT FROM OLD.status_effective_date) THEN
        RAISE EXCEPTION 'Licence status change requires a new reason and effective date' USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO lic.licence_status_history (licence_id, from_status, to_status, reason, effective_date, changed_by_account_id)
    VALUES (NEW.licence_id, OLD.status, NEW.status, NEW.status_reason, NEW.status_effective_date,
            current_setting('app.account_id')::uuid);
    RETURN NEW;
END $$;
CREATE TRIGGER trg_30_history AFTER UPDATE OF status ON lic.licence
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION lic.fn_licence_history();

-- BR-25 / SRS-FR-M6-02 public verification without exposing the register table
CREATE FUNCTION lic.fn_verify_certificate(p_code varchar)
RETURNS TABLE (licence_number varchar, holder_name varchar, category_name varchar,
               licence_status varchar, issue_date date, expiry_date date, is_current boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT l.licence_number, coalesce(e.registered_name, p.full_name), c.category_name,
           l.status, l.issue_date, l.expiry_date, ce.is_current
      FROM lic.certificate ce
      JOIN lic.licence l           ON l.licence_id = ce.licence_id
      JOIN cfg.licence_category c  ON c.category_id = l.category_id
      LEFT JOIN iam.entity e       ON e.entity_id = l.holder_entity_id
      LEFT JOIN iam.person p       ON p.person_id = l.holder_person_id
     WHERE ce.verification_code = p_code AND l.published_at IS NOT NULL
$$;

-- BR-02 / SRS-FR-M1-04: adviser may act only inside the recorded scope and period
CREATE FUNCTION iam.fn_adviser_can(p_adviser uuid, p_entity uuid, p_action text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM iam.adviser_authorisation a
         WHERE a.adviser_account_id = p_adviser AND a.entity_id = p_entity
           AND a.revoked_at IS NULL AND current_date BETWEEN a.valid_from AND a.valid_to
           AND CASE p_action WHEN 'PREPARE' THEN a.can_prepare WHEN 'SUBMIT' THEN a.can_submit
                             WHEN 'PAY' THEN a.can_pay WHEN 'VIEW' THEN a.can_view ELSE false END)
$$;

-- NFR-05 / SRS-FR-M4-08: generic change capture into the append-only audit store
CREATE FUNCTION aud.fn_capture_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE actor uuid; before_v jsonb; after_v jsonb;
        redacted text[] := ARRAY['password_hash','mfa_secret_enc'];
BEGIN
    actor := nullif(current_setting('app.account_id', true), '')::uuid;
    IF actor IS NULL THEN
        RAISE EXCEPTION 'Unattributable change to %.%: app.account_id is not set', TG_TABLE_SCHEMA, TG_TABLE_NAME
              USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF TG_OP <> 'INSERT' THEN before_v := to_jsonb(OLD) - redacted; END IF;
    IF TG_OP <> 'DELETE' THEN after_v  := to_jsonb(NEW) - redacted; END IF;
    INSERT INTO aud.audit_event (acting_account_id, action, object_type, object_id, before_value, after_value,
                                 client_ip, event_hash)
    VALUES (actor, TG_OP, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, coalesce(after_v, before_v) ->> TG_ARGV[0],
            before_v, after_v, inet_client_addr(), '\x'::bytea);
    RETURN NULL;
END $$;

CREATE FUNCTION aud.fn_hash_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.event_hash := sha256(convert_to(concat_ws('|', NEW.audit_event_id, NEW.occurred_at, NEW.acting_account_id,
                       NEW.action, NEW.object_type, NEW.object_id, NEW.before_value::text, NEW.after_value::text), 'UTF8'));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_10_hash BEFORE INSERT ON aud.audit_event FOR EACH ROW EXECUTE FUNCTION aud.fn_hash_event();

CREATE FUNCTION aud.fn_block_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'The audit store is append-only (% refused)', TG_OP USING ERRCODE = 'insufficient_privilege';
END $$;
CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON aud.audit_event
    FOR EACH ROW EXECUTE FUNCTION aud.fn_block_mutation();
CREATE TRIGGER trg_append_only_truncate BEFORE TRUNCATE ON aud.audit_event
    FOR EACH STATEMENT EXECUTE FUNCTION aud.fn_block_mutation();
CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON aud.audit_seal
    FOR EACH ROW EXECUTE FUNCTION aud.fn_block_mutation();

-- Scheduled job (every 15 minutes): chains unsealed events into a tamper-evident seal
CREATE FUNCTION aud.fn_seal_audit() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE last_seal aud.audit_seal; lo bigint; hi bigint; h bytea;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('aud.fn_seal_audit'));
    SELECT * INTO last_seal FROM aud.audit_seal ORDER BY seal_id DESC LIMIT 1;
    lo := coalesce(last_seal.to_event_id, 0) + 1;
    SELECT max(audit_event_id) INTO hi FROM aud.audit_event WHERE audit_event_id >= lo;
    IF hi IS NULL THEN RETURN NULL; END IF;
    SELECT sha256(coalesce(last_seal.seal_hash, '\x'::bytea) || string_agg(event_hash, ''::bytea ORDER BY audit_event_id))
      INTO h FROM aud.audit_event WHERE audit_event_id BETWEEN lo AND hi;
    INSERT INTO aud.audit_seal (from_event_id, to_event_id, previous_seal_hash, seal_hash)
    VALUES (lo, hi, last_seal.seal_hash, h);
    RETURN hi;
END $$;

-- Attach change capture to every operational table (first primary-key column identifies the row)
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT n.nspname AS sch, c.relname AS tbl,
               (SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
                 WHERE i.indrelid = c.oid AND i.indisprimary) AS pk
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind = 'r' AND n.nspname IN ('iam','cfg','app','doc','wf','fin','lic','cmp','ntf')
    LOOP
        EXECUTE format('CREATE TRIGGER trg_90_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I
                        FOR EACH ROW EXECUTE FUNCTION aud.fn_capture_change(%L)', r.sch, r.tbl, r.pk);
    END LOOP;
END $$;

-- =====================================================================
-- VIEWS  (public register, filing calendar, compliance history, reporting)
-- =====================================================================

CREATE VIEW lic.v_public_register WITH (security_barrier) AS
SELECT l.licence_number,
       coalesce(e.registered_name, p.full_name) AS holder_name,
       c.category_code, c.category_name,
       l.status AS licence_status, l.issue_date, l.expiry_date, l.conditions, l.published_at
  FROM lic.licence l
  JOIN cfg.licence_category c ON c.category_id = l.category_id
  LEFT JOIN iam.entity e ON e.entity_id = l.holder_entity_id
  LEFT JOIN iam.person p ON p.person_id = l.holder_person_id
 WHERE l.published_at IS NOT NULL;

CREATE VIEW cmp.v_filing_calendar AS
SELECT o.obligation_id, l.licence_number, l.holder_entity_id, rt.return_code, rt.return_name,
       o.period_start, o.period_end, o.due_date, o.status,
       (o.due_date - current_date) AS days_to_due
  FROM cmp.filing_obligation o
  JOIN lic.licence l      ON l.licence_id = o.licence_id
  JOIN cfg.return_type rt ON rt.return_type_id = o.return_type_id;

CREATE VIEW cmp.v_compliance_history AS
SELECT l.licence_id, l.licence_number,
       count(r.return_id)                                              AS returns_filed,
       count(r.return_id) FILTER (WHERE r.filed_date > r.due_date)     AS returns_filed_late,
       (SELECT count(*) FROM cmp.compliance_exception x WHERE x.licence_id = l.licence_id)                       AS exceptions_total,
       (SELECT count(*) FROM cmp.compliance_exception x WHERE x.licence_id = l.licence_id AND x.status = 'OPEN') AS exceptions_open
  FROM lic.licence l
  LEFT JOIN cmp.regulatory_return r ON r.licence_id = l.licence_id
 GROUP BY l.licence_id, l.licence_number;

CREATE VIEW rpt.v_case_ageing AS
SELECT cf.case_number, lc.category_code, cf.status, cf.assigned_officer_id,
       cf.opened_at, cv.sla_target_days,
       round((cf.sla_clock_seconds + coalesce(extract(epoch FROM now() - cf.sla_clock_resumed_at), 0)) / 86400.0, 1) AS sla_days_used,
       round(100 * (cf.sla_clock_seconds + coalesce(extract(epoch FROM now() - cf.sla_clock_resumed_at), 0))
             / (cv.sla_target_days * 86400.0), 0) AS sla_used_pct
  FROM wf.case_file cf
  JOIN app.application a       ON a.application_id = cf.application_id
  JOIN cfg.category_version cv ON cv.category_version_id = a.category_version_id
  JOIN cfg.licence_category lc ON lc.category_id = cv.category_id
 WHERE cf.status <> 'CLOSED';

CREATE VIEW rpt.v_turnaround_by_category AS
SELECT lc.category_code, date_trunc('month', a.decided_at)::date AS decision_month,
       count(*)                                         AS decided,
       count(*) FILTER (WHERE a.status = 'APPROVED')    AS approved,
       count(*) FILTER (WHERE a.status = 'REJECTED')    AS rejected,
       round(avg(extract(epoch FROM a.decided_at - a.submitted_at)) / 86400.0, 1) AS avg_turnaround_days
  FROM app.application a
  JOIN cfg.category_version cv ON cv.category_version_id = a.category_version_id
  JOIN cfg.licence_category lc ON lc.category_id = cv.category_id
 WHERE a.status IN ('APPROVED','REJECTED')
 GROUP BY lc.category_code, date_trunc('month', a.decided_at);

CREATE VIEW rpt.v_daily_reconciliation AS
SELECT d::date AS business_date,
       (SELECT coalesce(sum(amount + penalty_amount), 0) FROM fin.fee WHERE issued_at::date = d::date)                     AS assessed,
       (SELECT coalesce(sum(amount), 0) FROM fin.payment WHERE status = 'SETTLED' AND match_status <> 'UNMATCHED'
                                                            AND settled_at::date = d::date)                                 AS collected,
       (SELECT coalesce(sum(amount), 0) FROM fin.payment WHERE status = 'SETTLED' AND match_status = 'UNMATCHED'
                                                            AND settled_at::date = d::date)                                 AS unmatched,
       (SELECT coalesce(sum(amount + penalty_amount), 0) FROM fin.fee WHERE status IN ('INVOICED','OVERDUE')
                                                            AND issued_at::date <= d::date)                                 AS outstanding
  FROM generate_series(current_date - 30, current_date, interval '1 day') AS d;

-- =====================================================================
-- ACCESS CONTROL  (least privilege per service; read-only auditor; public register)
-- =====================================================================

DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['svc_identity','svc_application','svc_document','svc_case','svc_payment',
                             'svc_licence','svc_compliance','svc_notification','svc_reporting',
                             'role_auditor','role_public_register'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;

REVOKE ALL ON SCHEMA iam, cfg, app, doc, wf, fin, lic, cmp, ntf, aud, rpt FROM PUBLIC;

-- every service may read shared reference data and identities
GRANT USAGE ON SCHEMA iam, cfg, app, doc, wf, fin, lic, cmp, ntf, rpt
      TO svc_identity, svc_application, svc_document, svc_case, svc_payment, svc_licence,
         svc_compliance, svc_notification, svc_reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA iam, cfg, app, doc, wf, fin, lic, cmp, ntf, rpt
      TO svc_identity, svc_application, svc_document, svc_case, svc_payment, svc_licence,
         svc_compliance, svc_notification, svc_reporting;

-- each service writes only the schema it owns
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA iam TO svc_identity;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA app TO svc_application;
GRANT DELETE ON app.application_field_value TO svc_application;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA doc TO svc_document;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA wf  TO svc_case;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA fin TO svc_payment;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA lic TO svc_licence;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA cmp TO svc_compliance;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA ntf TO svc_notification;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA cfg TO svc_reporting;
-- cross-subsystem status hand-offs (Table 7 of the BRS)
GRANT UPDATE (status, decided_at, expected_decision_date) ON app.application TO svc_payment, svc_case;
GRANT UPDATE (approval_status, approved_by_application_id) ON iam.entity_key_person TO svc_case;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app, wf, fin TO svc_application, svc_case, svc_payment;

-- auditors: read-only over everything including the audit store
GRANT USAGE ON SCHEMA iam, cfg, app, doc, wf, fin, lic, cmp, ntf, aud, rpt TO role_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA iam, cfg, app, doc, wf, fin, lic, cmp, ntf, aud, rpt TO role_auditor;
-- credential columns are withheld: table-level SELECT is replaced by a column list
REVOKE SELECT ON iam.account FROM role_auditor;
DO $$
BEGIN
    EXECUTE (SELECT format('GRANT SELECT (%s) ON iam.account TO role_auditor', string_agg(quote_ident(column_name), ', '))
               FROM information_schema.columns
              WHERE table_schema = 'iam' AND table_name = 'account'
                AND column_name NOT IN ('password_hash','mfa_secret_enc'));
END $$;

-- public register: the view and the verification function, nothing else
GRANT USAGE ON SCHEMA lic TO role_public_register;
GRANT SELECT ON lic.v_public_register TO role_public_register;
GRANT EXECUTE ON FUNCTION lic.fn_verify_certificate(varchar) TO role_public_register;
REVOKE EXECUTE ON FUNCTION lic.fn_verify_certificate(varchar) FROM PUBLIC;

-- =====================================================================
-- DATA CLASSIFICATION TAGS  (SRS-NFR-04: personal data tagged by sensitivity)
-- =====================================================================

COMMENT ON COLUMN iam.person.national_id_number      IS 'classification=CONFIDENTIAL; personal data (DPA 2019)';
COMMENT ON COLUMN iam.person.date_of_birth           IS 'classification=CONFIDENTIAL; personal data (DPA 2019)';
COMMENT ON COLUMN iam.person.email_address           IS 'classification=CONFIDENTIAL; personal data (DPA 2019)';
COMMENT ON COLUMN iam.person.mobile_number           IS 'classification=CONFIDENTIAL; personal data; mask as ****last4 in logs';
COMMENT ON COLUMN iam.account.password_hash          IS 'classification=SECRET; never exported, redacted from audit';
COMMENT ON COLUMN iam.account.mfa_secret_enc         IS 'classification=SECRET; never exported, redacted from audit';
COMMENT ON COLUMN app.key_person_declaration.has_criminal_conviction IS 'classification=SENSITIVE; fit-and-proper declaration';
COMMENT ON COLUMN app.key_person_declaration.disclosure_notes        IS 'classification=SENSITIVE; fit-and-proper declaration';
COMMENT ON COLUMN app.key_person_declaration.assessment_remarks      IS 'classification=SENSITIVE; regulatory judgement';
COMMENT ON COLUMN iam.entity.paid_up_capital         IS 'classification=RESTRICTED; commercially sensitive';
COMMENT ON COLUMN cmp.return_value.value_numeric     IS 'classification=RESTRICTED; supervisory data';
COMMENT ON VIEW   lic.v_public_register              IS 'classification=PUBLIC; the only object exposed without authentication';

-- =====================================================================
-- REFERENCE DATA
-- =====================================================================

SET LOCAL app.account_id = '00000000-0000-0000-0000-000000000001';   -- every change must be attributable

INSERT INTO iam.person (person_id, full_name, national_id_number, email_address, mobile_number, id_verification_status)
VALUES ('00000000-0000-0000-0000-000000000001', 'Portal System Account', 'SYSTEM-0001',
        'system@portal.internal', '+254700000000', 'VERIFIED');
INSERT INTO iam.account (account_id, person_id, account_type, status)
VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'SYSTEM', 'ACTIVE');

INSERT INTO iam.role (role_code, role_name, is_internal) VALUES
 ('APPLICANT_ADMIN',     'Corporate account administrator', false),
 ('APPLICANT_PREPARER',  'Application preparer',            false),
 ('APPLICANT_SUBMITTER', 'Application submitter',           false),
 ('APPLICANT_PAYER',     'Fee payer',                       false),
 ('PROFESSIONAL_ADVISER','Professional adviser',            false),
 ('LICENSING_OFFICER',   'Licensing officer',               true),
 ('LICENSING_SUPERVISOR','Licensing supervisor',            true),
 ('LEGAL_OFFICER',       'Legal services officer',          true),
 ('FINANCE_OFFICER',     'Finance officer',                 true),
 ('SUPERVISION_OFFICER', 'Supervision officer',             true),
 ('APPROVING_MANAGER',   'Manager with delegated authority',true),
 ('SYSTEM_ADMIN',        'System administrator',            true),
 ('AUDITOR',             'Auditor (read-only)',             true);

INSERT INTO cfg.status_transition (object_type, from_status, to_status) VALUES
 ('APPLICATION','DRAFT','SUBMITTED'), ('APPLICATION','DRAFT','WITHDRAWN'),
 ('APPLICATION','SUBMITTED','PAID'),  ('APPLICATION','SUBMITTED','WITHDRAWN'),
 ('APPLICATION','PAID','UNDER_REVIEW'),
 ('APPLICATION','UNDER_REVIEW','AWAITING_APPLICANT'), ('APPLICATION','AWAITING_APPLICANT','UNDER_REVIEW'),
 ('APPLICATION','UNDER_REVIEW','APPROVED'), ('APPLICATION','UNDER_REVIEW','REJECTED'),
 ('APPLICATION','UNDER_REVIEW','WITHDRAWN'), ('APPLICATION','AWAITING_APPLICANT','WITHDRAWN'),
 ('CASE','OPEN','AWAITING_APPLICANT'), ('CASE','AWAITING_APPLICANT','OPEN'),
 ('CASE','OPEN','ESCALATED'), ('CASE','ESCALATED','OPEN'), ('CASE','ESCALATED','AWAITING_APPLICANT'),
 ('CASE','AWAITING_APPLICANT','ESCALATED'), ('CASE','OPEN','CLOSED'), ('CASE','ESCALATED','CLOSED'),
 ('LICENCE','ACTIVE','SUSPENDED'), ('LICENCE','ACTIVE','REVOKED'), ('LICENCE','ACTIVE','SURRENDERED'),
 ('LICENCE','ACTIVE','LAPSED'), ('LICENCE','ACTIVE','RENEWED'),
 ('LICENCE','SUSPENDED','ACTIVE'), ('LICENCE','SUSPENDED','REVOKED'),
 ('FEE','INVOICED','PAID'), ('FEE','INVOICED','OVERDUE'), ('FEE','OVERDUE','PAID'),
 ('FEE','INVOICED','CANCELLED'), ('FEE','OVERDUE','CANCELLED');

INSERT INTO cfg.licence_category (category_code, category_name, legal_basis, authorisation_kind, applicant_kind, validity_months) VALUES
 ('STOCKBROKER',      'Stockbroker',                                   'Capital Markets Act, s.23(1)', 'LICENCE',  'ENTITY', 12),
 ('INVESTMENT_BANK',  'Investment Bank',                               'Capital Markets Act, s.23(1)', 'LICENCE',  'ENTITY', 12),
 ('FUND_MANAGER',     'Fund Manager',                                  'Capital Markets Act, s.23(1)', 'LICENCE',  'ENTITY', 12),
 ('INVESTMENT_ADVISER','Investment Adviser',                           'Capital Markets Act, s.23(1)', 'LICENCE',  'EITHER', 12),
 ('CIS',              'Collective Investment Scheme',                  'Capital Markets Act, s.23(2)', 'APPROVAL', 'ENTITY', 12),
 ('ISPP',             'Intermediary Service Platform Provider',        'CMA (CIS) Regulations 2023, reg. 76', 'LICENCE', 'ENTITY', 12),
 ('COFFEE_BROKER',    'Coffee Broker',                                 'Capital Markets (Coffee Exchange) Regulations', 'LICENCE', 'ENTITY', 12);

INSERT INTO cfg.document_type (type_code, type_name, validity_months) VALUES
 ('CERT_INCORPORATION', 'Certificate of incorporation', NULL),
 ('AUDITED_ACCOUNTS',   'Audited financial statements', 12),
 ('BOARD_RESOLUTION',   'Board resolution',             6),
 ('BUSINESS_PLAN',      'Business plan',                NULL),
 ('CAPITAL_EVIDENCE',   'Evidence of capital adequacy', 3),
 ('KEY_PERSON_CV',      'Curriculum vitae of key person', NULL),
 ('TAX_COMPLIANCE',     'Tax compliance certificate',   12);

COMMIT;
