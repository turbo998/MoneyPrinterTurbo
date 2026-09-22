# MoneyPrinterTurbo Azure deployment plan

Status: Validated

## Scope and approval

Modernize the existing Streamlit/FastAPI/FFmpeg application without removing local
mode or existing providers. The user authorized implementation, deployment,
verification, and a feature-branch pull request to the fork. Parent-session
implementation updates take precedence over earlier approval gates.

## Azure context

- Subscription: `63b98714-aef9-4a1c-8018-418058e84bf7`
- Tenant: `16b3c013-d300-468d-ac64-7eda0820b6d3`
- Region: `eastus2`
- Proposed dedicated resource group: `rg-moneyprinterturbo-poc-eus2`
- Existing shared Foundry and Speech resources: Entra authentication only;
  do not change networking, local authentication, or model deployments.

## Intended architecture

Streamlit plus internal FastAPI in Container Apps, event-driven single-task
Container Apps Jobs, Blob/Queue/Table persistence, managed identities, and
single-tenant authenticated access. Use Bicep and Azure Developer CLI.

## Execution checklist

- [x] Read inherited design and inspect baseline.
- [x] Confirm architecture, dependencies, Azure context and directory permissions.
- [x] Implement providers, durable execution, access control, UI/API integration.
- [x] Create container, infrastructure, deployment configuration, documentation.
- [x] Run targeted tests, regressions, container and IaC validation.
- [x] Invoke azure-validate, then azure-deploy.
- [x] Verify authenticated access, durable execution, and short bilingual videos.
- [ ] Commit and push feature branch; create fork-targeted pull request.

## Safety and cost boundaries

No anonymous publication, new model deployments, GPUs, Sora, voice cloning, or
social posting. Single worker concurrency; 60-second output, eight generated
images, one output, and ten queued tasks. Unknown paid-request outcomes require
review rather than automatic resubmission. Background music defaults off and
container fonts must be open licensed.

## Implementation decisions

- Recipe: Bicep + AZCLI guarded bootstrap/runtime/publication; `azure.yaml` is also
  provided for azd. ACR remote build avoids a local Docker Desktop dependency.
- Keep the original Streamlit shell/styles and local UI. Cloud mode has bounded
  server-managed provider panels, persistent history, logs, uploaded media/BGM,
  audio preview, exact preview reuse, subtitles and same-origin media/downloads.
- Shared FastAPI submission service uses immutable parameter/provider manifests,
  private Blob artifacts with SHA256 verification, Table ETag task ownership,
  renewable Queue visibility and a global renewable Blob worker lease.
- Admission is serialized and capped at ten active tasks. Scheduled maintenance
  repairs pending/expired work. A `submitting` fence before every paid operation
  prevents uncertain calls from being replayed. SDK/HTTP automatic paid retries
  are disabled. Explicitly recovered safe stages consume existing checkpoints.
- Entra application registration created for this app, client ID
  `b4b51b4d-4686-4518-b097-503481e46c57`, single-tenant. Runtime remains internal
  until callback, client secret, authentication and OID authorization checks pass.
- Built-in EasyAuth protects all routes, including Streamlit media, using
  `defaultAuthorizationPolicy.allowedPrincipals.identities`. Streamlit also checks
  trusted platform principal tenant/OID; the loopback sidecar requires a separate
  service token and approved user identity. No anonymous intermediate publication.
- Container uses open-licensed Noto Sans CJK, FFmpeg and Python 3.11, non-root user;
  upstream fonts/music and local secrets are excluded from build context.
- Raw Bicep resources preserve precise managed-identity Job/authentication controls;
  official resource schemas and Microsoft Learn were used after Azure MCP timed out.
  Existing shared AI resources are referenced only by minimal role assignments.
- MAI preview voices are visibly disabled pending verified subtitle support.
  Neural Speech word-boundaries are required; no fabricated timing/Edge fallback.
- Local Entra provider options are documented in `config.example.toml`.

## Preparation evidence

- 243 upstream provider/task tests passed (4 environment-dependent skips).
- 64 new cloud tests passed: authorization, boundaries, ETag conflicts, pending
  dispatch/recovery, duplicate terminal messages, checksums, paid timeout fences,
  all `stop_at` paths and preview-reuse validation. Full repository ruff passed.
