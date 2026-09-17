# Historical reconciliation fixtures

These three immutable parser/reconciliation inputs preserve the acceptance and
manual UAT dispositions tested by `test_rr_reconciliation.py`. They are test
data, not live board tickets, and are never materialized into `.orchestrator`.

The bytes were copied from `.orchestrator/RR-274.md`, `RR-275.md`, and `RR-280.md`
at source commit `fec2f79815ba8390c4670a53d8d5e8ad138e1630` (v0.4.56), before
automatic ticket archival removed the working files. Tests deliberately use
these fixtures so they also run offline in a shallow or source-archive checkout.
