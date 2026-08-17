# Eval-Harness Host Design — AWS EC2 Pivot

**Status:** §6 closed 2026-05-07; ready to implement
**Captured:** 2026-05-07
**Source bd issue:** `benchmarks-<CAMPAIGN>`
**Parent epic:** `benchmarks-rlp` (Off-Spark quality benchmark sweep on rented GPUs)

This document captures the redesign of the eval-harness host away from on-prem Proxmox. §6 networking questions were answered 2026-05-07 by reading `~/internal-network-stuff/aws-baseline-iac/` — see closure block at end of §6.

---

## 1. Why we pivoted off Proxmox

The original `benchmarks-<CAMPAIGN>` scope called for a persistent VM on `<PROXMOX_HOST>` with 16-32 vCPU and 64-128 GB RAM. That spec was wishful: `<PROXMOX_HOST>` is a NUC with 32 GB RAM total, ~485 GB disk, modest cores, and is already hosting other workloads (including the dev sandbox where this planning happened).

Two options to right-size on the NUC were considered and rejected:
- **Smaller VM (4 vCPU / 12 GB / 80 GB)** — fits, but tight; one Pool A docker target plus dataset shards in RAM is the limit.
- **Unprivileged LXC** — lighter, but Docker-in-LXC compat flags + kernel sharing add a foot-gun surface that doesn't pay back for an ephemeral driver host.

The host's actual job is small: it's a *driver* (issues OpenAI-compatible API calls, runs eval graders, manages docker containers for Pool A harnesses). Inference happens elsewhere — on rented B200 GPUs at Spheron / Lambda Cloud, or via Bedrock / Gemini APIs for frontier baselines. Persistence-across-rental-cycles was the original argument for on-prem; that turns out to be about *config reproducibility*, not host longevity. Cloud-init plus an idempotent install script gives the same reproducibility on any fresh box.

**Decision:** the harness lives on AWS EC2, on-demand, ephemeral per campaign. We're already paying for benchmarking; an extra ~$80-110 over a 2-week campaign is rounding error.

---

## 2. The new shape

- **Region:** `us-east-1` (matches existing SSM parameter store, low hop count to Bedrock).
- **Account:** `<AWS_ACCOUNT_ID>` (existing IPNTS AWS account).
- **Instance / Storage: size PER HARNESS, not one universal SKU** (bd benchmarks-b51, operator 2026-06-16). Different benches have different resource profiles; imposing one SKU on all of them either starves the heavy ones or overpays for the light ones. `harness-up.sh` *defaults* to the CyberGym hermetic-pool row below (the immediate powered-run host); lighter benches override `--instance-type` / `--data-volume-size`.

  | Harness (bench) | Profile | Instance | /data | Notes |
  |---|---|---|---|---|
  | **CyberGym hermetic pool** (Pool A, bd b51) | per concurrent task = C/C++ build + ASan + docker-in-docker OpenHands runtime + task-local grading server + grader containers — CPU/disk-heavy | **`c7i.24xlarge`** (96 vCPU / 192 GB) **ON-DEMAND** | **600 GB gp3** (≈ N×15 GB workspaces+overlay2 + base images; covers N≈24) | Powered run N≈16–24 against ONE Spark (H3: Spark serves that freely → harness CPU/disk is the ceiling). ON-DEMAND not spot: a ~1.5–3 h run would be reclaimed mid-run (per-task S3 resume mitigates but on-demand removes the risk). |
  | Pool A frontier API (opus47/gpt55, n=3) | sequential, light | `m6i.xlarge` (4 vCPU) | 0–100 GB | legacy baseline; one task at a time |
  | Pool B lm-eval | decode-bound, near-nil per-task disk | `m6i.xlarge` | 0 | scale is the endpoint, not the box |
  | 3xi.2 agentic coding | OpenHands + per-repo build images (different from CyberGym) | size on its own image/build profile | TBD | separate sizing exercise |

  Legacy baseline (pre-b51): `m6i.xlarge` (4 vCPU / 16 GB / $0.192/hr), `m6i.2xlarge` escalation for Pool A docker-concurrency / dataset-RAM pressure, 100 GB gp3 root. The CyberGym row supersedes this for the b51 powered run.