- Full upstream Windows coverage run is in progress; failures will be classified
  and addressed before claiming full regression success.
- Both Bicep entry points compile with Bicep 0.42.1; 24 offline deployment-tooling
  checks passed. ARM quota/what-if/runtime validation remains to be completed.
- Real user-identity Speech SDK 1.48.2 `token_credential` synthesis succeeded:
  5.400-second MP3, 11 genuine Chinese word boundaries, two valid SRT cues.
- Real user-identity Foundry image sample supplied by parent: `gpt-image-2-1`,
  v1 images/generations, low quality, 1024x1536, 203 tokens.
- Real local pipeline produced a 1080x1920, 30fps H.264/AAC Chinese MP4 with
  Noto CJK subtitles and verified <=1-frame audio/video duration difference.
  Audio/image checkpoints were reused; no additional paid requests during retries.
- Media evidence: session artifacts `files/local-media-zh/acceptance.json`,
  `ffprobe.json`, `final-1.mp4`, `subtitle.srt`; Speech evidence
  `files/speech-smoke-zh.json`. These are local evidence, not worker-identity proof.
- All lockfile hashes either match the upstream lock or were checked against
  official PyPI metadata. Canonical PyPI URLs retained; a temporary TLS-verified
  mirror was needed only for this workstation's failed files.pythonhosted TLS.

## Deployment validation still required

Remaining gates: subscription/region capacity, ARM validation/what-if, actual
remote container build, managed-identity inference/Speech/Storage, unauthorized
HTTP rejection, browser access, duplicate/restart recovery and bilingual cloud
media. Do not label these as complete based on local tests.

## 7. Validation Proof

This validation authorizes **foundation bootstrap only**. It creates the registry,
Storage, managed identities, monitoring and environment without a public app.
Runtime and public ingress are a separate gate: build the actual image in ACR,
validate runtime parameters/roles, then verify protected routes before publication.

All foundation validation checks pass:

- Validation performed 2026-09-22 17:07-17:16 UTC.
- [x] Bicep compilation: `scripts/Validate-Azure.ps1` compiled both entry points.
- [x] Template validation: `az deployment sub validate --location eastus2
  --template-file infra/main.bicep` with actual environment parameters returned
  `Succeeded`, correlation `e53c74c1-359c-4fcf-ae2c-f9a164cbc295`.
- [x] What-if: `az deployment sub what-if --result-format ResourceIdOnly
  --no-pretty-print` succeeded; all evaluated resource changes are Create,
  no Delete/Modify of existing shared resources. Dynamic MI role assignments
  report Unsupported/short-circuit and require live post-bootstrap verification.
- [x] Authentication: Azure CLI shows the selected subscription and tenant;
  deployer has subscription Owner. Dedicated Entra registration creation succeeded.
- [x] Lint/static checks: complete Python ruff and 24 deployment-tooling checks pass.
- [x] Azure Policy: three inherited subscription assignments concern Defender
  data/database protection; provider-level ARM validation reports no policy denial.
- [x] Region/provider capacity: Microsoft.App and Microsoft.ContainerRegistry
  registered; eastus2 environments 2/50, storage accounts 1/250. Environment CPU
  quota is checked after creation, before deploying runtime.
- [x] Application build prerequisite: Python source imports, 64 cloud unit tests,
  243 upstream provider regressions and a real local 1080p media pipeline succeed.
  No runtime image is assumed built at this bootstrap stage.

Full Windows regression evidence remains separate from this infrastructure gate.
The initial sparse checkout omitted test fonts; six exact upstream fixtures were
restored by Git SHA (without changing sparse patterns or putting them in Docker).
The affected 16 BGM UI tests now pass. Do not report the original incomplete
coverage run as passed.

### Static role verification

