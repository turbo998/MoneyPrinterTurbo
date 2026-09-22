# Azure PoC deployment

This deployment preserves the local Dockerfile and local providers. It uses a
dedicated resource group, existing **Entra-only** text/image/Speech resources,
and one immutable image for Streamlit, its loopback FastAPI sidecar, a render job,
and a maintenance job. **Preparation is not a successful deployment.** Complete
the validation and authenticated smoke tests below before sharing the URL.

## Safety and resource boundaries

| Resource | Configuration |
|---|---|
| Container App | Streamlit 8501 only; API `127.0.0.1:8080`; 0–1 replicas |
| Render job | Queue-triggered; 0–1 executions; parallelism 1; 2 CPU/4 GiB; 3600s; no platform retry |
| Maintenance job | `python -m app.cloud.worker maintain`; every five minutes UTC; 240s; 0.5 CPU/1 GiB |
| Storage | Private `tasks` blob container, `tasks` and `poison` queues, `tasks` table; Entra only, TLS 1.2 |
| Network | Dedicated VNet; exclusive delegated ACA subnet; separate subnet with blob/queue/table Private Endpoints and linked Private DNS zones |
| ACR | Basic; admin credentials off; MI `AcrPull`; remote Linux/amd64 build |
| Monitoring | Log Analytics: 30 days, 1 GB/day ingestion cap; ACA console/system and Storage data diagnostics |
| Identities | Web and worker separate; both Blob/Queue/Table Data Contributor; **only worker** has scoped OpenAI User and Speech User |

KEDA only measures queue depth. The application must claim, renew, checkpoint,
and acknowledge messages itself. The single-execution setting does not replace
application leases or idempotency. Maintenance must not perform new paid inference.
The identities are scoped to this application's Storage account and ACR, and
the worker's inference roles to the three individual existing accounts.
No shared account settings, local authentication, or model deployments are changed.

Storage explicitly uses `publicNetworkAccess: Disabled`,
`networkAcls.defaultAction: Deny`, and `bypass: None`. It also keeps
`allowBlobPublicAccess: false`, `allowSharedKeyAccess: false`, and container
`publicAccess: None`. The inherited `StorageAccount_PublicNetwork_Modify` policy
is respected: do not request an exemption or repeatedly enable the public endpoint.
ACR and the existing shared AI endpoints are unchanged; this is not a fully
private-egress deployment.

The new ACA environment is a **workload-profile environment with only the
Consumption profile**, not the legacy "Consumption-only environment" type.
Its exclusive `10.247.0.0/23` subnet is delegated to `Microsoft.App/environments`;
the modern type requires at least `/27`, so `/23` is sufficient. Storage Private
Endpoints use the separate, nondelegated `10.247.2.0/27` subnet in
`10.247.0.0/16`. Azure-provided DNS plus three linked zones
(`privatelink.blob.core.windows.net`, `privatelink.queue.core.windows.net`,
`privatelink.table.core.windows.net`) resolve standard Storage hostnames privately.
Neither SDK settings nor KEDA should use `privatelink` URLs. KEDA's managed-identity
queue scaler runs in this environment; actual private-DNS resolution and queue
activation still require live acceptance.

No NAT gateway, VM, GPU, or dedicated ACA workload profile is provisioned.
**Scale-to-zero does not mean zero cost:** three Private Endpoints have ongoing
hourly/data charges, Private DNS has zone/query charges, and ACR, Storage and logs
remain billable. VNet-injected ACA also creates platform-managed networking in a
managed resource group; review load-balancer/public-IP charges and do not modify
those managed resources manually.

Blob lifecycle deletes all `tasks/` blobs seven days after last modification,
including completed artifacts and old unfinished tasks. Soft delete adds another
seven days of recoverability and storage charges. Table records and poison messages
are not lifecycle-deleted; reconcile/clean these separately. Do not use this
retention policy for production archives. The log ingestion cap is not a spending
cap, and may stop diagnostics when reached. Monitor Storage, image, Speech,
rendering, and log costs independently.

## Prerequisites