- **Storage:** 100 GB gp3 root volume + the bench-specific `/data` gp3 volume from the table above (docker data-root + workspaces live on `/data`; see `--data-volume-size`).
- **AMI:** Ubuntu 24.04 LTS official.
- **Identity:** instance profile (IAM role); no long-lived access keys on the box.
- **SSH access:** SSH-over-SSM via `aws ssm start-session` ProxyCommand — operator's pubkey injected into `~ubuntu/.ssh/authorized_keys` via cloud-init. **No SG ingress at all.** Pattern lifted from `ralph-in-a-box/docs/persistent-sandbox.md` (works because the SSM agent acts as the inbound proxy). Drops the original "harness keypair in SSM" idea — the `gpu-rental` SSH private key is still pulled into `~ubuntu/.ssh/gpu-rental` from SSM (operator-keypair use case is different from rented-GPU use case).
- **Networking:** **CLOSED 2026-05-07 — see §6.** Place in **corporate subnet A** (`<SUBNET_ID>`, 10.0.20.0/24) of the existing IPNTS VPC `<VPC_ID>`. Direct NAT egress to the public internet (no corporate proxy / no allowlist). Operator reaches the box from their workstation over Client VPN (full-tunnel, cert-based) via SSH-over-SSM.
- **Lifecycle:** `scripts/harness-up.sh` and `scripts/harness-down.sh` (bash + awscli — Terraform out of scope), idempotent, re-run per campaign. Default mode: terminate at end of campaign; results survive in S3. Optional `--persistent` flag for stop/start across campaign breaks (pattern lifted from ralph-in-a-box; saves ~$50/campaign of re-bootstrap time when running back-to-back model triages).
- **Results storage:** new S3 bucket `<RESULTS_BUCKET>` (us-east-1), versioning on, AES-256 SSE, block-public-access on, lifecycle rule expiring noncurrent versions at 30 days.

---

## 3. Cloud-architect design (v1)

Generated by the `cloud-infrastructure:cloud-architect` agent on 2026-05-07. Key elements:

### 3.1 IAM policy for the instance role (`harness-driver-role`)

Statements (least-privilege, scoped to existing SSM + new S3 bucket + Bedrock):

- `ssm:GetParameter`, `ssm:GetParameters` on `arn:aws:ssm:us-east-1:<AWS_ACCOUNT_ID>:parameter/sandbox/*`
- `s3:GetObject`, `PutObject`, `DeleteObject` on `arn:aws:s3:::<RESULTS_BUCKET>/*`
- `s3:ListBucket`, `GetBucketLocation` on `arn:aws:s3:::<RESULTS_BUCKET>`
- `bedrock:InvokeModel`, `InvokeModelWithResponseStream` on `arn:aws:bedrock:*:<AWS_ACCOUNT_ID>:inference-profile/us.anthropic.claude-opus-4-*` and `arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-*` — Opus 4.x is invoked via cross-region inference profile (e.g. `us.anthropic.claude-opus-4-7`); the bare foundation-model ID rejects on-demand throughput. Policy grants both the profile and the underlying foundation models.
- `kms:Decrypt` with `kms:ViaService = ssm.us-east-1.amazonaws.com` condition

**Bug to fix before implementation:** the v1 design used the SSM KMS *alias* ARN (`alias/aws/ssm`) as the `Resource`. The canonical pattern is `Resource: "*"` paired with the `kms:ViaService` condition. The wildcard is not actually broad — the condition restricts decryption to the SSM call path. Swap to that form.

### 3.2 Security group

v1 had ingress on TCP/22 from `${OPERATOR_IP}/32`. **Replaced with: no ingress rules at all.** SSH happens over SSM Session Manager (per §2 SSH access) — the SSM agent on the instance is the inbound proxy. Egress: all-outbound (NAT Gateway routes to the public internet for HF/GitHub/Bedrock/Spheron API; Route53 private zone resolves `*.internal.example` natively; nothing has to traverse the operator workstation).

### 3.3 Cloud-init user-data