Verified 11 resource-scoped assignments against actual built-in definitions:
WEB and WORKER each receive Blob Data Contributor
(`ba92f5b4-2d11-453d-a403-e96b0029c9fe`), Queue Data Contributor
(`974c5e8b-45b9-4653-ba55-5f855dd0fb88`), Table Data Contributor
(`0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3`) on the new Storage account, and AcrPull
(`7f951dda-4ed3-4680-a7ca-43fe172d538d`) on the new ACR. WORKER alone receives
OpenAI User (`5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`) on each existing text/image
account and Speech User (`f2dc8367-1007-4938-bd23-fe263f013447`) on existing Speech.
Blob lease operations, queue renewal/poison delivery and Table conditional CRUD
are covered. No subscription/RG-scoped application assignment is declared.

Monitoring is explicitly Log Analytics console/system and Storage diagnostics,
not Application Insights instrumentation. Runtime task logs correlate by task ID.
The exact upstream Windows CI smoke selection also passed: 168 passed, four
environment-dependent skips, 64 subtests.

### Foundation deployed and internal runtime validated

Foundation bootstrap completed in the dedicated resource group. Verified all 11
live role assignments, including both AcrPull grants. Environment consumption
capacity is 500 cores; current usage before runtime is zero.

ACR build `ch1` succeeded with digest
`sha256:3a19e65166d0e6dc65de8bb414aefe5317d365520553df8b885aa5a6a94c7719`.
Image execution `ch3` verified nonroot UID 10001, native Speech SDK 1.48.2
initialization, FFmpeg/ffprobe, application-resolved Noto font and FastAPI health.
An earlier smoke used the task runner's relative working directory and was
corrected to the application's absolute font path; no image workaround was needed.

Runtime ARM validation succeeded at 2026-09-22T17:37:30Z, correlation
`3d3cdb5a-56ce-414a-b454-e53f84bae0c5`. Resource-level what-if reports only four
new runtime resources (app, auth configuration and two jobs); foundation remains
unchanged. Validation used explicitly nonsecret placeholder credentials and does
not prove OAuth login. **Validation scope now includes internal runtime deployment;
public ingress remains gated on live authentication and acceptance checks.**

New cloud tests: 74 passed, including full worker execution, committed-result
recovery without repeat paid calls, unknown paid outcomes and heartbeat renewal.
After restoring byte-identical upstream test fixtures, CLI tests (106), subtitle/
video tests (59), and settings transfer tests (19) pass. The initial full run was
77% covered but failed because sparse checkout omitted fixtures; its failures are
not a successful regression result. A fresh full run is in progress.

### Policy-driven private-network correction

The completed full Windows/Python 3.11 regression now passes: **1,382 passed,
19 environment-dependent skips, 10,616 subtests, 80% coverage**. The additional
real Azure SDK-constructor regression brings targeted cloud tests to 75 passing.
The deployed image was updated to
`sha256:e07742e5a1ca03eab08b8dd81cf698570c8ab796190829a4463b51febf992b50`.

Live worker validation exposed `StorageAccount_PublicNetwork_Modify`, which
rewrote public network access to Disabled during the original account creation.
This is an organization policy, not missing RBAC. No policy exemption will be
created. Shared AI resources remain unchanged, and the application is still
internal-only. No worker paid model call has occurred at this stage.

The corrected design retains Storage public-network access Disabled and adds a
dedicated VNet, isolated ACA infrastructure subnet, separate private-endpoint
subnet, and private endpoints plus private DNS for Blob, Queue and Table. SDKs
keep their normal account FQDNs. A new VNet-integrated Consumption environment
and new app/job names avoid mutating immutable environment networking. Existing
internal-only application resources remain until replacement acceptance.

Microsoft.Network is registered; eastus2 usage is 0/1,000 VNets and 0/65,536
private endpoints. The three endpoints add ongoing network charges even while
apps/jobs scale to zero. No NAT gateway, VM, GPU, or new model deployment is
planned. The temporary operator Blob Reader grant was removed; private data-plane
acceptance will execute inside the ACA network, not from the operator's internet
connection.

**The revised network is not yet validated or deployed.** Status has returned to
Ready for Validation; earlier successful ARM checks do not cover this revision.

### Private-network validation receipt