- Azure CLI with Bicep and the `containerapp` extension; PowerShell 7.2+.
  `az bicep version` and `az extension show --name containerapp` must succeed.
  Install missing components only when needed.
- A signed-in principal able to deploy resources and assign the scoped data roles.
  Directory app-registration permissions are separate from subscription RBAC.
  Private Endpoint connection approval, VNet and Private DNS deployment permissions
  are required in the dedicated resource group; `Microsoft.Network` must be registered.
- Existing text/image/Speech endpoints and deployment names; Speech must have a
  custom `cognitiveservices.azure.com` subdomain. Keep local authentication disabled.
  `MPT_SPEECH_RESOURCE_ID` is mandatory, including with Speech SDK `token_credential`;
  it must reference that existing Speech account, not an endpoint URL.
- A tested single-tenant Entra app registration and a nonexpired client secret
  before runtime deployment. A directory administrator can supply them.
  No registration permissions means **stop with the safe foundation**, not
  publish an anonymous UI.
- A current `uv.lock` matching `pyproject.toml`, generated by the application owner.
  Remote builds use `uv sync --frozen --no-dev`; no lock update happens in the image.
  Review any package mirror URLs in the lockfile for reachability from ACR.
- Docker and azd are **not** required for the Azure CLI flow.

Run all commands at the repository root. The following are non-secret deployment
settings for the approved PoC; reusable Bicep has no subscription/tenant/account
identifiers embedded:

```powershell
$env:AZURE_SUBSCRIPTION_ID = '63b98714-aef9-4a1c-8018-418058e84bf7'
$env:MPT_TENANT_ID = '16b3c013-d300-468d-ac64-7eda0820b6d3'
$env:AZURE_ENV_NAME = 'moneyprinterturbo-poc-eus2'
$env:AZURE_RESOURCE_GROUP = 'rg-moneyprinterturbo-poc-eus2'
$env:AZURE_LOCATION = 'eastus2'
$env:MPT_ALLOWED_OIDS = '8922ff53-3609-44a8-92f0-fc46c7826929'
$env:MPT_ENTRA_CLIENT_ID = 'b4b51b4d-4686-4518-b097-503481e46c57'
$env:MPT_TEXT_RESOURCE_GROUP = 'rg-qichen2-7902'
$env:MPT_TEXT_ACCOUNT_NAME = 'rg-qichen2-7902-resource-0647'
$env:MPT_TEXT_ENDPOINT = 'https://rg-qichen2-7902-resource-0647.openai.azure.com'
$env:MPT_TEXT_DEPLOYMENT = 'gpt-4.1-mini-219696'
$env:MPT_IMAGE_RESOURCE_GROUP = 'Default-ActivityLogAlerts'
$env:MPT_IMAGE_ACCOUNT_NAME = 'qichen2-7212-resource'
$env:MPT_IMAGE_ENDPOINT = 'https://qichen2-7212-resource.openai.azure.com'
$env:MPT_IMAGE_DEPLOYMENT = 'gpt-image-2-1'
$env:MPT_SPEECH_RESOURCE_GROUP = 'rg-speech-diarization-poc-eus2'
$env:MPT_SPEECH_ACCOUNT_NAME = 'spch-diarization-poc-eus2-y525bucwek7oc'
$env:MPT_SPEECH_ENDPOINT = "https://$env:MPT_SPEECH_ACCOUNT_NAME.cognitiveservices.azure.com"
$env:MPT_SPEECH_REGION = 'eastus2'
$env:MPT_SPEECH_RESOURCE_ID = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:MPT_SPEECH_RESOURCE_GROUP/providers/Microsoft.CognitiveServices/accounts/$env:MPT_SPEECH_ACCOUNT_NAME"
az login --tenant $env:MPT_TENANT_ID
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
.\scripts\Validate-Azure.ps1
.\scripts\Test-AzureTooling.ps1
```

Never paste secrets into source files, command arguments, terminal transcripts,
azd environment files, screenshots, or logs. Run deployment in a trusted shell
without PowerShell transcription/debug tracing.

## Three-phase Azure CLI flow (no local Docker)

### 1. Safe foundation