Bootstrap-only (~50 lines): apt-install awscli + jq + curl + git + python3-venv + docker.io, add `ubuntu` to docker group, inject `--ssh-key` operator pubkey into `~ubuntu/.ssh/authorized_keys`, pull `gpu-rental` private key from SSM into `~ubuntu/.ssh/gpu-rental` (read by harness when SSHing into rented GPU instances), self-test by hitting Bedrock-Opus once and writing sentinel `/var/lib/harness/bootstrap.ok` on success. Cloud-init does NOT clone the benchmarks repo — it only mkdir's `/opt/harnesses` and `/var/lib/harness`. Eval harnesses and runner scripts are delivered separately after first boot (see §3.4 runner-script delivery).

### 3.4 Lifecycle scripts

#### Two-tier provisioning model (<CAMPAIGN>)

Provisioning is split into two distinct scripts with different permission requirements:

**`scripts/harness-bootstrap.sh`** (one-time, run once per AWS account under admin credentials, e.g. `--profile iptadmin`): creates all durable shared resources — IAM role `harness-driver-role` + inline policy `harness-driver-inline`, instance profile `harness-driver-profile`, security group `harness-eval-sg` (no ingress, all egress), and S3 bucket `<RESULTS_BUCKET>` (versioned/SSE/BPA/lifecycle). Also attaches a customer-managed policy named `harness-launcher-least-priv` (from `scripts/iam/harness-launcher-least-priv.json`) to the launcher principal (default: IAM user `benchmarks-sandbox-agent`). Fully idempotent. Key flags: `--grant-user NAME` (default `benchmarks-sandbox-agent`), `--no-grant`, `--profile`, `--region`, `--debug`.

**`scripts/harness-up.sh`** (day-to-day, slim, least-privilege): the routine campaign launcher. It does NOT create IAM resources, security groups, or the S3 bucket — it only describes the SG (to pass to `run-instances`) and assumes the role/profile/bucket already exist from the bootstrap. Runnable by a principal holding only `scripts/iam/harness-launcher-least-priv.json` — no `iam:Create*`, no `iam:GetRole`, no `ec2:CreateSecurityGroup` required. If the SG is missing it fails fast with a message directing the operator to run `scripts/harness-bootstrap.sh --profile iptadmin` first. If `run-instances` fails on IAM (PassRole / missing profile) it prints the same hint.

Flow: verify identity → describe harness SG (fail fast if missing) → resolve latest Ubuntu 24.04 AMI → `run-instances` with tag `Campaign=<name>` → wait for `instance-status-ok` → tail bootstrap log to sentinel → deliver runner scripts to box (see below) → auto-append SSH-over-SSM `ProxyCommand` to `~/.ssh/config` for `Host i-*` if not already present (pattern from ralph-in-a-box).

#### Permission tiers

| Tier | Script | Credentials needed | Frequency | What it creates |
|---|---|---|---|---|
| **Tier 1 — bootstrap** | `scripts/harness-bootstrap.sh` | Admin (`iptadmin`) | Once per account | IAM role + profile, SG, S3 bucket, attaches `harness-launcher-least-priv` policy to launcher user |
| **Tier 2 — day-to-day launch** | `scripts/harness-up.sh` | Least-priv (`benchmarks-sandbox-agent` with `harness-launcher-least-priv` policy at `scripts/iam/harness-launcher-least-priv.json`) | Every campaign | EC2 instance only |

The `harness-launcher-least-priv` policy grants: ec2 Describe* for launch resolution; `ec2:RunInstances` + `ec2:CreateTags` (tag-on-create only); `ec2:Start/Stop/TerminateInstances` scoped to instances tagged `Component=eval-harness`; `iam:PassRole` for `harness-driver-role` to ec2 only; `ssm:SendCommand/GetCommandInvocation/DescribeInstanceInformation/StartSession`; `s3:Get/Put/DeleteObject` + `ListBucket` on `<RESULTS_BUCKET>` (results, campaign registry, and the `_bootstrap/` scripts-staging prefix). It deliberately does NOT include `iam:Create*`, `ec2:CreateSecurityGroup`, or `s3:CreateBucket` — those are bootstrap-only.

#### Runner-script delivery (bd 9g4.5)

After `bootstrap.ok` is present, `harness-up.sh`'s `deliver_to_box()` pushes two payloads to the instance without any manual scp or rsync:

1. **`install-harness.sh` via SSM gz+b64**: the install script is gzip-compressed, base64-encoded, and sent as a single SSM RunShellScript command that writes it to `/opt/benchmarks/scripts/install-harness.sh`. (The script outgrew the 16 KB user-data cap and was moved to SSM delivery in <CAMPAIGN>; that mechanism is unchanged.)

