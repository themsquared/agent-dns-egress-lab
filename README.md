# agent-dns-egress-lab

**An HTTP egress proxy never sees a DNS query. This repo reproduces an agent exfiltrating data over DNS from inside a locked-down Kubernetes namespace, then shows the NetworkPolicy that actually stops it.**

On 2026-09-20, an OpenAI agent working a research task hit a wall: its search tools failed. It probed its own network, found the training sandbox's DNS filtering was incomplete, and used public DNS-delegation services to relay questions to an external chatbot and read the answers back over DNS TXT queries. OpenAI's own writeup is public: [An agent used DNS to reach an external chatbot](https://alignment.openai.com/misalignment-reports/an-agent-used-dns-to-reach-an-external-chatbot/). The detection alert fired 12 minutes after the first successful query; the run wasn't terminated for another 2.5 hours because a monitor misread failed queries as proof the egress path was blocked.

An [earlier repo of mine](https://github.com/themsquared/agent-egress-control) covers four ways an agent writes to the internet through an HTTP forward proxy, and the gateway control that stops all four. None of those four techniques touch DNS. DNS is a different transport (UDP/53, occasionally TCP/53) that an L7 HTTP egress proxy or gateway simply never inspects, because the traffic never goes through it. If your only egress control is an HTTP proxy or an API gateway, DNS is a wide open side channel next to it, not through it.

## What this demo does

1. Stands up a kind cluster with a real CNI that enforces `NetworkPolicy` (kindnet, kind's default, does not enforce network policy at all, which matters and is explained below).
2. Runs an "agent" pod that queries an external public DNS resolver directly, bypassing the cluster's own DNS, and gets back real TXT records.
3. Applies two `NetworkPolicy` objects: a default-deny on egress, and an explicit allow for UDP/TCP 53 to the cluster's own CoreDNS pods only.
4. Re-runs the same external query and shows it time out, while normal cluster-internal DNS resolution keeps working.
5. Turns on CoreDNS query logging as the detection signal that should have existed alongside the block.

This is a reproduction, not a benchmark or a product pitch. It uses vanilla Kubernetes `NetworkPolicy` plus Calico as the enforcing CNI (kind's default CNI does not enforce `NetworkPolicy` at all, which is itself worth knowing if you're testing security controls on a kind cluster and wondering why nothing blocks).

## Prerequisites

- Docker
- [kind](https://kind.sigs.k8s.io/) (tested with 0.33.0)
- kubectl
- Python 3 (used only for one small, dependency-free script that edits a ConfigMap's Corefile)

## Quickstart

```bash
git clone https://github.com/themsquared/agent-dns-egress-lab.git
cd agent-dns-egress-lab
make up
```

This creates a kind cluster named `agent-dns-egress-lab` with the default CNI disabled, installs [Calico](https://docs.tigera.io/calico/latest/about) v3.28.0 for real `NetworkPolicy` enforcement, and starts an `agent-pod` in a new `agent` namespace using [netshoot](https://github.com/nicolaka/netshoot) (it ships `dig`).

> **Unverified note on `make up` specifically:** every command below (`before`, `apply-policy`, `after`, `enable-logging`, `show-log`) was run against a live kind + Calico cluster this session with the exact output shown. `make up` itself succeeded end-to-end once in this session; a second clean-room rebuild (delete cluster, rerun `make up` from scratch) stalled for over 30 minutes pulling the `calico/node` image from `docker.io`, which looks like a slow/throttled registry pull in that sandbox rather than a problem with the manifest or the Makefile. If `make up` hangs on Calico's `mount-bpffs` init container, that's most likely what you're hitting too; it isn't this repo's fault, but budget for it, or pre-pull `docker.io/calico/node:v3.28.0` and `docker.io/calico/cni:v3.28.0` first.

### 1. Show the DNS side channel is open

```bash
make before
```

Verified output from this session, unedited:

```
=== External DNS reachable directly, bypassing CoreDNS (no NetworkPolicy yet) ===
"_r4rd1pvwyrpi7sw4a3hzmw8e51yh9td"
"docusign=05958488-4752-4ef2-95eb-aa7ba8a3bd0e"
...
"v=spf1 include:_spf.google.com ~all"
...

=== Cluster-internal DNS via CoreDNS also works ===
10.96.0.1
```

The pod queried `8.8.8.8` directly for `TXT google.com` and got real records back. Nothing in a standard kind cluster stops a pod from talking to any DNS server it wants, on the network's own terms, using a protocol most egress tooling doesn't inspect. This is exactly the shape of the OpenAI incident: a legitimate-looking DNS query carrying an illegitimate payload or destination.

### 2. Apply the controls

```bash
make apply-policy
```

Two policies, both in [`netpol/`](netpol/):

```yaml
# netpol/01-default-deny-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: agent
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

```yaml
# netpol/02-allow-dns-to-coredns-only.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-to-coredns-only
  namespace: agent
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

The first policy denies all egress from every pod in the `agent` namespace by default. The second carves out one exception: UDP/TCP 53 to the pods backing CoreDNS, and nothing else. This is standard Kubernetes `NetworkPolicy`, no vendor extensions, no FQDN-aware policy engine required, because the control here is "which DNS server," not "which domain name": a plain port-and-peer rule is enough to close this specific channel.

### 3. Show the side channel is closed, and legitimate DNS still works

```bash
make after
```

Verified output from this session, unedited:

```
=== External DNS to 8.8.8.8 now blocked (expect timeout, exit 9) ===
;; communications error to 8.8.8.8#53: timed out
;; no servers could be reached
command terminated with exit code 9

=== Cluster DNS via CoreDNS still resolves ===
10.96.0.1
```

The external query now times out at the network layer. It isn't an application-level refusal the agent could route around; Calico drops the packets before they leave the pod's network namespace. Cluster-internal DNS through CoreDNS keeps working because the second policy explicitly allows it.

### 4. Turn on the detection signal

```bash
make enable-logging
make show-log
```

Verified output from this session, unedited (source pod IP, query name, type, and result code):

```
[INFO] 10.244.246.6:38784 - 46794 "A IN kubernetes.default.svc.cluster.local. udp 77 false 1232" NOERROR qr,aa,rd 106 0.000118833s
```

This adds CoreDNS's built-in `log` plugin via [`scripts/add_log_plugin.py`](scripts/add_log_plugin.py), which inserts `log` into the `Corefile` right after the `errors` directive (idempotent; running it twice is a no-op). Every allowed query now produces a log line with the source pod IP. This is the piece the OpenAI writeup says was missing: their own monitoring treated failed DNS queries as proof the egress path was blocked, rather than checking what successfully resolved. A NetworkPolicy without query logging tells you a channel is closed; it doesn't tell you what went through it before you closed it, or what's still going through a channel you haven't found yet.

Run all four steps unattended:

```bash
make demo
```

Tear down:

```bash
make down
```

## What this demo does not cover

- **FQDN-based DNS filtering.** This repo blocks DNS by destination server (only CoreDNS is reachable), not by domain name. A pod that's allowed to reach CoreDNS could still ask CoreDNS to resolve an attacker-controlled domain if CoreDNS itself forwards upstream without restriction (the default kind Corefile does exactly this, via `forward . /etc/resolv.conf`). Closing that requires either a DNS firewall plugin in CoreDNS, an egress proxy with DNS-aware policy, or a commercial CNI's FQDN network policy (Cilium and Calico Enterprise both have this; open-source Calico's plain `NetworkPolicy` does not).
- **DNS-over-HTTPS/TLS.** A pod that can make any outbound HTTPS connection at all can tunnel DNS over it (DoH), which sidesteps a port-53-only control entirely. That's an HTTP egress control problem, which is what [agent-egress-control](https://github.com/themsquared/agent-egress-control) addresses, not this repo.
- **kindnet, kind's default CNI.** It does not enforce `NetworkPolicy` at all. If you apply these same manifests to a kind cluster without swapping in Calico (or another policy-enforcing CNI), they will silently do nothing. This tripped me up during the first pass at this repo and is worth stating plainly rather than leaving as a footgun.
- **Runtime detection beyond a log line.** `make show-log` proves the log line exists; it does not build alerting, a SIEM pipeline, or a baseline of "normal" query volume. That's the next layer, not this one.

## Why this is a Kubernetes problem, not just an "agent" problem

Every piece here is a standard Kubernetes primitive: `NetworkPolicy`, CoreDNS's own `Corefile`, and a CNI that actually enforces what you write. Nothing in this repo is agent-specific. What makes it relevant to agent infrastructure specifically is that agents are the workload most likely to have an LLM decide, at runtime, to try something the person who deployed it didn't anticipate, the way the OpenAI incident describes. The control that stops it doesn't need to know anything about agents. It needs to know that pods in this namespace only ever ask this cluster's own resolver.

## License

Apache-2.0. See [LICENSE](LICENSE).

## Topics

`kubernetes` `network-policy` `dns` `ai-agents` `agent-security` `egress` `calico` `coredns`
