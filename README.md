# Dataverse metadata audit

**Who changed my form?** Track who changed what in Dataverse / Dynamics 365 customizations, such as forms,
views and columns. Dataverse auditing doesn't cover this; Microsoft states that auditing *"isn't supported on
table or column definition changes."*

This project combines a small plug-in, a snapshot poller and Git to give you:

- **What** changed: a real diff of FormXml, FetchXml/LayoutXml and column metadata
- **When** it changed: within one poll interval
- **Who** changed it: from a log of every Publish, with an honest confidence label

![Architecture](docs/images/architecture.png)

> Read the write-up: [docs/medium-article.md](docs/medium-article.md) · Background research: [docs/research-report.md](docs/research-report.md)

## How it works

| Piece | Gives you | Where it runs |
|---|---|---|
| **Publish logger plug-in** | **Who** published and **which components** (ParameterXml), the moment it happens | Inside Dataverse (synchronous PostOperation on `Publish` / `PublishAll`) |
| **Snapshot poller** | **What** changed (Git diff) and roughly **when** | Your machine or a scheduled job (read-only against Dataverse) |
| **Correlation** | Joins the two and labels each change with a confidence | Part of the poller |

![Sequence](docs/images/sequence.png)

Why `Publish`? Plug-ins can't be registered on `CreateAttribute`, `UpdateEntity`, `ImportSolution`, or
Create/Update on `systemform`/`savedquery`. `Publish` and `PublishAll` are the only customization messages
that accept custom steps, and nearly every maker edit ends with a publish.
`scripts/Test-MetadataAuditFeasibility.ps1` checks this against your own environment.

## Repository layout

```
plugin/MetadataAudit.Plugins/            C# plug-in (net462, strong-name signed)
solution/                                Exported Dataverse solution (unmanaged + managed)
scripts/DataverseApi.psm1                Web API + Azure CLI auth helpers
scripts/Test-MetadataAuditFeasibility.ps1  Read-only checks: what can be audited / plugged / polled
scripts/Install-PublishLogger.ps1        Creates log table + registers plug-in (changes the environment)
scripts/Invoke-MetadataSnapshot.ps1      Snapshot + diff + attribution (read-only)
scripts/New-SigningKey.ps1               Generates the plug-in's strong-name key
docs/                                    Article, research report, diagrams (SVG + PNG)
```

## Prerequisites

- Windows PowerShell 5.1+, Git
- Azure CLI signed in with an account in the environment's tenant (`az login --tenant <tenant>`).
  The scripts detect the tenant from the environment URL and use the matching `az` account.
- .NET SDK, only if you build the plug-in yourself
- System Administrator or System Customizer role in the environment, for install

## Quick start

### 0. Check what your environment allows (read-only)

```powershell
.\scripts\Test-MetadataAuditFeasibility.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/
```

### 1. Install the publish logger

**Option A: import the solution.** Import `solution/MetadataAuditPrototype_1_0_0_0_managed.zip` (or the
unmanaged zip) in make.powerapps.com → Solutions → Import.

**Option B: build and install from source.**

```powershell
.\scripts\New-SigningKey.ps1
dotnet build plugin\MetadataAudit.Plugins -c Release
.\scripts\Install-PublishLogger.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/
```

The install script creates, inside unmanaged solution **MetadataAuditPrototype** (publisher `metadataaudit`, prefix `mda`):

- table `mda_customizationpublishlog` (message, user, initiating user, correlation id, summary, ParameterXml)
- sandbox assembly `MetadataAudit.Plugins` with type `MetadataAudit.Plugins.PublishLoggerPlugin`
- steps `MetadataAudit: log Publish` and `MetadataAudit: log PublishAll` (stage 40, synchronous; unsecure config = table prefix)

The plug-in writes as SYSTEM and swallows its own errors, so it never blocks a maker's publish.
It's safe to re-run, and `-Uninstall` removes everything except the publisher.

### 2. Run the snapshot poller

```powershell
.\scripts\Invoke-MetadataSnapshot.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/
# limit to some tables
.\scripts\Invoke-MetadataSnapshot.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com/ -Tables account,contact
```

The first run is a baseline (about 6 minutes in our test environment: 967 forms, 3,281 views, 7,745 columns).
Later runs are incremental (about 15 seconds):

- forms by `publishedon`
- views by `modifiedon`
- columns by `RetrieveMetadataChanges` version stamp

Each run that finds changes commits to `snapshots/<env>` and writes `changes/<timestamp>.md|json`.

```powershell
git -C snapshots\contoso log --oneline
git -C snapshots\contoso show HEAD
```

Schedule it every 5–15 minutes with Task Scheduler, Azure Automation or a pipeline. It **must** run at least once
within the environment's `ExpireSubscriptionsInDays` (7 days in the environment we tested). If the version stamp
expires, the poller re-baselines the columns automatically.

### Attribution labels

| Label | Meaning |
|---|---|
| `direct` | A publish log row's ParameterXml names this component id |
| `corroborated` | A publish of this component's table happened in the window |
| `last-writer` | `savedquery.modifiedby` at detection time (views only; overwritten by the next edit) |
| `deployment` | Change falls inside a solution import/uninstall window (solution history has no user) |
| `candidate` | A PublishAll happened in the window; it doesn't say which components |
| `unattributed` | Nothing matched |

## Native signals, for reference

![Native signals](docs/images/signals.png)

## Known gaps

- **Unpublished edits** aren't tracked; forms and columns are seen once published.
- **PublishAll** has no component list, and `PublishAllAsync` can't take plug-ins.
- **Solution imports** don't go through Publish, so they get `deployment` (solution name, no user).
- **Creating a column** is a metadata call that no plug-in can see; it's attributed through the publish that usually follows.
- The maker portal publishes the whole table when saving a view or form, so views and forms reach `corroborated`, not `direct`.
- Web resources, site maps, app modules, charts and business rules aren't snapshotted yet.
- Microsoft Purview activity logs (production only) aren't wired in yet. They're the natural next "who" source.

## Diagrams

`docs/images/*.svg` are the sources. Run `docs/images/render.ps1` to regenerate the PNGs (uses headless Edge).

## License

[MIT](LICENSE). This is a prototype: test it in a non-production environment first.