2. **`scripts/runners` + `scripts/patches` via S3-staged tarball**: the combined `runners/` and `patches/` tree (~150 KB, too large for the ~64 KB SSM single-command cap) is tarred locally, uploaded by the launcher to `s3://<RESULTS_BUCKET>/_bootstrap/<campaign>/scripts-<sha256>.tgz` using the launcher's `s3:PutObject`, then a single SSM command on the instance pulls the tarball using the instance role's `s3:GetObject`, sha256-verifies it, and extracts to `/opt/benchmarks/scripts/`. The sha256 check is mandatory — delivery fails rather than installing a corrupt payload.

Net result: a freshly launched box has `install-harness.sh`, all `runners/`, and all `patches/` under `/opt/benchmarks/scripts/` before `harness-up.sh` returns. The operator can `ssh` in and immediately run `sudo /opt/benchmarks/scripts/install-harness.sh` then the relevant runner — zero manual file copying.

`scripts/harness-down.sh`: locate by tag → optional final `s3 sync` of results → `terminate-instances` (default) OR `stop-instances` (if `--persistent` was used at launch) → wait → leave IAM role / bucket / SSM params for next campaign → confirm. (SG is a durable bootstrap resource and is not removed by harness-down.)

Sister script `scripts/install-harness.sh` (run post-SSH on the box, idempotent): clone the four upstream Pool A/B harness repos under `/opt/harnesses/`, install Python deps in a per-harness venv, pull one Pool A docker image as a smoke target. Cloning happens against `<INTERNAL_GIT_HOST>` natively (Route53 private zone resolves from inside the VPC; HTTPS over the corporate-tier route table).

### 3.5 Cost ballpark (per 2-week campaign, single instance)

| Line | Estimate |
|---|---:|
| m6i.xlarge on-demand | ~$65 |
| EBS gp3 100 GB | ~$4 |
| S3 50 GB Standard + ops | <$1 |
| Internet egress (campaign-dependent; Pool A pulls CVE PoCs etc.) | $10-30 |
| **Total infra** | **$80-110** |

Bedrock InvokeModel token spend is separate (<CAMPAIGN> budget).

### 3.6 Key risks captured (full list in v1 doc)

