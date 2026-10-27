# Prepare the Arc demo with an assistant

This is an operator handoff, not another presentation guide. The assistant uses
[AGENTS.md](../AGENTS.md), [runbook.md](runbook.md) and
[lifecycle.md](lifecycle.md) for operations. The presenter receives
**`.local/presenter-runsheet.md`**, already filled with portal links and KQL.

## Give the assistant this request

```text
Prepare the Arc part of this demo for presentation.

Read AGENTS.md, docs/runbook.md, docs/lifecycle.md and docs/troubleshooting.md.
Keep the existing lab running. For an existing lab, use its retained target and
configuration; do not redeploy, reskin, rotate credentials or reset workloads
just to prepare a presentation.

Ask for the explicit tenant/subscription and any missing retained setup inputs.
For a new deployment, also confirm the notification email, selected workloads
and cost scope. Default to the Arc/Monitor spine; do not make customization or
optional Container App/AKS/SQL scenarios a prerequisite for the Arc story.

1. Verify the exact supplied target without changing CLI defaults. Use normal
   prerequisites/preview and obtain approval before any deployment, activation,
   repair, provider registration, assessment, fault, email test or other write.
2. Follow the runbook/lifecycle path for the approved operation. Preserve VM/SP
   credentials, retained identities/data and workload fault flags. Never run a
   destructive lifecycle rehearsal against this in-use lab.
3. Verify Active readiness independently, preserving dated JSON evidence outside
   source. Pending telemetry is not a presenter-ready handoff. Monitor readiness
   does not establish app health, patch completion, policy compliance or full EDR.
4. Save only the documented nonsecret presenter fields in .local/demo-context.json
   using the confirmed inputs and actual saved resource IDs. Follow the field
   table in docs/runbook.md; do not copy credentials, whole manifests or private
   runtime files. Keep the evidence timestamp accurate.
5. Run scripts/New-PresenterRunsheet.ps1. Hand over .local/presenter-runsheet.md,
   not an input card, a list of IDs to find or a second set of presentation steps.
   The guide is generated offline and does not itself verify current health.
6. If a prepared SRE companion guide exists, record its actual absolute path as
   companionSreRunsheetPath; generation computes a relative link. Otherwise omit
   it. Keep SRE instructions in the SRE repo.
7. Refresh the local context/guide after later successful preparation changes its
   resources. Report actual gaps plainly. Leave the lab active unless the user
   separately asks to park or remove it.
```

The [local context field table](runbook.md#prepare-the-local-presenter-guide)
is the single setup contract. Plain Markdown does not interpolate JSON;
`New-PresenterRunsheet.ps1` fills the tracked [runsheet template](runsheet.md).
The entire `.local/` folder stays ignored. Historical evidence can produce a
review copy, but must not be relabelled as fresh readiness.

## Keep optional features optional

The [runbook](runbook.md) owns commands and preflight; [cost.md](cost.md) owns
selected-workload estimates. SQL Server/Arc SQL/BPA stays off by default; read
[the support decision](sql-arc-spike.md) before considering it.
The [LOB sample](../samples/lob-arc-app/README.md) needs separate preparation and
fresh source-specific events; its presence in source does not prove installation.
Notification configuration is not delivered-email proof; do not send a test
without approval.

## Hand off to SRE Agent

For an explicitly requested **combined Arc + SRE activation**, complete Arc
activation and verify Ready before continuing in the configured companion.
That repo owns SRE readiness and the conversational post-activation incident
offer: from this repo root use
`../sre-agent/docs/ai-deploy-handbook.md#post-activation-incident-offer`
only if the companion exists.

After SRE readiness succeeds, the SRE-owning assistant offers the existing
incident once. Declining leaves the demo ready. Accepting uses the established
T09 observation/recovery flow with the human's actual Review approval.
Do not add an orchestrator prompt, duplicate offer or command checklist for the
presenter. **Arc-only activation never offers or induces an incident.**

Parking is a separately approved operator action: companion first, then Arc
through its normal lifecycle scripts. Retained storage/services can still bill.
