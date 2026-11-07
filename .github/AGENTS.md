# CI and repository automation

[Development](../docs/development/README.md#continuous-integration) owns the required checks and the
workflow trust model.

- Pull Request, Verify, and Local E2E execute contributor code without deployment or administrative
  secrets. Release workflows are manual, restricted to `main`, and use the network-specific release
  environment; this repository has no preview-deployment or `workflow_run` workflow.
- Keep required aggregate checks stable, including when a path-filtered lane does not run.
- Keep benchmark RPC credentials separate from deployment environments.

Test changed automation at its executable boundary, including rejection cases, and keep checks
runnable without deployment secrets.
