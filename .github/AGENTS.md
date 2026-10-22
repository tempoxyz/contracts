# CI and repository automation

[Development](../docs/development.md#continuous-integration) owns the required checks and the
workflow trust model, including preview deployment.

- Untrusted PR code never receives deployment or administrative secrets. Privileged `workflow_run`
  jobs execute trusted default-branch code and validate same-repository provenance before consuming
  artifacts.
- Keep required aggregate checks stable, including when a path-filtered lane does not run.
- Keep benchmark RPC credentials separate from deployment environments.

Test changed automation at its executable boundary, including rejection cases, and keep checks
runnable without deployment secrets.
