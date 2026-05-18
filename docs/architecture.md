# Architecture

> What the deploy creates and how it's wired together.

## Topology

```mermaid
flowchart TB
    subgraph sub["Azure Subscription (target)"]
        direction TB

        subgraph rg_arc["rg-arc-demo (Arc + observability)"]
            LAW[("Log Analytics<br/>law-arc-demo")]
            DCR1[/DCR — core perf/events/syslog/]
            DCR2[/DCR — VM Insights/]
            DCR3[/DCR — Change Tracking/]
            WB[Workbook<br/>Estate Overview]
            AG[Action Group<br/>email]
            AR[Alert rule<br/>heartbeat missing >10m]
            ARC1[/Arc machine<br/>win-app-01..03/]
            ARC2[/Arc machine<br/>win-sql-01..02/]
            ARC3[/Arc machine<br/>lnx-app-01..03/]
            SQL1[/Arc SQL instance/]
        end

        subgraph rg_infra["rg-arc-demo-infra (backing infra)"]
            VNET[VNet 10.50.0.0/16<br/>+ subnet snet-vms]
            NSG[NSG nsg-arc-demo]
            NAT[NAT Gateway<br/>+ public IP]
            KV[(Key Vault<br/>admin password)]
            VM1[Azure VM<br/>win-app-01..03]
            VM2[Azure VM<br/>win-sql-01..02]
            VM3[Azure VM<br/>lnx-app-01..03]
            SCHED[8× auto-shutdown<br/>schedule @ 19:00]
        end

        DEFENDER([Defender for Servers<br/>Plan 2])
        POL([Policy: MCSB])
        POL2([Policy: NIST 800-53 r5])
        BUDGET([Budget AUD 200/mo])
    end

    INET((Internet<br/>gbl.his.arc.azure.com<br/>Defender + AMA endpoints))

    VM1 -. installs Arc agent .-> ARC1
    VM2 -. installs Arc agent .-> ARC2
    VM3 -. installs Arc agent .-> ARC3
    VM2 -. Arc SQL ext .-> SQL1

    ARC1 -.->|DCR assoc| DCR1
    ARC2 -.->|DCR assoc| DCR1
    ARC3 -.->|DCR assoc| DCR1
    ARC1 -.->|DCR assoc| DCR2
    ARC1 -.->|DCR assoc| DCR3

    DCR1 --> LAW
    DCR2 --> LAW
    DCR3 --> LAW
    LAW --> WB
    LAW --> AR
    AR --> AG

    VM1 --> NSG
    VM2 --> NSG
    VM3 --> NSG
    NSG --> VNET
    VNET --> NAT
    NAT --> INET

    DEFENDER -. protects .-> ARC1
    DEFENDER -. protects .-> ARC2
    DEFENDER -. protects .-> ARC3
    DEFENDER -. protects .-> SQL1
    POL -. evaluates .-> ARC1
    POL2 -. evaluates .-> ARC1
```

## Two resource groups, why

- **`rg-arc-demo`** — the things you'd have in a real customer environment (Arc machines, LAW, DCRs, workbook, alerts).
- **`rg-arc-demo-infra`** — the backing Azure VMs we use to *simulate* on-prem hosts. In a real engagement, these wouldn't exist — the Arc agent would be installed on actual on-prem servers.

Keeping them separate makes the demo flow read correctly in the portal (the customer never sees the "infra" RG; you only show them `rg-arc-demo`).

## Data flow

1. **Azure VMs** boot and the deploy script installs the **Connected Machine Agent** (`azcmagent`) with `MSFT_ARC_TEST=true` (officially supported for demo scenarios) so it registers a **Microsoft.HybridCompute/machines** resource in `rg-arc-demo`.
2. The deploy script then installs three extensions on each Arc machine:
   - **AzureMonitorAgent** (or **AzureMonitorWindowsAgent**) — collects perf, events, syslog.
   - **DependencyAgentWindows** (Windows only — Ubuntu kernel unsupported) — feeds the VM Insights Map.
   - **ChangeTracking-Windows** / **ChangeTracking-Linux** — tracks file/software/registry/service changes.
3. Each Arc machine has **three DCR associations** (core / VM Insights / Change Tracking). The DCRs route to the same workspace.
4. **Defender for Servers Plan 2** is enabled at subscription scope; it auto-deploys the MDE extension and (for SQL hosts) the Defender for SQL extension.
5. **MCSB + NIST 800-53 r5** policy initiatives are assigned at subscription scope — their results power the regulatory compliance scorecard in Defender for Cloud (~12h to first populate).
6. The **Estate Overview workbook** pulls all of the above into one persona-ordered dashboard.

## Networking

- VMs sit in a single `/24` subnet behind an empty NSG (no inbound rules).
- A **NAT Gateway** provides outbound internet for the Arc agent's outbound-only API calls (required — Azure default outbound is being deprecated).
- The NAT GW is deleted by `Hibernate-ArcDemo.ps1` to save ~AUD 55/mo and recreated by `Activate-ArcDemo.ps1`.

## Identity

- VMs use system-assigned managed identities (for AMA on Linux, and SQL Arc extension).
- A service principal **`sp-arc-demo-onboard`** with the *Azure Connected Machine Onboarding* role on `rg-arc-demo` is created once and reused — its only job is for the Arc agent to register on first install.
- Key Vault stores the local-admin password (single secret `vm-admin-password`).

## Cost notes

See [`cost.md`](cost.md) for the breakdown by state (active / hibernated / removed).