The following validation and preview do not deploy resources. Their parameters
are **non-secret**. Keep the original environment name, subscription, location and
resource group: changing the name seed would create different Storage/ACR/identities.

```powershell
$bootstrapName = "$($env:AZURE_ENV_NAME)-bootstrap-vnet"
$bootstrapParameters = @(
  "environmentName=$env:AZURE_ENV_NAME", "location=$env:AZURE_LOCATION",
  "resourceGroupName=$env:AZURE_RESOURCE_GROUP",
  "textResourceGroup=$env:MPT_TEXT_RESOURCE_GROUP", "textAccountName=$env:MPT_TEXT_ACCOUNT_NAME",
  "imageResourceGroup=$env:MPT_IMAGE_RESOURCE_GROUP", "imageAccountName=$env:MPT_IMAGE_ACCOUNT_NAME",
  "speechResourceGroup=$env:MPT_SPEECH_RESOURCE_GROUP", "speechAccountName=$env:MPT_SPEECH_ACCOUNT_NAME"
)
az provider show --namespace Microsoft.Network --query registrationState --output tsv
az network list-usages --location $env:AZURE_LOCATION --output table
az deployment sub validate --name $bootstrapName --location $env:AZURE_LOCATION `
  --template-file .\infra\main.bicep --parameters @bootstrapParameters --no-prompt --output none
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap ARM validation failed.' }
az deployment sub what-if --name $bootstrapName --location $env:AZURE_LOCATION `
  --template-file .\infra\main.bicep --parameters @bootstrapParameters --no-prompt
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap what-if failed.' }
# Owner reviews the preview: no deletes or shared-account settings changes.
# Then deploy. Never use Complete mode/deployment stacks.
.\scripts\Deploy-Azure.ps1 -Phase Bootstrap
$env:MPT_BOOTSTRAP_DEPLOYMENT = $bootstrapName
.\scripts\Test-AzureNetwork.ps1
az containerapp env list-usages --resource-group $env:AZURE_RESOURCE_GROUP `
  --name mpt-rlgz72uq-env-vnet --output table
