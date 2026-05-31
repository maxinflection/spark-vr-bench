# B200 Rental Provider Comparison

Comparison of the four candidate B200 rental providers in `benchmarks-<CAMPAIGN>`,
gathered from public docs and pricing pages on **2026-05-06**. All prices
are USD per GPU-hour on-demand unless noted. Cite-back URLs at the end of
each section.

The campaign needs:

- B200 on-demand availability *now* (no procurement cycle)
- Bring-your-own-container so we can run our own vLLM serve
- Public IPv4 + SSH so a harness host (Dreadnode-managed or <HARNESS_HOST>)
  can hit `:8080` on the rented instance
- Credit-card / minimal-friction signup
- Enough NVMe scratch for ~150–300 GB of weights per model

---

## Crusoe Cloud

1. **B200 availability** — listed on the pricing page as *"NVIDIA B200
   180 GB HGX"* with **"Contact sales"** for both on-demand and spot
   rates ([crusoe.ai/cloud/pricing][crusoe-pricing]). On-demand, spot, and
   reserved tiers all exist conceptually, but no public self-service B200
   booking — every B200 customer goes through a sales gate. A separate
   "Contact sales / NVIDIA B200" landing page exists at
   [crusoe.ai/contact-sales/nvidia-b200][crusoe-b200-sales] which
   confirms the gating.
2. **Hourly pricing** — public sources disagree: aggregator sites quote
   anywhere from "$2–3/hr" ([eesel review][eesel-crusoe]) to **$5.87/hr**
   ([Awesome Agents March 2026 comparison][awesomeagents]). Without sales
   contact we can't confirm the rate that would actually apply to a small
   short-term rental. Reservation tier is the deepest discount per their
   own copy: *"Reserved capacity is a custom agreement where you commit
   to a specific resource volume for a defined period, resulting in our
   deepest possible discounts and guaranteed resource availability."*
3. **Docker support** — general infrastructure docs reference Docker
   container support ([docs.crusoecloud.com][crusoe-docs]); root + SSH
   on bare-VM-style instances is the standard path. BYO container
   plausible.
4. **Signup friction** — account creation is self-service via web signup
   ([Creating an account][crusoe-signup]); billing requires a *valid,
   non-prepaid credit card* ([Enabling billing][crusoe-billing]). **But**
   B200 access in particular routes through Contact sales, so even a
   billed account doesn't get instant B200 instances without a sales
   touch. No public free credits offered.
5. **Network shape** — public IPv4, customer-controlled firewall via
   their VPC product. No public DDoS-proxy or rate-limit notes that
   would hamper sustained agentic eval traffic.
6. **Disk + model weight prep** — not detailed publicly for B200 SKU
   without sales engagement. HGX B200 instances generally ship with
   substantial NVMe scratch on-host; exact size needs sales confirmation.
   Snapshot/image support exists in the broader Crusoe Cloud product.
7. **Known gotchas / community signal** — *"high technical barrier
   requiring extensive engineering teams… long time-to-value for most
   teams"* ([eesel review][eesel-crusoe]). Strength is sustained-large
   reservations on stranded-energy datacenters; weakness for our case is
   exactly the sales-gate friction that makes a $50 spike test
   impractical.

[crusoe-pricing]: https://www.crusoe.ai/cloud/pricing
[crusoe-b200-sales]: https://www.crusoe.ai/contact-sales/nvidia-b200
[crusoe-docs]: https://docs.crusoecloud.com/
[crusoe-signup]: https://docs.crusoecloud.com/quickstart/creating-an-account/index.html
[crusoe-billing]: https://docs.crusoecloud.com/quickstart/enabling-billing/index.html
[eesel-crusoe]: https://www.eesel.ai/blog/crusoe-ai-review
[awesomeagents]: https://awesomeagents.ai/pricing/open-source-hosting-costs/

---

## Nebius

1. **B200 availability** — **publicly self-service** as of 2026, no
   waitlist. *"NVIDIA HGX B200 instances are now publicly available as
   self-service AI clusters on Nebius AI Cloud, allowing anyone to access
   NVIDIA Blackwell with just a few clicks and a credit card"*
   ([Introducing self-service Blackwell][nebius-blackwell]). 1x, 2x, 8x
   configurations all available on-demand via console.