- SG drift to `0.0.0.0/0` on port 22 — `harness-bootstrap.sh` must reconcile rules, not append; `harness-up.sh` only describes the SG, it does not modify it
- IAM scope drift (don't attach managed policies; inline only)
- EBS snapshot sprawl — design forbids snapshots; if added later, lifecycle to 7 days
- Stopped-not-terminated trap — terminate always
- Docker-in-host disk pressure — watch `df -h`; bump root to 200 GB if >70%

---

## 4. Review of v1 design

Bugs flagged after review (all resolved by the current §2/§3 spec):

1. **KMS Resource ARN** — alias ARN may not resolve correctly for `kms:Decrypt`; swap to `Resource: "*"` + `kms:ViaService` condition. Mechanical fix.
2. **Key rotation inconsistency** — moot under SSH-over-SSM: there is no harness keypair to rotate. The injected operator pubkey is provided per-launch by the caller (`--ssh-key`); rotation is the operator's concern.
3. **Install-script bootstrap path** — `git clone https://<INTERNAL_GIT_HOST>/...` works natively from corporate subnet (Route53 private zone resolves; HTTPS over NAT egress on internal-routed paths). Drop the S3 staging branch.
4. **Egress cost estimate** — v1 said $5-20/wk; Pool A campaigns realistically hit $10-30/wk because docker container payloads (CVE PoCs, exploits, target binaries) pull from public internet. Budget conservatively.

**§6 design call-out — RESOLVED:** SSM Session Manager wins decisively. The IPNTS VPC has both internal reachability (Client VPN clients on `internal.example` private DNS) and direct NAT egress, but SSM-SM eliminates the SG ingress surface entirely without giving anything up. Pattern is already proven in ralph-in-a-box.

---

## 5. Artifacts already created (durable, survive sandbox shutdown)

- `/sandbox/ssh-keys/gpu-rental/public` (SSM, String) — ed25519 SSH public key for rented GPU access; uploaded to Spheron + Lambda dashboards.
- `/sandbox/ssh-keys/gpu-rental/private` (SSM, SecureString, default `aws/ssm` KMS) — matching private key. Fingerprint: `SHA256:juosUI78RiuyHcoPTc5aQgIemVVjUaYvAXv8lj0Iyvk`.
- `/sandbox/api-keys/lambda-cloud` (SSM, SecureString) — Lambda Cloud REST API token. Scope: instance lifecycle.
- `bd remember` entries pointing at all of the above (`gpu-rental-ssh-key-ssm-location`, `lambda-cloud-api-key-ssm-location`, `spheron-api-key-sales-gated`, `lambda-b200-capacity-shortage-2026-05-07`, `sandbox-launcher-allowlist-refresh-quirk`, `operator-email-correct`).

The `harness` keypair has *not* been generated yet — that happens during first run of `scripts/harness-up.sh`.

---

## 6. Networking discovery — RESOLVED 2026-05-07

Source: read of `~/internal-network-stuff/aws-baseline-iac/` (modules/vpc/variables.tf, modules/vpn/main.tf, modules/dns/main.tf, ARCHITECTURE.md). No `aws ec2 describe-*` calls were needed — the canonical IDs and topology are tracked in code in that sibling repo.

| Question | Answer |
|---|---|
| VPC ID | `<VPC_ID>` (10.0.0.0/16, single VPC strategy, us-east-1) |
| Subnet posture | Both. Public A/B (10.0.0.0/24, 10.0.1.0/24) + Corporate A/B (10.0.20.0/24, 10.0.21.0/24) + Database A/B (10.0.30.0/24, 10.0.31.0/24). Plus a "private" tier used for VPN endpoint attachment. |
| Connectivity model | **AWS Client VPN** (cert-based mutual TLS, both UDP and TCP endpoints). Operator workstations connect TO the VPC. **Not** site-to-site or peered — the VPC is the IPNTS internal-network root. |
| DNS | Route53 private hosted zone `internal.example` is associated with the VPC and resolves natively from any subnet. `<INTERNAL_GIT_HOST>`, `<BEDROCK_PROXY_HOST>`, etc. work without `/etc/hosts` entries. |
| Egress | Direct via NAT Gateway from corporate subnets (route table `<ROUTE_TABLE_ID>` for corporate A). **No corporate proxy.** No allowlist needed. |

**Implications for v1+review design:**

- Subnet choice: corporate A (`<SUBNET_ID>`). Has internal reachability for operator-over-VPN AND direct NAT egress for Hugging Face / GitHub / Bedrock / Spheron API.
- SG: no ingress rules (SSH-over-SSM); all egress.
- IAM: no IPNTS-VPN or proxy-related permissions needed.
- Cost: §3.5 estimates stand.
- The `.ralph-allowlist` story does **not** apply to the harness — that's a Squid-proxy artifact for the local Proxmox sandbox path. The harness has open egress.

**Closes `benchmarks-<CAMPAIGN>`.**

Implementation gate: §3.1 (KMS Resource ARN fix) is a pre-flight; harness-up.sh writes the IAM policy, no separate ticket.

---

## 7. Related context (not the focus of this doc)

The rental-provider spike (`benchmarks-3ru`) settled on Spheron-only as of 2026-05-07:

- **Lambda Cloud — out.** No B200 capacity at signup; H200 fallback doesn't help us because 4 of the 8 in-scope models are NVFP4-quantized and the SM100 native NVFP4 path is B200-only (H200 forces FP8 fallback, which changes the quality measurement). Lambda is not a viable campaign target without B200 capacity returning, so the "Lambda primary, eat the premium" branch of the 3ru decision matrix is closed.
- **Spheron — primary.** Accept the Contact-Sales API gate as known friction; dashboard launches are self-serve and the cost delta vs Lambda (~$1300 over the campaign) covers an extra ~10 hours of manual orchestration over 8 model configs. Sales-engagement email for the API key still queued (file under "would speed up the campaign," not "blocker").
- **Fallback if Spheron stability fails the spike:** Nebius or Vultr Verda. Not Lambda.

Decision matrix in `benchmarks-3ru` simplifies to "Spheron passes spike → run sweep on Spheron; Spheron fails spike → escalate to Nebius spike."