```

`infra/main.bicep` is subscription-scoped: it creates the dedicated group,
Storage, ACR, identities, monitoring, networking and the new ACA environment.
**No new app is created during bootstrap.** All nested deployments are Incremental.
Only the same inference role assignments reference shared AI accounts. The scripts
do not register providers, request quotas, or exempt policies; ARM validation and
preview remain the owner's preflight for applicable regional/governance limits.

### Blue-green resource changes

An existing environment cannot acquire VNet integration in place. For the approved
PoC, bootstrap creates `mpt-rlgz72uq-env-vnet`, VNet `mpt-rlgz72uq-vnet`, its two
subnets, PEs `mpt-rlgz72uq-pe-blob/queue/table` (one per service), three DNS zones,
three VNet links and three PE DNS zone groups. Azure also creates PE NICs and
ACA-managed network resources. Runtime creates `mpt-rlgz72uq-web-vnet`,
`mpt-rlgz72uq-render-vnet` and `mpt-rlgz72uq-maintain-vnet`; it does not rename or
replace resources in place.

The same `stmptrlgz72uqyetnu`, `crmptrlgz72uqyetnu`, `mpt-rlgz72uq-logs`,
`mpt-rlgz72uq-web` UAMI and `mpt-rlgz72uq-worker` UAMI are retained, including
all 11 data/inference/pull role assignments and existing data. Storage's firewall
default changes to Deny; public network access stays Disabled.
The old `mpt-rlgz72uq-env`, `mpt-rlgz72uq-web` app and `mpt-rlgz72uq-render/maintain`
jobs are **not updated, stopped or deleted**. The old scheduled job can keep
attempting its schedule until the owner explicitly retires it.
Only after new-runtime acceptance may the owner clean up those old application
resources. Never delete the resource group, Storage, registry, identities,
workspace or shared AI resources as part of this cutover.

`MPT_BOOTSTRAP_DEPLOYMENT=moneyprinterturbo-poc-eus2-bootstrap-vnet` selects the
new outputs. Runtime and Publish reject legacy outputs **before changing ingress**;
do not point them at the old `...-bootstrap` record or manually override names.
`Test-AzureNetwork.ps1` performs read-only ARM checks: effective Storage settings,
environment/subnet bindings, Approved PE connections, exact Storage/group/subnet
targets, DNS zone groups and VNet links. It returns the new `PublicUrl`/`Callback`
without modifying the registration. It does not prove in-container DNS or data access.

| Bootstrap output | Consumer |
|---|---|
| `AZURE_CONTAINER_APPS_ENVIRONMENT_ID` | New `-env-vnet`; runtime and callback lookup |
| `MPT_WEB_APP_NAME`, `MPT_WORKER_JOB_NAME`, `MPT_MAINTENANCE_JOB_NAME` | New `-vnet` runtime names |
| `MPT_NETWORK_MODE` | `storage-private-endpoints-v1`; stale-output guard |
| `AZURE_VIRTUAL_NETWORK_ID`, `MPT_ACA_SUBNET_ID`, `MPT_PRIVATE_ENDPOINT_SUBNET_ID` | Actual VNet and distinct subnet IDs |
| `MPT_STORAGE_RESOURCE_ID`, `MPT_STORAGE_ACCOUNT` | Existing dedicated Storage |
| `MPT_STORAGE_PRIVATE_ENDPOINT_IDS`, `MPT_PRIVATE_DNS_ZONE_IDS`, `MPT_PRIVATE_DNS_LINK_IDS` | Three-element arrays, ordered blob/queue/table |
| `MPT_WEB_IDENTITY_ID`, `MPT_WEB_CLIENT_ID`, `MPT_WORKER_IDENTITY_ID`, `MPT_WORKER_CLIENT_ID` | Existing web and worker identities |
| `AZURE_CONTAINER_REGISTRY_NAME`, `AZURE_CONTAINER_REGISTRY_ENDPOINT`, `AZURE_LOG_ANALYTICS_WORKSPACE_ID` | Unchanged registry and workspace outputs |

Runtime deployment `moneyprinterturbo-poc-eus2-runtime-vnet` returns
`environmentResourceId`, `webAppResourceId`, `internalWebHost`,
`workerJobResourceId`, and `maintenanceJobResourceId`. No secrets are outputs.

### 2. Build and private runtime

```powershell
# First installation / changed image ONLY: .\scripts\Build-AzureImage.ps1
# Network-only migration: keep the full already-verified digest in this shell.
# Build-AzureImage sets MPT_CONTAINER_IMAGE; never use a truncated hash.
if ([string]::IsNullOrWhiteSpace($env:MPT_CONTAINER_IMAGE)) {
  throw 'Set MPT_CONTAINER_IMAGE to the complete verified ACR image@sha256 digest.'
}
.\scripts\Deploy-Azure.ps1 -Phase Runtime `
  -EntraClientSecret (Read-Host 'Entra client secret' -AsSecureString)
```

The build helper stages an explicit source allowlist under the repository,
uploads it to `az acr build`, resolves the pushed image digest, and removes
the staging directory. It never packages `.git`, `.venv`, `.azure`, `storage`,
or `config.toml`. `Dockerfile.azure.dockerignore` additionally protects local
Docker builds. The base is Python 3.11 Bookworm with FFmpeg, Speech native
libraries, and Debian's open-licensed Noto CJK; the font is copied as
`resource/fonts/NotoSansCJK-Regular.ttc`, with Debian copyright/license notices.
No upstream bundled music or fonts are included. Code runs as UID/GID 10001;
`/app/storage`, `/app/config.toml`, and the parent directory for atomic config
replacement are writable. Dependency downloads, base images, and OS packages
still need release-time supply-chain review.