2. **Hourly pricing** — **$5.50/hr** on-demand for the HGX B200 SKU
   (20 vCPUs, 224 GB RAM) ([nebius.com/prices][nebius-prices]). Up to
   35% commitment discount for reserved capacity. Storage and egress
   billed separately per [docs.nebius.com pricing][nebius-compute-prices].
3. **Docker support** — **caveat.** Standard self-service GPU instances
   *run as Docker containers*; bare-metal / custom driver install is
   not available on the standard tier. Their Container Registry product
   ([nebius.com/services/container-registry][nebius-cr]) is the
   recommended path. For our case (run vLLM ourselves), this works
   cleanly *if* the standard tier exposes nvidia-smi and lets us run
   our own container — confirmed plausible but **needs verification on
   first launch**, since "containerized GPU instance" can mean
   "you bring a container we run for you" or "you SSH into a machine
   and run docker" — different developer-experience.
4. **Signup friction** — credit-card or bank-transfer; **$25 minimum
   first payment** ([nebius.com/prices][nebius-prices]). Instant access
   to NVIDIA Blackwell once credit card and payment are added; explicit
   *"no waitlists or minimum commitments"* ([self-service page][nebius-self-service]).
5. **Network shape** — public IPv4, security-group equivalent in their
   console. No public note of provider-side rate-limiting for sustained
   inference traffic.
6. **Disk + model weight prep** — separately billable block storage;
   default plan footprint not detailed without launching a console
   instance. Snapshot/image support exists in the broader product.
7. **Known gotchas / community signal**
   - **Capacity warnings** — *"There were concerns around capacity
     availability and unexpected disruptions in on-demand resources,
     which impacted production reliability at times"*
     ([Spheron Nebius alternatives][spheron-nebius]). Less of a concern
     for one-off Screening runs; bigger concern for multi-day jobs.
   - **Quota approval at scale** — *"Accessing H100 and H200 GPUs at
     scale requires going through an approval workflow"* ([same source][spheron-nebius]).
     Single-B200 is below the bar; clusters at TP=2 should be fine; full
     8x might hit the workflow.
   - **Trustpilot complaints** — at least one user-reported "hundreds
     of dollars charged with a hidden cancellation option"
     ([Trustpilot][nebius-trustpilot]). Anecdotal but worth noting for
     the auto-billing default.

[nebius-prices]: https://nebius.com/prices
[nebius-compute-prices]: https://docs.nebius.com/compute/resources/pricing
[nebius-blackwell]: https://nebius.com/blog/posts/introducing-self-service-nvidia-blackwell-gpus
[nebius-self-service]: https://nebius.com/self-service
[nebius-cr]: https://nebius.com/services/container-registry
[spheron-nebius]: https://www.spheron.network/blog/nebius-alternatives/
[nebius-trustpilot]: https://www.trustpilot.com/review/nebius.ai

---

## Lambda Labs

1. **B200 availability** — fully on-demand self-service. 1x, 2x, 4x, 8x
   B200 configurations all visible on the public pricing page
   ([lambda.ai/pricing][lambda-pricing]). 1-Click Cluster product for
   16/64/256+ GPU reservations exists for larger campaigns. No sales
   contact required for any standard tier.
2. **Hourly pricing** (as of 2026-05-06, via the live pricing page):
   - **1× B200:** $6.99/hr
   - **2× B200:** $6.89/hr/GPU
   - **4× B200:** $6.79/hr/GPU
   - **8× B200:** $6.69/hr/GPU
   - **1-Click Cluster reserved:** $9.86/hr (16 GPUs, 2 weeks–1 year);
     $9.36 (64 GPU); $8.87 (256+ GPU)
3. **Docker support** — yes, **Docker pre-installed** as part of the
   Lambda Stack image ([Lambda virtual environments and Docker
   containers][lambda-docker]). Standard root + SSH on Ubuntu instances.
   Cleanest BYO experience of the four.
4. **Signup friction** — credit-card-only (no debit cards
   per [community thread][lambda-debit]). No reported sales gate for
   on-demand B200. No public free credits.
5. **Network shape** — public IPv4 with their firewall product. Static
   IP retention available across instance restarts within the team
   account. Standard inference traffic supported, no DDoS-proxy gating
   surfaced in docs.
