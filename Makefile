# Everything runs from YOUR machine (or the Poridhi lab VM). The servers are reached over SSH
# with the generated ssh/config, so you never have to copy files around by hand.
#
# Typical order:
#   make keys infra env image k3s nginx check
#   make deploy STEP=1-baseline && make experiment NAME=e1-baseline
#   ... see README for E2-E4 ...
#   make destroy

DOCKERHUB_USER ?= CHANGE_ME
IMAGE          ?= $(DOCKERHUB_USER)/whoami-api:v1
STEP           ?= 1-baseline
NAME           ?= run
DURATION       ?= 60
EVENT          ?= none
EVENT_AT       ?= 20
REPLICAS       ?= 2

SSH := ssh -F ssh/config
SCP := scp -F ssh/config
-include .env.mk

ifeq ($(EVENT),stop-worker2)
  EVENT_ARGS = --event-at $(EVENT_AT) --event-cmd "aws ec2 stop-instances --force --instance-ids $(WORKER2_ID) > /dev/null"
else
  EVENT_ARGS =
endif

.PHONY: help keys infra env image k3s nodes deploy scale pods rebalance nginx check ports \
        load experiment timeline plot start-worker2 clean-k8s destroy

help:
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 16

# ---------- AWS ----------
keys: ## create the two EC2 key pairs (files go to infra/, never commit them)
	aws ec2 create-key-pair --key-name nginx --query 'KeyMaterial' --output text > infra/nginx.pem
	aws ec2 create-key-pair --key-name k3sCluster --query 'KeyMaterial' --output text > infra/k3sCluster.pem
	chmod 400 infra/nginx.pem infra/k3sCluster.pem

infra: ## create VPC + 4 EC2 instances with Pulumi
	cd infra && npm install && (pulumi stack select dev 2>/dev/null || pulumi stack init dev) \
	  && pulumi config set aws:region ap-southeast-1 && pulumi up

env: ## read Pulumi outputs into .env.mk and ssh/config (re-run after a restart: public IPs change)
	./scripts/env.sh

# ---------- app image ----------
image: ## build the Spring Boot image for amd64 and push it to Docker Hub
	@test "$(DOCKERHUB_USER)" != "CHANGE_ME" || (echo "Run: make image DOCKERHUB_USER=<your-docker-hub-name>"; exit 1)
	docker build --platform linux/amd64 -t $(IMAGE) app
	docker push $(IMAGE)

# ---------- K3s ----------
k3s: ## install K3s on master, join both workers, label them
	$(SSH) master 'sudo hostnamectl set-hostname master && curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.31.4+k3s1 sh -s - --write-kubeconfig-mode 644'
	TOKEN=$$($(SSH) master sudo cat /var/lib/rancher/k3s/server/node-token); \
	for w in worker1 worker2; do \
	  $(SSH) $$w "sudo hostnamectl set-hostname $$w && curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.31.4+k3s1 K3S_URL=https://$(MASTER_PRIV):6443 K3S_TOKEN=$$TOKEN sh -"; \
	done
	$(SSH) master 'until kubectl get node worker1 worker2 >/dev/null 2>&1; do sleep 3; done; kubectl wait --for=condition=Ready node/worker1 node/worker2 --timeout=300s'
	$(SSH) master 'kubectl label nodes worker1 worker2 role=worker-node --overwrite'
	$(SCP) scripts/watch-cluster.sh master:~/
	$(MAKE) nodes

nodes: ## kubectl get nodes -o wide
	$(SSH) master 'kubectl get nodes -o wide'

# ---------- workload ----------
deploy: ## apply k8s/$(STEP) (deployment with your image + service) and wait
	@test "$(DOCKERHUB_USER)" != "CHANGE_ME" || (echo "Run: make deploy STEP=$(STEP) DOCKERHUB_USER=<your-docker-hub-name>"; exit 1)
	sed 's#IMAGE_PLACEHOLDER#$(IMAGE)#' k8s/$(STEP)/deployment.yaml | $(SSH) master 'kubectl apply -f -'
	$(SSH) master 'kubectl apply -f -' < k8s/$(STEP)/service.yaml
	$(SSH) master 'kubectl rollout status deployment/whoami --timeout=300s'
	$(MAKE) pods