Runtime always deploys **internal ingress**, even on updates. It first closes
public ingress on the selected new `-web-vnet` app if it already exists, then
updates both sidecars and both new jobs to the same digest. Legacy resources are
never selected. The environment is external-capable (`internal: false`), but
that does not expose an app whose own ingress remains internal.
Each runtime deployment creates a new web revision so secret rotation cannot
leave an old replica using stale environment-secret values.
The internal API token is generated from 64 random bytes and saved as an ACA secret,
reused on updates by reading it into process memory. The Entra client secret and
token enter ARM as `secureString` parameters in an in-memory HTTPS request; they
are never written as parameter files or passed on CLI command lines.
UI and API receive the token; jobs do not. Neither secret appears in outputs.
ARM failures report HTTP status and a bounded error-code identifier, not request
bodies or service messages. Check execution/deployment state before retrying an
ambiguous failure; a client error does not prove the operation was rejected.

`-EntraClientSecret` is mandatory for every Runtime call and accepts a
`SecureString`. It does **not** automatically reuse the Entra secret or create
Graph credentials. Reuse the parent's already-held SecureString. If it was lost,
the owner may read `entra-client-secret` from the old app into memory, convert it
to SecureString without printing, and discard plaintext references. The new app
gets a new internal API token on first deployment; later updates reuse its token.
Do not put runtime secrets in `az deployment --parameters`, what-if CLI arguments,
files or debug output. `Deploy-Azure.ps1` has no runtime validate-only switch;
an owner performing ARM Runtime validation must send the secure parameters
in-memory over HTTPS and avoid dumping request/response bodies.

Wait for RBAC propagation before assuming image-pull, queue-scale, or inference
failures are configuration bugs. Do not repeatedly requeue paid requests.

### 3. Explicit authenticated publication

Configure the registration as **single tenant (`AzureADMyOrg`)**, with a Web
redirect URI:

```text
https://<web-app-name>.<environment-default-domain>/.auth/login/aad/callback
```

Use `(.\scripts\Test-AzureNetwork.ps1).Callback` for the **new** environment.
Preserve existing registration redirect URIs and append this callback while
testing blue-green; the parent owns that Graph update and any final removal of
the legacy URI. Do not regenerate a client secret.
The internal app hostname may contain `.internal.`; do **not** register that
internal hostname as the public callback. Follow the official Entra setup guide
below for the ID-token/hybrid-flow configuration and `api://<client-id>` audience.
Create the enterprise application/service principal as required by your tenant.
Directory setup is deliberately not automated or silently granted broad permissions.

```powershell
.\scripts\Publish-Azure.ps1
```

The publish guard closes ingress first, reads live EasyAuth settings, requires
single-tenant issuer/audience, HTTPS, no excluded paths, an exact OID allowlist,
and the correct client-secret reference. It also verifies the Entra registration's
single-tenant setting and public callback. Only then does it enable public ingress.
It checks anonymous root, media, download, WebSocket, and health routes without
following redirects. Unexpected responses close ingress again.
There is no `-SkipAuth` switch or anonymous fallback.

**Schema detail:** the stable ACA `2025-01-01` schema spells the authorization
property `identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities`;
`builtInAuthorizationPolicy` is not the property in this version. This policy
protects all application paths at the platform proxy, including Streamlit-owned
media/download handlers. The application must also fail closed for absent/forged
principals and enforce its allowlist. Read-back alone does not prove actual
authorized and unauthorized-user behavior; perform the browser tests below.

## Optional azd foundation flow

`azure.yaml` intentionally has no service deploy targets. Running plain
`azd deploy` cannot safely coordinate an API sidecar plus two jobs or the
authentication-before-publication sequence. Do not replace this with a public
placeholder image. azd is used for **provisioning only**, then the same scripts
perform ACR remote build and runtime publication:

