//! Shared-library domain values, independent of worker transport and graph IO.

/// Reusable, upstream-formatted contribution; also the complete persisted value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SharedContribution {
    pub header: String,
    pub imports: String,
    pub source: String,
}

/// Valid only for the source version observed during the current transaction.
#[derive(Debug)]
pub(crate) struct SourceEditEvidence {
    pub original: String,
    pub with_part: Option<String>,
    pub without_part: Option<String>,
}