The revised bootstrap is now validated (not yet deployed at this checkpoint):
83 offline checks, compiled subnet/PE/DNS contract assertions, and live ARM
validation succeeded at 2026-09-22T18:38:42Z, correlation
`d2b961ff-ae6f-4b7b-83f5-c5646bd9edd7`. Full-payload what-if adds the VNet,
three private endpoints/DNS associations and a Consumption environment with
the `-vnet` suffix. It preserves the original application/environment and data.
The intended Storage modification is defaultAction Allow to Deny, with public
networking remaining Disabled. Other property deltas are provider defaults or
unresolved references to unchanged identities; no resource deletion or shared
AI configuration change is proposed.

Validation scope permits this private-network bootstrap. New runtime outputs,
actual private DNS/data access, authenticated publication and media acceptance
are still separate deployment gates.

### Private runtime and real media acceptance

Private bootstrap and runtime are now deployed. Runtime ARM validation succeeded
with correlation `28bbe494-d5ff-4981-a41f-590c41f69fe6`; what-if created only the
new app, its auth configuration and two jobs. Live network checks confirm
Storage Disabled/Deny/keyless, approved private endpoints and DNS links.

The actual worker MI resolves Blob/Queue/Table to `10.247.2.4`, `.5`, `.6` and
successfully performs Blob lease acquire/renew/release, Table ETag writes and
queue submission. KEDA independently consumed the queue. The web/API revision
was restarted after enqueue; all three original tasks completed.

| Acceptance | Task ID | Verified output |
|---|---|---|
| Foundry text | `86359249-0544-51ca-a3ba-82fee8571b35` | Real worker-identity text completion |
| Chinese uploaded material | `186fa782-2d04-50d1-9a34-20c7c36b0426` | 1080x1920, H.264/AAC, 6.40s, SRT, 14 Speech word boundaries |
| English Foundry image | `0075ee92-d1a1-549b-9373-eeba0f488574` | 1920x1080, H.264/AAC, 6.31s, SRT, 16 Speech word boundaries |

Both cloud videos were downloaded through authenticated administrative exec,
checksum-verified against immutable artifact indexes, and independently checked
with local ffprobe. No public Blob URL or SAS was created. The actual internal
API rejects missing credentials (401) and a disallowed user (403), and verifies
all returned media bytes. The one-time diagnostic web replica is temporarily
kept warm; min replicas must return to zero before final delivery.

Guarded authenticated publication may now proceed. Real browser login and
completion of injected recovery/duplicate checks remain outstanding.

### Completed authenticated acceptance

Published endpoint:
https://mpt-rlgz72uq-web-vnet.livelystone-f0c1d23a.eastus2.azurecontainerapps.io

The allowlisted user completed actual single-tenant Entra browser sign-in and
basic-profile consent. The Streamlit cloud workspace loaded successfully. A
browser-submitted, prewritten script task
`8fcc650f-6f46-4fcc-851a-45b2aea80274` completed after navigating away; reconnecting
showed the persisted successful result. No paid generation was used for this test.

Browser acceptance includes uninterrupted playback to the end of the 6.31-second
English video across the automatic status-refresh interval, actual audio playback,
and authenticated MP4/SRT downloads with matching artifact SHA-256 hashes.
The real video URL supports HTTP 206 with a correct 1,024-byte Range response.
That same URL, anonymous root requests, forged principal headers and invalid
bearer tokens all return 401 without a session. A second real Entra account was
not used; disallowed identity rejection was tested on the internal API, and the
live platform allowlist was verified separately.

Duplicate messages for all three paid test tasks were acknowledged with attempts
remaining one and unchanged immutable results. Injected queue-send failure was
repaired from pending_dispatch; an expired worker lease recovered successfully.
A deliberately pre-created paid fence produced needs_review without another
provider POST. The queue returned to zero messages.

The deployed application is restored to min replicas zero, max one. The diagnostic
browser was disconnected. Three Storage private endpoints, Private DNS, ACR,
Storage and logging still incur ongoing charges; scale-to-zero is not free teardown.
The single PoC OAuth client secret expires **2026-09-29T17:39:23Z** and must be
rotated before then for continued sign-in. No automatic resource deletion is
configured. Shared AI model deployments, network settings and keyless policies
were not changed.

Cloud artifacts are private in `stmptrlgz72uqyetnu`, container `tasks`, under each
task ID's checkpoint paths and immutable `result.json` index. Download them through
Tasks & downloads. Verified local evidence copies are retained outside the repository.