6. **Disk + model weight prep** — full HGX B200 instance ships with
   **~22 TiB SSD** ([lambda.ai/pricing][lambda-pricing]). Single-B200
   gets a pro-rated slice; specific size not on pricing page but easily
   sufficient for our 150–300 GB-per-model footprint without extra
   storage purchases.
7. **Known gotchas / community signal** — generally well-regarded for
   on-demand single-GPU rentals, especially in the Hacker News A100
   anecdote ([HN][hn-lambda]). Capacity has been bursty in past years
   (sometimes "out of stock") but the B200 fleet has been more
   reliably available through 2026.

[lambda-pricing]: https://lambda.ai/pricing
[lambda-docker]: https://docs.lambda.ai/software/virtual-environments-and-docker-containers/
[lambda-debit]: https://deeptalk.lambdalabs.com/t/how-to-add-billing-to-lambda-without-credit-card-i-have-debit-card/4174
[hn-lambda]: https://news.ycombinator.com/item?id=36027027

---

## Spheron Network

Added to the comparison after the initial four-provider research surfaced
their pricing as a citation source rather than a candidate provider.
Spheron is itself a GPU rental platform, not a pure aggregator — they
source hardware from a "certified data center network" of third-party
operators and resell with conventional fiat billing. **Not** a
crypto/decentralized-compute play despite the `.network` TLD; no token,
no community-supplied consumer hardware in the listed SKU.

