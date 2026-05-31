# Eval-Harness Host — Operator Setup Reference

**Scope:** the AWS EC2 box that drives the Off-Spark benchmark sweep. It issues
OpenAI-compatible API calls to rented Runcrate GPU endpoints and frontier APIs
(Bedrock + Gemini), runs the four upstream eval graders, and stages results in
S3. **Inference does not happen on this host.**

For the architectural why-and-how, see `docs/research/ec2-harness-design.md`.
This file is the day-to-day reference: how to bring it up, where things live,
which env vars are honored.

---

## TL;DR

```bash
# Bring up a campaign-scoped harness
./scripts/harness-up.sh \
  --campaign nemotron-screening-2026-05 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --connect

# Inside the box, install the four upstream harnesses (idempotent; safe to re-run)
# install-harness.sh ships embedded in user-data (cloud-init write_files
# encoding:gz+b64) and lands at /opt/benchmarks/scripts/install-harness.sh
# on first boot; no scp / git clone needed (<CAMPAIGN>).
ssh ubuntu@<instance-id>     # SSH-over-SSM ProxyCommand auto-configured by harness-up.sh
sudo /opt/benchmarks/scripts/install-harness.sh

# Tear down at end of campaign (results survive in S3)
./scripts/harness-down.sh --campaign nemotron-screening-2026-05

# Or stop instead of terminate (state survives EBS, restart with harness-up.sh + same name)
./scripts/harness-up.sh --campaign nemotron-screening-2026-05 --persistent ...
./scripts/harness-down.sh --campaign nemotron-screening-2026-05    # stops; doesn't terminate
```

---

## Instance specs