```powershell
azd auth login
azd env new $env:AZURE_ENV_NAME
foreach ($key in @('AZURE_SUBSCRIPTION_ID','AZURE_LOCATION','AZURE_RESOURCE_GROUP',
  'MPT_TEXT_RESOURCE_GROUP','MPT_TEXT_ACCOUNT_NAME','MPT_IMAGE_RESOURCE_GROUP',
  'MPT_IMAGE_ACCOUNT_NAME','MPT_SPEECH_RESOURCE_GROUP','MPT_SPEECH_ACCOUNT_NAME')) {
  azd env set $key ([Environment]::GetEnvironmentVariable($key))
}
azd provision
# Import non-secret azd outputs into the current shell.
$values = azd env get-values --output json | ConvertFrom-Json -AsHashtable
foreach ($key in $values.Keys) {
  $value = $values[$key]
  if ($value -is [array]) { $value = ConvertTo-Json -InputObject $value -Compress }
  [Environment]::SetEnvironmentVariable($key, [string]$value)
}
Remove-Item Env:MPT_BOOTSTRAP_DEPLOYMENT -ErrorAction SilentlyContinue
.\scripts\Test-AzureNetwork.ps1
# Build only if the image changed; reuse the verified digest for network migration.
# Continue with Runtime and Publish exactly as above.
```

Do not run `azd init -t` over this repository or store the Entra secret with
`azd env set`. The azd binary is not required or installed by these scripts.

## Validation and release checklist

`Validate-Azure.ps1` performs only local/static checks: compiles both Bicep entry
points in memory, checks actual compiled PE target/group/subnet expressions,
DNS group/link references, subnet CIDRs/delegation, Storage Disabled/keyless,
blue-green names, Consumption-only profiles, Incremental mode and secure
parameters/internal ingress/loopback binding/allowlist, parses PowerShell,
and validates the Dockerfile and parameters.
It does not create resources or imply ARM validation succeeded.
`Test-AzureTooling.ps1` uses local CLI/ARM stubs to exercise fail-closed
authorization, legacy-output rejection before mutation, mocked live network
checks, deliberate compiled PE/DNS/subnet miswirings, and ACR build-context
allowlist/cleanup. It invokes the local Bicep compiler, but never deploys or builds
an image. Run both scripts after infrastructure changes.

Before provisioning, run ARM validation/what-if on `infra/main.bicep` with the
same non-secret parameters as the bootstrap command. Before live runtime updates,
review changes to `runtime.bicep`; secrets must remain secure parameters.
Use the Azure validate/deploy workflow in the owner's session.

Use the following checklist for releases and revalidation. The dated evidence
and limitations below identify what was actually exercised:

1. Run `Test-AzureNetwork.ps1`, then verify inside a **new** job that normal
   `<storage>.blob/queue/table.core.windows.net` hostnames resolve within
   `10.247.2.0/27`. Verify worker and web MI Storage access, Blob leases/renewal,
   queue send/receive/visibility-renew/ack/poison and Table ETag CRUD. Observe
   actual managed-identity KEDA activation; static templates and ARM checks alone
   cannot prove it. A laptop outside the VNet should not bypass Storage networking.
2. Entra login as the allowed user works; an authenticated user with a different
   OID receives 403; no anonymous route (including actual MP4/media/download URLs)
   exposes content. Verify WebSocket and video Range requests, not merely root HTML.
3. Test spoofed principal headers and the API token boundary. API port 8080 must
   not be reachable over public ingress, and no API URL should point browsers to localhost.
4. Worker MI can perform text/image/Speech inference and Storage operations;
   the web MI cannot perform inference. Do not test by enabling account keys.
5. Submit a short Chinese and English task; observe one worker, checkpoints,
   subtitle/audio alignment, private Blob persistence, and downloaded MP4 playback.
6. Restart the web revision while a job runs. Verify queue renewal, idempotency,
   maintenance recovery, poison handling, and `needs_review` for ambiguous paid calls.
7. Confirm no prompt, token, client secret, SAS, or sensitive content is leaked in logs.
8. Record image digest and successful app/job revisions. An update closes ingress;
   rerun publication checks. Rollback means redeploy a previously verified digest,
   not `latest`; verify schema compatibility before rolling application code back.

### Recorded live PoC acceptance (2026-09-22 UTC)

