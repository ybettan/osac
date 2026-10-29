# OSAC-6202 implementation notes

## Code fix

The AAP NATGateway provider now inserts owned forwarding and bypass rules
before shared chain `RETURN` sentinels. Forwarding rule reconciliation compares
iptables selector semantics so `iptables -S` output reordering is idempotent.
Namespace SNAT rules are inserted before existing `POSTROUTING` rules, keeping
them ahead of broad translation rules.

## E2E coverage

The rebased `e2e` runner covers source-rule ordering, peer-aware lease checks,
retry identity, Subnet source add/remove, direct upstream packet observation,
and dependency-ordered cleanup. The endpoint probe targets the direct upstream
link and verifies the observed source is the allocated ExternalIP, including
IPv4-mapped BusyBox source formatting.

## Validation

- AAP NATGateway and network unit tests passed.
- E2E focused unit tests: 97 passed.
- Changed-file pre-commit checks passed.
- Component integration playbook passed.
- Final NATGateway lifecycle reached SNAT observation, retry, Subnet churn,
  peer isolation, and ordered cleanup; stale interrupted-run artifacts were
  recovered with the supported cleanup path.