| Property | Value |
|---|---|
| AMI | Ubuntu 24.04 LTS (Noble), latest official Canonical AMI resolved at launch time |
| Default instance type | `m6i.xlarge` (4 vCPU / 16 GB RAM) — suitable for Pool B + frontier baselines |
| Pool A escalation type | `m6i.2xlarge` (8 vCPU / 32 GB RAM) — bump via `--instance-type`. See [Pool A escalation](#pool-a-escalation) for the full sizing recipe (instance + `/data` EBS). |
| Root volume | 100 GB gp3, encrypted, `DeleteOnTermination=true` |
| Optional `/data` EBS | gp3 with 6000 IOPS provisioned, attached at `/dev/sdb` when `--data-volume-size N` (N>0) is passed; cloud-init formats ext4, mounts at `/data`, and points Docker's `data-root` at `/data/docker` BEFORE `apt install docker.io` runs |
| IMDS | v2 required (token-only) |
| Region | `us-east-1` (forced — SSM Parameter Store, Bedrock, S3 results bucket all colocated here) |
| Account | `<AWS_ACCOUNT_ID>` (IPNTS production AWS) |
| Subnet | Private 1 (`<SUBNET_ID>`, 10.0.10.0/24, AZ-a) of IPNTS VPC `<VPC_ID>` |
| Public IP | None — SSH-over-SSM only |
| SG ingress | None |
| SG egress | All — direct NAT egress to public internet (no corporate proxy) |

The subnet placement gives the host **both** IPNTS-internal reachability over
the operator's Client VPN connection AND direct NAT egress for Hugging Face,
GitHub, Bedrock, Runcrate API calls, **and outbound SSH (:22) to rental GPU
boxes**. Egress is unfiltered (no `.ralph-allowlist`-style proxy in front).

> **Why private-1, not corporate**: An earlier iteration (pre-v7x) placed the
> harness in `corporate-A`. That subnet's NACL (`<NACL_ID>`) is a
> strict outbound allow-list scoped to internal corporate services
> (HTTP/HTTPS/SMTP/UDP/ephemeral) — outbound :22 was blocked, so SSH from the
> harness to rental boxes timed out. The `private-*` subnets carry the same
> NAT-egress / Client-VPN reachability but with an unrestricted-egress NACL
> (`<NACL_ID>`, rule 100 = `allow ALL 0.0.0.0/0`), which is the
> right tier for an outbound-heavy agent runner.

## SSH access

SSH happens over AWS Systems Manager Session Manager. The SSM agent on the
instance is the inbound proxy; the security group has zero ingress rules.

`harness-up.sh` auto-appends a `Host i-*` block to your `~/.ssh/config` on
first run — after that, plain `ssh ubuntu@<instance-id>` Just Works (the
ProxyCommand transparently tunnels through SSM). Multiple terminal sessions
work fine; tmux from anywhere.

The harness's user is **`ubuntu`** (Canonical Ubuntu AMI default).

> Note: This is **different** from the SSH user on rented Runcrate GPU
> instances. Runcrate's Ubuntu image authorizes only `root` even though the
> base OS is Ubuntu. When the harness's per-model run scripts SSH into a
> rented GPU, they use `root@<runcrate-ip>`, not `ubuntu@`. The
> `gpu-rental` private key (in SSM at `/sandbox/ssh-keys/gpu-rental/private`,
> mounted into `~ubuntu/.ssh/gpu-rental` at cloud-init) is the same key used
> for both ends.

### Register an operator key (multi-operator harness access)

`harness-up.sh --ssh-key` only authorizes the operator who launches the
harness. To let multiple operators / sandbox agents access every future
harness without manually appending pubkeys after each boot, store an
authorized_keys-style blob in SSM at
`/sandbox/ssh-keys/operators/authorized_keys` (plain `String`, NOT
SecureString — public keys aren't secret). Cloud-init's step 5.5 reads it
and appends each valid `ssh-…`/`ecdsa-…` line to `~ubuntu/.ssh/authorized_keys`
alongside the launcher's `--ssh-key`. Blank lines and `#` comments are tolerated.

Register your pubkey once:

```bash
# Pull the current value (empty on first run), append your pubkey, push back
aws ssm get-parameter --name /sandbox/ssh-keys/operators/authorized_keys \
  --query Parameter.Value --output text 2>/dev/null > /tmp/auth_keys || : > /tmp/auth_keys
printf '%s\n' "$(cat ~/.ssh/id_ed25519.pub)" >> /tmp/auth_keys
aws ssm put-parameter --name /sandbox/ssh-keys/operators/authorized_keys \
  --type String --overwrite --value file:///tmp/auth_keys
```

The parameter is read at every cloud-init run (not cached on the AMI), so
the next harness launch picks up new keys without code changes.

Soft-fail: if the parameter is missing or empty, cloud-init logs a warning
and proceeds with only the launcher's `--ssh-key`. The launcher's key plus
SSM Session Manager still give at least one path in; no boot is blocked.

## Filesystem layout

```
/opt/harnesses/
├── lm-evaluation-harness/         # EleutherAI lm-eval — Pool B graders
│   └── .venv/                     # per-harness venv
├── cybergym/                      # Pool A: CyberGym (sunblaze-ucb fork)
├── sec-bench/                     # Pool A: SEC-bench
└── cve-bench/                     # Pool A: CVE-Bench (UIUC Kang lab)

/var/lib/harness/
├── bootstrap.ok                   # cloud-init success sentinel; contains timestamp + AMI ID
├── bootstrap.err                  # cloud-init failure sentinel; contains failing-step name
└── install.ok                     # install-harness.sh success sentinel

/var/log/harness-bootstrap.log     # full cloud-init stdout+stderr; tailable via SSM

~ubuntu/.ssh/gpu-rental            # private key for SSHing into rented Runcrate GPUs
                                   # mode 0600 owner ubuntu; pulled from SSM at cloud-init
```

For Pool B-only campaigns, Docker images pull into the default
`/var/lib/docker/` on the root EBS. For Pool A campaigns, see
[Pool A escalation](#pool-a-escalation) — Docker's `data-root` moves to
`/data/docker` on a dedicated 1 TB gp3 volume so the 130 GB CyberGym binary
data + 150 GB SEC-bench images + 100 GB CVE-Bench images don't crowd root.

## Hostname convention

The harness's hostname is set from the `Campaign` tag at cloud-init via
`hostnamectl set-hostname`. Mirrors Runcrate's auto-hostname-from-instance-name
behavior on the rented-GPU side, so logs aggregated from both ends use one
naming scheme.

The convention for instance / Campaign names: short, descriptive, includes the
sweep phase. Examples:

| Use | Name |
|---|---|
| Harness for full Abbreviated sweep | `abbr-sweep-2026-05` |
| Harness for one-model Standard run | `qwen3.6-27b-fp8-std-001` |
| Rented Runcrate GPU for an Abbreviated run | `qwen3.6-27b-fp8-abbr-001` |

The same value is used as: `--campaign` flag, EC2 instance Name tag, EC2
`Campaign` tag, hostname on the box, and S3 prefix
(`s3://<RESULTS_BUCKET>/<campaign>/`).

## IAM and credentials

The harness runs under instance profile `harness-driver-role`. Inline policy
grants exactly:

| Action | Resource |
|---|---|
| `ssm:GetParameter`, `ssm:GetParameters` | `arn:aws:ssm:us-east-1:<AWS_ACCOUNT_ID>:parameter/sandbox/*` |
| `s3:GetObject`, `PutObject`, `DeleteObject` | `arn:aws:s3:::<RESULTS_BUCKET>/*` |
| `s3:ListBucket`, `GetBucketLocation` | `arn:aws:s3:::<RESULTS_BUCKET>` |
| `bedrock:InvokeModel`, `InvokeModelWithResponseStream` | `arn:aws:bedrock:*:<AWS_ACCOUNT_ID>:inference-profile/us.anthropic.claude-opus-4-*` and `arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-*` (Opus 4.x is invoked via cross-region inference profile, not bare model ID; the policy grants both the profile and the foundation models it routes to) |
| `kms:Decrypt` | `*` (scoped via condition `kms:ViaService = ssm.us-east-1.amazonaws.com`) |
| SSM Session Manager channels | `*` (standard SSM agent permissions) |
| `ec2:DescribeTags` | `*` (used at cloud-init to read Campaign tag for hostname) |

No long-lived AWS access keys exist on the box. No managed policies are
attached — any future policy expansion edits the inline policy and re-applies
via `harness-up.sh` (idempotent).

## Env vars set by cloud-init

| Var | Source | Purpose |
|---|---|---|
| `HARNESS_CAMPAIGN` | tag `Campaign` | propagated to per-run scripts as a stable identifier |
| `AWS_DEFAULT_REGION` | `us-east-1` | enforces region for awscli without `--region` flags |
| `RESULTS_BUCKET` | `<RESULTS_BUCKET>` | per-run scripts call `aws s3 cp` against this |
| `RESULTS_PREFIX` | `s3://<RESULTS_BUCKET>/$HARNESS_CAMPAIGN/` | per-run scripts upload here |
| `BEDROCK_OPUS_MODEL` | `us.anthropic.claude-opus-4-7` | frontier-baseline runs (cross-region inference profile, not bare model ID) |

These are written into `/etc/profile.d/harness.sh` and exported into root and
ubuntu shells.

API tokens (Hugging Face `HF_TOKEN`, Anthropic API for Gemini-comparison work,
etc.) live in SSM under `/sandbox/api-keys/*` and are pulled on-demand by
per-run scripts via `aws ssm get-parameter --with-decryption`. Never written
to the filesystem in plaintext.

## Bedrock self-test (cloud-init gate)

cloud-init runs a single Bedrock `InvokeModel` call before writing the
`bootstrap.ok` sentinel:

```bash
aws bedrock-runtime invoke-model \
  --region us-east-1 \
  --model-id us.anthropic.claude-opus-4-7 \
  --content-type application/json \
  --body '{"messages":[{"role":"user","content":"ok"}],"max_tokens":1,"anthropic_version":"bedrock-2023-05-31"}' \
  /tmp/bedrock-selftest.out
```

If the call fails (most common cause: account-level Bedrock model access not
enabled for Opus 4.7 in us-east-1), `bootstrap.err` records "bedrock-selftest"
as the failing step and `harness-up.sh` aborts after polling timeout. Fix
Bedrock access in the AWS console under **Bedrock → Model access** and
re-run `harness-up.sh` (the next launch is a fresh instance — no need to
clean up).

## Pool A escalation

Pool A (CyberGym + SEC-bench + CVE-Bench) is a different beast from Pool B.
Per the [`benchmarks-2on` sizing memo](#) the install + steady-state footprint
is roughly:

| Component | Disk | Notes |
|---|---|---|
| CyberGym binary data (`.7z` + extract) | ~260 GB peak during install, ~130 GB steady | HuggingFace `.7z` archive; extraction needs full archive present, so peak ≈ 2× |
| SEC-bench Docker images (50-instance subset) | ~150 GB | Per-instance footprint is real — these images do NOT share base layers (unlike SWE-bench) |
| CVE-Bench Docker images (40 CVEs) | ~100 GB | Standard Docker layer sharing applies |
| OS + harness venvs + Pool B leftovers | ~45 GB | Already on root |
| Headroom | ~75 GB buffer | Avoid filling root mid-run |

That puts Pool A install at ~510 GB total, of which ~380 GB is content that
should NOT live on the root volume. The standard recipe is **m6i.2xlarge +
1 TB gp3 `/data`**:

```bash
harness-up.sh \
  --campaign pool-a-2026-05 \
  --instance-type m6i.2xlarge \
  --data-volume-size 1000
```

CPU/RAM rationale: 3 concurrent Pool A tasks need ~15-18 GB host RAM
(1-2 GB Python controller + 2-4 GB sanitizer container per task). The default
`m6i.xlarge` (4 vCPU / 16 GB) is marginal at 3-concurrent; `m6i.2xlarge`
(8 vCPU / 32 GB) is comfortable. Step up to `m6i.4xlarge` only if running 6+
concurrent tasks.

What `--data-volume-size 1000` does:

1. `harness-up.sh` adds a second `BlockDeviceMapping` for `/dev/sdb` (1 TB gp3
   with 6000 IOPS provisioned — keeps `docker pull` of large image sets from
   being IOPS-bottlenecked; the gp3 free baseline is 3000 IOPS).
2. Cloud-init Step 0 (runs BEFORE the apt install of `docker.io`):
   - Detects `/dev/nvme1n1` (Nitro presents the second device under that name).
   - Formats ext4 if not already formatted (idempotent across `--persistent`
     stop/start cycles).
   - Mounts at `/data`, writes a UUID-based `/etc/fstab` line for reboot
     persistence (`nofail` so a missing volume doesn't block boot).
   - Mkdirs `/data/docker` and writes `/etc/docker/daemon.json` with
     `data-root=/data/docker`.
3. The subsequent `apt install docker.io` step picks up `daemon.json` on
   the daemon's first start. `docker info` will show `Docker Root Dir:
   /data/docker`.

When `--data-volume-size 0` (default), Step 0 is a no-op and Docker uses
its default `/var/lib/docker` on the root EBS — Pool B campaigns are
unchanged.

Cost: m6i.2xlarge bump is +$0.096/hr (~+$70/mo if running 24/7). 1 TB gp3
storage is ~+$80/mo plus minor IOPS surcharge for the provisioned 6000 IOPS
above the free baseline. With `--persistent` + `harness-down.sh`, only the
storage cost persists between campaigns (~$80/mo for the volume).

> Pool A install steps (CyberGym binary download, SEC-bench/CVE-Bench
> image prepull) are tracked in `benchmarks-2on.2` and `benchmarks-2on.3`
> and gate behind a `--pool-a` flag in `install-harness.sh`. Until those
> ship, `install-harness.sh` clones the upstream repos but does not
> populate `/data` with binary data or images — operator runs the
> per-bench data-pulls by hand.

## Lifecycle modes

Default: **terminate at down**. EBS volume is deleted; results survive in S3.
Re-launch starts a fresh box and re-bootstraps cloud-init.

`--persistent`: `harness-down.sh` calls `stop-instances` instead of
`terminate-instances`. EBS persists at ~$0.08/GB/month while stopped (~$8/mo
for the 100 GB root). Subsequent `harness-up.sh --campaign <same-name>`
detects the stopped instance and starts it instead of provisioning new.

Persistent mode shines when running back-to-back model triages because
cloud-init bootstrap (~5 min) and `install-harness.sh` (~20 min for upstream
clone + venv setup + first docker pull) don't repeat. Drop persistence at
end of campaign (`--final-sync` to a local directory, then plain
`harness-down.sh` without `--persistent` flips it back to terminate mode).

## What this host does NOT do

- **Does not run inference.** Inference happens on Runcrate-rented GPUs
  (B300/RTXPro6000/GH200/H100) or via Bedrock/Gemini APIs.
- **Does not bake AMIs.** All state is reproduced via cloud-init + idempotent
  `install-harness.sh`. AMI lock is for the Canonical Ubuntu base only.
- **Does not provision rented GPUs.** Per-run scripts call the Runcrate
  API directly. The harness's IAM role does not include any Runcrate-related
  access.
- **Does not run ralph-loop / Claude Code agent loops.** That's
  ralph-in-a-box's domain. Patterns from there were lifted into the
  harness scripts (SSH-over-SSM, persistent flag, tag-based discovery), but
  this box is a benchmarking driver, not an agent runner.

## Provisioning a rental vLLM endpoint

The harness drives rented GPU boxes (Runcrate / B300 / RTXPro6000 / GH200) via
`scripts/rental-vllm-up.sh`. The operator first stands up a rental box through
the provider's runbook (see `bd memory runcrate-sku-mapping-for-benchmarks-rlp-4-11`
for SKU/region picks), then hands the hostname or IP to this script:

```bash
# On the harness EC2 (as ubuntu):
cp /opt/benchmarks/scripts/rental-specs/qwen3.6-27b-fp8.yaml /tmp/spec.yaml
sed -i 's/REPLACE-ME-WITH-ACTUAL-RENTAL-HOSTNAME-OR-IP/<your-rental-host-or-ip>/' /tmp/spec.yaml
/opt/benchmarks/scripts/rental-vllm-up.sh /tmp/spec.yaml
```

What the script does:

1. SSH-preflights the rental (using `~/.ssh/gpu-rental` and the `rental-gpu-*`
   block in `~/.ssh/config`)
2. Installs `uv` on the rental if missing, then `uv pip install vllm>=0.20`
   into `/opt/vllm-venv`
3. Mints a per-rental Bearer key (or reuses one from a prior up)
4. Launches `vllm serve <model-id>` in a tmux session bound to `127.0.0.1:8000`
   on the rental, logs to `/var/log/vllm.log`
5. Opens an `ssh -fN -L <local_port>:127.0.0.1:8000` tunnel from the harness
6. Polls `/v1/models` until vLLM reports the model as served (timeout 25 min
   by default — first cold load + torch.compile can take ~10 min)
7. Writes `/var/lib/harness/rentals/<rental-host>.json` with the endpoint,
   API key, tmux session, and SSH tunnel pid
8. Emits a one-line JSON on stdout: `{"endpoint":"http://127.0.0.1:8000/v1",
   "api_key":"sk-rental-...","model_id":"...","rental_host":"..."}`

The endpoint URL is `http://127.0.0.1:<local_port>/v1` (a localhost SSH tunnel,
not the rental's public IP). This satisfies the Pool runners' `--vllm-url`
TLS-or-localhost guard. When `<CAMPAIGN>` ships nginx+TLS in front of vLLM, this
will become `https://<rental>/v1` with the same Bearer key.

Re-running the same spec is a no-op: each stage probes its own preconditions
and skips if already satisfied. Use `--force-restart` to kill and relaunch the
tmux session (e.g. after changing `vllm_args` in the spec).

Tear-down (preserves cached weights + venv on the rental for the next launch):

```bash
/opt/benchmarks/scripts/rental-vllm-down.sh <rental-host>
# or
/opt/benchmarks/scripts/rental-vllm-down.sh --spec /tmp/spec.yaml
```

The down script does NOT terminate the rental box itself — that lives with
the operator (Runcrate dashboard / API). It only kills the SSH tunnel, kills
the vLLM tmux session, and removes the local state file.

Out of scope for `rental-vllm-up.sh`: TLS, nginx, public exposure (those are
`<CAMPAIGN>`); rental-box provisioning (operator's runbook); orchestrating an
end-to-end screening run across all benches (that's `<CAMPAIGN>`'s
`run-screening.sh`).

## Recovery commands

### Find orphaned instances across all campaigns

If state files are lost or instances were launched manually, use `--find-orphans` to
discover all eval-harness instances in the account:

```bash
./scripts/harness-down.sh --find-orphans
# Prints a table: InstanceId | Campaign | State | LaunchTime
# No campaign argument required.
```

To clean up a discovered instance:

```bash
./scripts/harness-down.sh --instance-id i-0abc123def456 [--final-sync ./results/]
```

### Common operator commands

```bash
# Find existing harness instances
aws ec2 describe-instances --region us-east-1 \
  --filters Name=tag:Project,Values=benchmarks Name=tag:Component,Values=eval-harness \
            'Name=instance-state-name,Values=running,stopped,pending' \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Campaign`].Value|[0],State.Name]' \
  --output table

# Tail cloud-init log on a running harness
aws ssm send-command --region us-east-1 \
  --instance-ids <id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -200 /var/log/harness-bootstrap.log"]' \
  --query 'Command.CommandId' --output text
# (then poll get-command-invocation with that command-id)

# List all results from a campaign
aws s3 ls s3://<RESULTS_BUCKET>/<campaign>/ --recursive

# Pull all results locally at end of campaign
aws s3 sync s3://<RESULTS_BUCKET>/<campaign>/ ./results/<campaign>/

# Register your pubkey on the multi-operator authorized_keys list (bd <ISSUE>).
# Cloud-init step 5.5 reads this on every harness boot and appends each
# line to /home/ubuntu/.ssh/authorized_keys. Idempotent — runs are no-op
# if your key is already present.
aws ssm get-parameter --region us-east-1 \
  --name /sandbox/ssh-keys/operators/authorized_keys \
  --query Parameter.Value --output text > /tmp/auth_keys 2>/dev/null || : > /tmp/auth_keys
grep -qxF "$(cat ~/.ssh/id_ed25519.pub)" /tmp/auth_keys \
  || printf '%s\n' "$(cat ~/.ssh/id_ed25519.pub)" >> /tmp/auth_keys
aws ssm put-parameter --region us-east-1 \
  --name /sandbox/ssh-keys/operators/authorized_keys \
  --type String --overwrite --value file:///tmp/auth_keys
rm /tmp/auth_keys
```

## Running frontier baselines from a Proxmox sandbox

This describes the operator flow for `benchmarks-<CAMPAIGN>` (Pool B) and
`benchmarks-<CAMPAIGN>` (Pool A). All runner scripts live under
`scripts/runners/` on the harness EC2 host at
`/opt/benchmarks/scripts/runners/`. They run **on the harness EC2** (under
`harness-driver-role`), not in the sandbox. The sandbox is the
orchestrator/monitor only.

### Prerequisites

1. Harness EC2 is up and `bootstrap.ok` is present:
   ```bash
   ./scripts/harness-up.sh --campaign frontier-pool-b-2026-05 --ssh-key ~/.ssh/id_ed25519.pub
   ```
2. Harnesses installed on the EC2 box:
   ```bash
   ssh ubuntu@<instance-id>
   sudo /opt/benchmarks/scripts/install-harness.sh
   ```
3. Gemini API key stored in SSM (one-time, from the operator workstation):
   ```bash
   aws ssm put-parameter \
     --region us-east-1 \
     --name /sandbox/api-keys/gemini \
     --value "<key>" \
     --type SecureString \
     --overwrite
   ```

### Split-responsibility launch (laptop + sandbox)

Until `<CAMPAIGN>` lands (one-time IAM-init / day-to-day split), the laptop is the
only place with `iptadmin` AWS credentials and is therefore the only place that
can run `harness-up.sh` / `harness-down.sh`. The actual long-running benches
run on the EC2 box and are kicked off from the proxmox sandbox (or anywhere
else with SSH-over-SSM access). tmux on the box keeps the runner alive
through SSH disconnect / Claude Code session exit / sandbox restart.

**1. Laptop — bring up the harness** (~5 min, ~$0.05):

```bash
./scripts/harness-up.sh \
  --campaign frontier-poolb-2026-05 \
  --profile iptadmin
```

This creates / reuses the IAM role + S3 bucket (idempotent). After it returns,
the harness EC2 is fully bootstrapped and reachable via SSH-over-SSM. The
laptop is no longer in the loop.

**2. Sandbox (or anywhere) — kick off Pool B in detached tmux**:

```bash
./scripts/runners/launch-pool-b-tmux.sh \
  --campaign frontier-poolb-2026-05 --target opus47

./scripts/runners/launch-pool-b-tmux.sh \
  --campaign frontier-poolb-2026-05 --target gemini
```

Both runs are independent; you can fire them in parallel on the same harness.
The wrapper:
- Resolves the instance ID from `/tmp/harness-instance-<campaign>.id` (or
  accepts `--instance-id` explicitly)
- Verifies no stale tmux session of the same name exists
- Starts `sudo tmux new-session -d -s pool-b-<target> "/opt/benchmarks/scripts/runners/run-pool-b.sh ..."`
- Prints the re-attach + tail commands for that specific session

**3. Anywhere — check progress**:

```bash
./scripts/runners/check-pool-b-status.sh \
  --campaign frontier-poolb-2026-05 --target opus47
```

Reports: tmux-session presence, last 10 runner-log lines, results already
synced to S3, any error sentinels. Safe to invoke at any cadence; doesn't
disturb the running tmux session.

**4. Laptop — tear down when both targets complete** (~$0.05):

```bash
./scripts/harness-down.sh \
  --campaign frontier-poolb-2026-05 \
  --final-sync ./results/ \
  --profile iptadmin
```

Final sync pulls per-bench JSON to `./results/frontier-poolb-2026-05/`.

### Direct invocation (debug / one-off only)

For interactive debugging where you want to watch lm-eval's live output:

```bash
ssh ubuntu@<instance-id> \
  sudo /opt/benchmarks/scripts/runners/run-pool-b.sh \
    --campaign frontier-poolb-2026-05 \
    --target opus47
```

**This dies on SSH disconnect.** Don't use it for real campaign runs.

### Monitoring Pool A (CyberGym)

Pool A runs are unattended but write progress heartbeats to S3 every 60 seconds.
Poll from the sandbox:

```bash
# List heartbeat objects (one per 60s tick)
aws s3 ls s3://<RESULTS_BUCKET>/frontier-pool-b-2026-05/_progress/ \
  --recursive

# Fetch the latest heartbeat
aws s3 cp \
  "$(aws s3 ls s3://<RESULTS_BUCKET>/frontier-pool-b-2026-05/_progress/ \
    --recursive | sort | tail -1 | awk '{print "s3://<RESULTS_BUCKET>/" $4}')" -
```

The spend watchdog polls Bedrock cost delta every 60 seconds. If the delta
since runner start exceeds `--spend-cap-usd` (default $300), the runner
receives SIGTERM, syncs partial results to S3, and exits with code 2.
The watchdog is **conservative**: CE propagation delay (~4-8 hours) means
early polls return $0 delta; that is normal and does not trigger the cap.
If Cost Explorer is unavailable, the run continues (no false aborts).

### Tailing logs live

```bash
# Tail runner log on the harness EC2 via SSM run-command
aws ssm send-command \
  --region us-east-1 \
  --instance-ids <instance-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -200 /var/log/harness-runner.log"]' \
  --query 'Command.CommandId' --output text
# Then poll: aws ssm get-command-invocation --command-id <id> --instance-id <id>

# Or open an SSM session and tail directly
aws ssm start-session --target <instance-id>
# Inside session:
tail -f /var/log/harness-runner.log
```

### Pulling results at the end

```bash
./scripts/harness-down.sh \
  --campaign frontier-pool-b-2026-05 \
  --final-sync ./results/frontier-pool-b-2026-05/
```

### Idempotency

All runner scripts are idempotent: re-running with the same `--campaign` and
`--target` skips benches that already have a `results.json`. Pass `--force` to
overwrite existing results.

### Error artifacts

If a runner encounters an unhandled error, a structured bug report is written to
`/var/lib/harness/runner-errors/<runner>-<timestamp>.err` on the EC2 box. Retrieve
via SSM session or `aws ssm send-command`.

---

## Cross-references

- `docs/research/ec2-harness-design.md` — full architectural rationale and the
  closure block for VPC discovery (`benchmarks-<CAMPAIGN>`)
- `docs/eval-battery.md` — pool definitions, run profiles, frontier reference
  numbers, contamination caveats
- `bd memory: vpc-topology-for-benchmarks-eval-harness-placement-closed` —
  canonical VPC/subnet IDs (sourced from `~/internal-network-stuff/aws-baseline-iac/`)
- `bd memory: ralph-in-a-box-patterns-reused-for-benchmarks` — which patterns
  were lifted from where
- `bd memory: runcrate-rtx-pro-6000-sm120-nvfp4-spike-pass-2026-05-07` —
  validated rented-GPU side details (vLLM 0.20.1, VLLM_CUTLASS backend,
  SSH-as-root convention)
