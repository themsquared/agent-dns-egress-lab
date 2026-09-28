CLUSTER := agent-dns-egress-lab
CTX := kind-$(CLUSTER)
CALICO_MANIFEST := https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

.PHONY: up before apply-policy after enable-logging show-log demo down

up:
	kind create cluster --config kind-config.yaml
	kubectl --context $(CTX) apply -f $(CALICO_MANIFEST)
	kubectl --context $(CTX) -n kube-system rollout status daemonset/calico-node --timeout=180s
	kubectl --context $(CTX) wait --for=condition=Ready nodes --all --timeout=180s
	kubectl --context $(CTX) create namespace agent
	kubectl --context $(CTX) -n agent run agent-pod --image=nicolaka/netshoot --restart=Never --command -- sleep infinity
	kubectl --context $(CTX) -n agent wait --for=condition=Ready pod/agent-pod --timeout=120s

before:
	@echo "=== External DNS reachable directly, bypassing CoreDNS (no NetworkPolicy yet) ==="
	kubectl --context $(CTX) -n agent exec agent-pod -- dig +short +time=5 TXT google.com @8.8.8.8
	@echo
	@echo "=== Cluster-internal DNS via CoreDNS also works ==="
	kubectl --context $(CTX) -n agent exec agent-pod -- dig +short +time=5 kubernetes.default.svc.cluster.local @10.96.0.10

apply-policy:
	kubectl --context $(CTX) apply -f netpol/01-default-deny-egress.yaml
	kubectl --context $(CTX) apply -f netpol/02-allow-dns-to-coredns-only.yaml

after:
	@echo "=== External DNS to 8.8.8.8 now blocked (expect timeout, exit 9) ==="
	-kubectl --context $(CTX) -n agent exec agent-pod -- dig +short +time=5 +tries=1 TXT google.com @8.8.8.8
	@echo
	@echo "=== Cluster DNS via CoreDNS still resolves ==="
	kubectl --context $(CTX) -n agent exec agent-pod -- dig +short kubernetes.default.svc.cluster.local @10.96.0.10

enable-logging:
	kubectl --context $(CTX) -n kube-system get configmap coredns -o json > /tmp/coredns-cm.json
	python3 scripts/add_log_plugin.py /tmp/coredns-cm.json /tmp/coredns-cm-new.json
	kubectl --context $(CTX) apply -f /tmp/coredns-cm-new.json
	kubectl --context $(CTX) -n kube-system rollout restart deployment coredns
	kubectl --context $(CTX) -n kube-system rollout status deployment coredns --timeout=90s

show-log:
	kubectl --context $(CTX) -n agent exec agent-pod -- dig +short kubernetes.default.svc.cluster.local @10.96.0.10
	sleep 2
	kubectl --context $(CTX) -n kube-system logs -l k8s-app=kube-dns --tail=20 | grep -i "kubernetes.default"

demo: up before apply-policy after enable-logging show-log
	@echo "Demo complete."

down:
	kind delete cluster --name $(CLUSTER)