scale: ## kubectl scale deployment/whoami --replicas=$(REPLICAS)
	$(SSH) master 'kubectl scale deployment/whoami --replicas=$(REPLICAS) && kubectl rollout status deployment/whoami'
	$(MAKE) pods

pods: ## which pod runs on which node
	$(SSH) master 'kubectl get pods -l app=whoami -o wide'

rebalance: ## after a worker comes back, restart pods so they spread over both workers again
	$(SSH) master 'kubectl rollout restart deployment/whoami && kubectl rollout status deployment/whoami'
	$(MAKE) pods

# ---------- Nginx L4 load balancer ----------
nginx: ## render nginx.conf with the workers' private IPs, build and run it on the nginx instance
	sed -e 's/WORKER1_IP/$(WORKER1_PRIV)/' -e 's/WORKER2_IP/$(WORKER2_PRIV)/' nginx/nginx.conf.template > nginx/nginx.conf
	$(SSH) nginx 'command -v docker >/dev/null || (curl -fsSL https://get.docker.com | sudo sh)'
	$(SSH) nginx 'mkdir -p ~/nginx'
	$(SCP) nginx/nginx.conf nginx/Dockerfile nginx:~/nginx/
	$(SSH) nginx 'cd ~/nginx && sudo docker build -q -t custom-nginx . && (sudo docker rm -f my_nginx >/dev/null 2>&1 || true) \
	  && sudo docker run -d --restart unless-stopped -p 80:80 --name my_nginx custom-nginx'

check: ## 6 requests through Nginx: which node answered each one?
	@for i in 1 2 3 4 5 6; do curl -s http://$(NGINX_IP)/api/whoami; echo; done

ports: ## the lab's telnet checks, with nc: you -> nginx:80, nginx -> workers:30001
	nc -zv -w 3 $(NGINX_IP) 80
	$(SSH) nginx 'nc -zv -w 3 $(WORKER1_PRIV) 30001; nc -zv -w 3 $(WORKER2_PRIV) 30001'

# ---------- experiments ----------
load: ## load test only (no event, no cluster log)
	python3 scripts/loadtest.py --url http://$(NGINX_IP) --duration $(DURATION) --name $(NAME)

experiment: ## NAME=... DURATION=... EVENT=none|stop-worker2 : load test + cluster log + timeline
	@mkdir -p results
	$(SSH) master 'kubectl get nodes; echo; kubectl get pods -l app=whoami -o wide' > results/$(NAME)-before.txt
	@cat results/$(NAME)-before.txt
	$(SSH) master 'bash ~/watch-cluster.sh $(DURATION)' > results/$(NAME)-cluster.log & \
	python3 scripts/loadtest.py --url http://$(NGINX_IP) --duration $(DURATION) --name $(NAME) $(EVENT_ARGS) \
	  | tee results/$(NAME).txt; \
	wait
	python3 scripts/timeline.py $(NAME) | tee results/$(NAME)-timeline.txt

timeline: ## re-print the timeline of a finished run: make timeline NAME=e3-node-down
	python3 scripts/timeline.py $(NAME)

plot: ## chart of E3 vs E4 into screenshots/node-failure.png (needs matplotlib)
	python3 scripts/plot.py e3-node-down e4-resilient-node-down -o screenshots/node-failure.png

start-worker2: ## start worker2 again, refresh IPs, wait until the node is Ready
	aws ec2 start-instances --instance-ids $(WORKER2_ID) > /dev/null
	aws ec2 wait instance-running --instance-ids $(WORKER2_ID)
	./scripts/env.sh
	$(SSH) master 'kubectl wait --for=condition=Ready node/worker2 --timeout=300s'
	$(MAKE) nodes

# ---------- cleanup ----------
clean-k8s: ## delete the app from the cluster
	$(SSH) master 'kubectl delete deployment/whoami service/whoami --ignore-not-found'

destroy: ## DELETE all AWS resources (do this when you are done!)
	cd infra && pulumi destroy