The deployment owner completed the following live acceptance, separately from
the static/offline checks. The authenticated endpoint is
[MoneyPrinterTurbo PoC](https://mpt-rlgz72uq-web-vnet.livelystone-f0c1d23a.eastus2.azurecontainerapps.io).
The final image digest is
`sha256:e07742e5a1ca03eab08b8dd81cf698570c8ab796190829a4463b51febf992b50`.

The new VNet-integrated environment/runtime and all three Approved Private
Endpoints are operational. From the worker MI execution, Blob, Queue and Table
hostnames resolved to `10.247.2.4`, `10.247.2.5` and `10.247.2.6`, respectively.
Blob lease, Table ETag and Queue operations succeeded; KEDA actually consumed
queued work. The web app was restored to min replicas **0**, max replicas **1**;
the new worker concurrency remains **1**.

Guarded publication completed. The allowed user completed real Entra SSO and
basic-profile consent, and the existing Streamlit cloud panels worked.
Anonymous requests, forged principal headers, invalid bearer tokens and an
actual public video media URL without authentication returned **401**. Internal
API requests without credentials returned **401**; a wrong user OID returned
**403**. This wrong-OID check is not a second-account Entra login test.

| Task | Live result |
|---|---|
| Chinese `186fa782-2d04-50d1-9a34-20c7c36b0426` | Uploaded original geometric PNG material; 1080x1920 H.264/AAC, 30 fps, 6.40 seconds; SRT based on 14 genuine Speech word-boundary events |
| English `0075ee92-d1a1-549b-9373-eeba0f488574` | One actual Foundry-generated image; 1920x1080 video, 6.31 seconds; SRT based on 16 genuine Speech word-boundary events |
| Text `86359249-0544-51ca-a3ba-82fee8571b35` | Worker managed-identity model request succeeded |

The controlled paid acceptance performed exactly **one text request, two Speech
requests and one image-generation request**, with no duplicate paid POSTs.
UI/API-enqueued work survived a web restart. Duplicate delivery of the three
acceptance tasks left each task's attempt count at **1**. Live
`pending_dispatch` fault injection recovered successfully; expired-lease recovery
completed with an attempt count of **2**. An injected pre-existing paid-operation
fence moved the task to `needs_review` without making a paid request.

The no-charge browser-submitted task
`8fcc650f-6f46-4fcc-851a-45b2aea80274` succeeded after navigating to `about:blank`
to disconnect and then reconnecting. In the browser, the English video played
fully to 6.31 seconds across the five-second refresh without replacing its media
node. A Range request returned **206** with **1,024 bytes**, audio preview worked,
and actual MP4/SRT download hashes matched the private Blob artifacts.
Cloud evidence remains in the private `tasks` container under
`<task-id>/checkpoints/...` and `<task-id>/result.json`; retrieve user-facing
artifacts through the UI's Tasks and downloads panels, not public Blob URLs.

Recorded test evidence: **1,382 passed, 19 skipped, 10,616 subtests, 80% coverage**;
the cloud suite passed **75 tests** after the real-SDK constructor fix;
**83 offline infrastructure-tooling checks** passed.

### Remaining limitations and operational obligations

- A second real Entra account was **not** used for an SSO login. The internal
  wrong-OID 403 and anonymous/forged-request 401 results do not establish that
  separate end-to-end account scenario.
- Python 3.13 remains in the unchanged CI matrix. No local Python 3.13 execution
  is claimed by this acceptance record.
- **Rotate the existing single PoC OAuth client secret before
  `2026-09-29T17:39:23Z` and update the runtime secret.** Otherwise Entra login
  will fail after expiry. No credential value is included in this document.
- There is **no automatic teardown**. Three Private Endpoints, Private DNS and
  ACR retain ongoing charges even with web min replicas 0; Storage, logs and
  platform-managed networking can also remain billable.
- At evidence capture, the deployment owner was separately deleting only the
  four legacy environment/web/render/maintenance resources. Completion of that
  cleanup is not asserted here. Do not repeat the deletion or include Storage,
  identities, ACR or the new VNet/runtime resources in it.

Static validation remains distinct from live evidence and is not a substitute
for revalidation after changes. Missing Graph read permission still blocks the
publish guard; no anonymous or alternate-authentication fallback is implemented.

### Parent-run read-only worker DNS probe

The new render job container is `worker`; maintenance container is `maintenance`.
Both retain `AZURE_CLIENT_ID` for the existing worker MI and all Storage/AI/Speech
environment variables. UI/API use the existing web MI. Network migration does
not change those bindings, application commands, or raw JSON queue payloads.

The following optional owner-run execution only resolves DNS and prints no secrets;
it does not enqueue work or invoke paid AI. It still consumes a Job execution.
It replaces that execution's worker command, not the stored Job. Inspect existing
executions before retrying an ambiguous start response.

```powershell
. .\scripts\Azure-Common.ps1
Assert-AzureContext
$o = Get-BootstrapOutputs
$null = Get-PrivateNetworkStatus $o
$jobId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$($o.AZURE_RESOURCE_GROUP)/providers/Microsoft.App/jobs/$($o.MPT_WORKER_JOB_NAME)"
$job = Invoke-Arm "${jobId}?api-version=2025-01-01"
$template = $job.properties.template | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
# StartJobExecutionTemplate rejects volumes:null; do not blindly forward job-show.
if ($template.ContainsKey('volumes')) {
  if ($null -ne $template.volumes) { throw 'Review non-null volumes against the start API before overriding.' }
  $template.Remove('volumes')
}
$worker = @($template.containers | Where-Object name -EQ 'worker')
if ($worker.Count -ne 1) { throw 'Expected exactly one worker container.' }
$worker[0].command = @('python')
$worker[0].args = @('-c', @'
import ipaddress, os, socket
subnet = ipaddress.ip_network("10.247.2.0/27")
for service in ("blob", "queue", "table"):
    host = f"{os.environ['MPT_STORAGE_ACCOUNT']}.{service}.core.windows.net"
    addresses = {entry[4][0] for entry in socket.getaddrinfo(host, 443, socket.AF_INET)}
    if not addresses or any(ipaddress.ip_address(ip) not in subnet for ip in addresses):
        raise RuntimeError(f"Storage private DNS failed for {service}: {sorted(addresses)}")
    print(service, sorted(addresses))
'@)
# Keep complete containers/env/resources; this endpoint does not partially merge.
$execution = Invoke-Arm "${jobId}/start?api-version=2025-01-01" -Method POST -Body $template
$execution.name
```

`Invoke-Arm` takes a relative ARM resource path, not a full management URL.
This DNS-only example is not a substitute for the controlled MI/lease/queue/Table
and KEDA acceptance recorded above. Do not repeat paid requests or normal task
submissions merely because DNS passed. There is no Application Insights SDK instrumentation
in these infrastructure artifacts; ACA/Storage diagnostics are platform logging,
not application tracing.

## IaC implementation and references

The AVM pattern catalog and resource modules for Container App and Job were
researched first. This PoC uses small raw, strongly typed Bicep modules: the Azure
MCP schema/best-practices services timed out, and locally compilable pinned stable
API definitions avoid an additional registry-module restore dependency during
the tightly controlled private-runtime/auth/publication sequence. This is a
documented exception, not a claim that AVM lacks these resources. The templates
are checked by Bicep 0.42.1; no `any()` schema escape hatch is used.

- [AVM pattern catalog](https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-pattern-modules/)
- [AVM Container App](https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/app/container-app)
- [AVM Container App Job](https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/app/job)
- [ACA authConfigs stable schema](https://learn.microsoft.com/azure/templates/microsoft.app/2025-01-01/containerapps/authconfigs)
- [ACA Jobs stable schema](https://learn.microsoft.com/azure/templates/microsoft.app/2025-01-01/jobs)
- [Entra authentication](https://learn.microsoft.com/azure/container-apps/authentication-entra)
- [Managed-identity scaling](https://learn.microsoft.com/azure/container-apps/scale-app)
- [Event-driven Jobs](https://learn.microsoft.com/azure/container-apps/tutorial-event-driven-jobs)
- [ACA custom virtual networks and subnet types](https://learn.microsoft.com/azure/container-apps/custom-virtual-networks)
- [Storage Private Endpoints and DNS](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints)
- [Private Endpoint Bicep schema](https://learn.microsoft.com/azure/templates/microsoft.network/2024-05-01/privateendpoints)