1. **B200 availability** — *"limited availability with early access
   program"* per their [B200 rental page][spheron-b200]. Self-serve via
   `app.spheron.ai/login`; multi-GPU and large-cluster bookings route
   through Contact Sales (*"Spheron sources from its certified data
   center network, negotiates pricing, handles setup"*). Single-B200
   appears to be the bookable unit on the standard 8-GPU HGX node.
2. **Hourly pricing** — **$1.71/hr** on-demand for a single B200, per
   the dedicated B200 rental page — by a wide margin the cheapest
   on-demand rate in this comparison ([spheron-b200]). Per-minute
   billing, no contracts. Their own pricing-comparison blog quotes
   $6.02/hr on-demand and $2.12/hr spot for B200 SXM6 ([spheron-2026]) —
   inconsistent with the $1.71/hr rental-page rate, suggesting recent
   price drift, different SKUs across pages, or marketing-vs-platform
   discrepancy. Real rate to be verified at trial-spike time.
3. **Docker support** — explicitly yes. The B200 page itself walks
   through `ssh` + `docker run` of vLLM, with full root access assumed
   in the example. Cleanest BYO-vLLM DX of the providers, on par with
   Lambda.
4. **Signup friction** — self-serve via the platform login link
   referenced from the rental page. Credit-card requirements / KYC
   flow not specified on the page; assume conventional cloud signup
   until verified.
5. **Network shape** — not specified on the rental page (no info on
   public IPv4 / static IP / egress costs). Worth verifying at trial
   spike, especially the firewall-control story for exposing
   `:8080` to a remote eval harness.
6. **Disk + model weight prep** — **250 GB NVMe Gen5** included per
   8-GPU HGX B200 node. Adequate for one model's weights at a time
   (~150–300 GB per model), but tighter than Lambda's 22 TiB and
   Vultr's multi-TB NVMe. May need to swap weights between models
   rather than caching multiple. Verify at spike time.
7. **Spot interruption shape — disqualifies spot for Screening runs.**
   Their wording: *"can be preempted when dedicated demand rises."*
   No published eviction-warning window or interruption-rate SLA. A
   reclaim mid-Screening (24–40hr per model) invalidates the run.
   **Use on-demand only for campaign-critical work; spot is fine for
   one-off exploration where re-running is cheap.**
8. **Known gotchas / community signal** — limited third-party
   coverage; smaller community footprint than Lambda or Nebius. The
   "early access program" capacity gating is the biggest unknown:
   $1.71/hr is real *if* there's capacity at booking time, but if
   capacity is "Contact Sales for cluster" gated for anything beyond
   1× B200, the headline doesn't apply to our 2× B200 cluster runs.
   Brand newer to broad-market visibility; verify any operational
   claims at trial spike.

[spheron-b200]: https://www.spheron.network/gpu-rental/b200/
[spheron-2026]: https://www.spheron.network/blog/gpu-cloud-pricing-comparison-2026/

---

## Vultr (Verda Cloud GPU)

1. **B200 availability** — listed on the public Cloud GPU page with the
   B200 product subpage at
   [vultr.com/products/cloud-gpu/nvidia-b200/][vultr-b200] (page returned
   a 403 to scraping during research; product is live per search
   results). Configuration is **8× B200** as the default bare-metal SKU;
   smaller fractional bookings less common in their listing pattern but
   may be available via console.
2. **Hourly pricing** — **starting $2.890/GPU/hr** on-demand,
   **$2.990/GPU/hr** prepaid ([per Shadeform's Vultr comparison][shadeform-vultr]).
   This is **~50% lower** than the $5–7/hr range at Nebius/Lambda.
   Caveat: "starting from" pricing on Vultr historically requires
   prepaid contract terms — pure on-demand may differ. Sales-contact
   recommended for confirmation per ([Vultr's pricing summary][vultr-pricing]).
3. **Docker support** — Vultr Cloud GPU instances are bare-metal-style
   Linux servers; docker installs cleanly via apt. Root + SSH the
   default DX.
4. **Signup friction** — Vultr's standard signup is credit-card
   self-service ($1 minimum to verify), but **B200 specifically has been
   sales-contact-recommended per public copy**. Free $250 credit
   sometimes offered to new accounts via referral codes; no documented
   evergreen B200 trial credit.
5. **Network shape** — public IPv4, customer-managed firewall, static-IP
   reservation available. Vultr's networking is bare-metal-flavor
   without provider-side proxying that would interfere with sustained
   agent traffic.
6. **Disk + model weight prep** — published 8× B200 SKU ships with
   **2 × 1.92 TB NVMe** boot + **8 × 3.84 TB NVMe** scratch. Massive
   surplus for our needs. Snapshot/image creation supported across
   bare-metal product line.
7. **Known gotchas / community signal**
   - Limited public documentation surfacing in 2026 — most third-party
     comparison aggregators don't have Vultr B200 specs as
     comprehensively as Lambda/Nebius. Vultr Verda is a newer brand
     (relaunch / rename of their cloud GPU line) and the marketing
     surface is still catching up.
   - Headline price is the lowest of the four, but verify it applies
     to short-term on-demand (not a multi-month-prepaid teaser).

[vultr-b200]: https://www.vultr.com/products/cloud-gpu/nvidia-b200/
[shadeform-vultr]: https://www.shadeform.ai/clouds/vultr
[vultr-pricing]: https://www.vultr.com/pricing/

---

## Comparison table

| Provider | 1× B200 hourly (on-demand) | Signup | Docker / root | B200 availability | Biggest caveat |
|---|---|---|---|---|---|
| **Crusoe** | "Contact sales" — public sources show $2–6/hr range | Self-serve account, but B200 sales-gated | yes (general infra) | Sales touch required | Sales gate eliminates fast spike-test path |
| **Nebius** | **$5.50/hr** | Credit card + $25, instant | yes, but standard tier is *containerized GPU instance* (DX nuance) | Self-service, no waitlist | "Containerized GPU instance" model — verify BYO-container DX on first launch; capacity flakes reported |
| **Lambda** | **$6.99/hr** (1×); $6.69/hr (8×) | Credit card only, instant | yes, Docker pre-installed | Self-service, fully on-demand | Highest price; established but bursty capacity historically |
| **Spheron** | **$1.71/hr** (early-access program) | Self-serve platform login | yes, vLLM walkthrough on rental page | "Limited availability — early access" | Capacity gate is the load-bearing unknown; 250 GB NVMe is tighter than peers; spot disqualified for 30hr runs |
| **Vultr Verda** | **~$2.89/hr starting** (verify on-demand vs prepaid) | Credit card, but B200 has "contact sales" suggested in pricing copy | yes, bare-metal SSH default | Self-service in console (per search) | Headline price likely needs prepaid commit; less third-party documentation; newer brand |

---

## Recommendation

**Run trial spikes on Spheron + Lambda in parallel before committing.**
Spheron's $1.71/hr headline (vs Lambda's $6.99/hr) is too large a
delta to ignore on a multi-model sweep — *if* the early-access-program
capacity gate doesn't trip. Lambda is the operationally-simple
fallback if Spheron flakes.

### The cost case for Spheron-if-it-works

At ~30 hr/model × 8 model configurations:
- **Lambda single-B200**: ~$1700 across the sweep
- **Spheron single-B200**: ~$420 across the sweep
- **Delta**: ~$1300 saved if Spheron capacity holds

That's ~40% of the entire campaign's projected total. Worth ~$50 of
trial spike time to validate before committing.

### Spike-test acceptance criteria

For each provider trial, before signing the campaign over to it:

- Boot 1× B200 on-demand from the standard signup flow (no
  Contact-Sales path)
- Install vLLM, serve Qwen3.6-27B-FP8 (or any small model — the bench
  is the rental flow, not the model)
- Hit the OpenAI-compatible endpoint from a remote host
  (<HARNESS_HOST> or laptop) for a HumanEval+ subset
- Confirm: stable for ≥6hr without provider-side intervention,
  clean tear-down, billable hours match expectation, capacity
  available again on next spin-up (i.e., not "you got lucky once")
- Verify firewall / static-IP / network-shape story for exposing
  `:8080` to a remote eval harness

If both spikes pass, **Spheron primary, Lambda fallback** is the
defensible pick. If Spheron capacity flakes or DX surprises, Lambda
primary is the safe call — operational simplicity and known-quantity
DX are worth the ~$1300 in absolute terms on a ~$3000 campaign.

### Spot is disqualified for Screening runs

Spheron's spot rate ($2.12/hr per their pricing-comparison blog) and
any equivalent on Vultr/Lambda/Nebius are **off the table for
30-40 hr Screening runs**. A preemption mid-run invalidates the work
— every Pool A bench is multi-turn agentic loops with internal state
on the rented host, not checkpoint-resumable. Use on-demand only.
Spot is fine for one-shot exploration (Pool B function-level benches
re-run cheaply) but not the campaign critical path.

### Other providers

- **Nebius** — distant third. $5.50/hr is cheaper than Lambda but
  the *containerized GPU instance* DX caveat is real; verify
  separately if Spheron + Lambda both fall through. The "Contact us
  for the cluster" path is cleanly available for 2× B200 TP=2 cluster
  runs (`benchmarks-<CAMPAIGN>`, `.11`).
- **Crusoe** — disqualified by Contact-Sales gate on B200. Worth
  revisiting for sustained reservation work after this campaign.
- **Vultr Verda** — sparse third-party docs, B200 product copy
  inconsistent. Skip unless Spheron + Lambda + Nebius all fail. If
  Vultr's $2.89/hr applies to short-term on-demand without a
  prepaid commit (verify), it'd land between Spheron and Nebius on
  cost — but the documentation gap is a campaign-critical-window
  risk we shouldn't take without good reason.

### Concrete next step

Trial spikes on Spheron + Lambda, ~$25-50 each, ideally same day.
Outcome determines provider pick for `benchmarks-<CAMPAIGN>` through `.11`.
Tracked in our issue tracker — see the trial-spike task.

---

## Sources

- Provider pricing pages: [Crusoe][crusoe-pricing], [Nebius][nebius-prices], [Lambda][lambda-pricing], [Spheron B200][spheron-b200], [Vultr B200][vultr-b200]
- Comparison aggregators: [getdeploying.com B200][getdeploying-b200], [computeprices.com][computeprices]
- Crusoe docs: [account creation][crusoe-signup], [billing][crusoe-billing]
- Nebius announcement: [self-service Blackwell][nebius-blackwell]
- Lambda Docker docs: [virtual environments and containers][lambda-docker]
- Spheron pricing comparison blog: [GPU cloud pricing comparison 2026][spheron-2026]
- Vultr Verda: [Shadeform Vultr listing][shadeform-vultr]
- Community signal: [Spheron Nebius alternatives][spheron-nebius], [HN A100 thread][hn-lambda], [Trustpilot Nebius][nebius-trustpilot], [eesel Crusoe review][eesel-crusoe]

[getdeploying-b200]: https://getdeploying.com/gpus/nvidia-b200
[computeprices]: https://computeprices.com/gpus/b200
