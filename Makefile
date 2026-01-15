SHELL := /usr/bin/env bash

.PHONY: init apply destroy outputs kube smoke

init:
	cd infra/core && terraform init
	cd infra/addons && terraform init

apply:
	cd infra/core && terraform apply
	cd infra/addons && terraform apply

destroy:
	# Destroy addons first (k8s objects), then core (UpCloud)
	cd infra/addons && terraform destroy
	cd infra/core && terraform destroy

outputs:
	cd infra/core && terraform output

kube:
	@KCFG=$$(cd infra/core && terraform output -raw uks_kubeconfig_path); \
	echo "KUBECONFIG=$$KCFG"; \
	kubectl --kubeconfig "$$KCFG" get nodes -o wide

smoke:
	./smoke/smoke.sh
