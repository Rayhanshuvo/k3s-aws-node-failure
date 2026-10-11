# What happens when a Kubernetes node dies on AWS, measured

**In plain words:** my service runs on two servers behind a load balancer. I switched one server off in the middle of heavy traffic and counted how many users got an error, for how long, and why. Then I changed the setup until switching a server off cost almost nothing.

> Status: infrastructure and tooling ready, experiments not run yet. Numbers below are filled in after each run.

| Setup | Failed requests when a worker node died | Error window |
|---|---|---|
| Lab default (`externalTrafficPolicy: Cluster`, 2 replicas) | _TBD_ | _TBD_ |
| Resilient (`Local` + 4 spread replicas + 30 s eviction) | _TBD_ | _TBD_ |

**Stack:** AWS EC2 · Pulumi · K3s (1 master, 2 workers) · Nginx Layer 4 load balancer · Java 21 / Spring Boot 3 · Python load tester

Follows [zero-downtime-k8s](https://github.com/Rayhanshuvo/zero-downtime-k8s), which measured planned changes (rollouts, rollbacks, a deleted pod) on a single node. This project measures the unplanned one: a whole server disappearing.

---

## Architecture

```
                 you / load tester
                        |
                        v  :80
            +-----------------------+
            |  nginx  (EC2 t2.micro)|   Layer 4: forwards TCP, does not read HTTP
            +-----------------------+
               |                 |      private IPs, :30001 (NodePort)
               v                 v
     +----------------+   +----------------+        +----------------+
     | worker1 (t3.s) |   | worker2 (t3.s) |        | master (t3.s)  |
     | kube-proxy     |<->| kube-proxy     |        | K3s server     |
     | whoami pods    |   | whoami pods    |        | (control plane)|
     +----------------+   +----------------+        +----------------+
            all in one VPC (10.0.0.0/16), public subnet, ap-southeast-1
```

Every response from the Spring Boot app says **which pod and which node** answered (`/api/whoami`), so the load tester can show, second by second, where traffic goes and what happens when one node is gone.

## The question

When a worker node dies without warning, two separate systems have to notice:

1. **Nginx** must stop sending connections to the dead server. It finds out when a connect attempt times out (`proxy_connect_timeout 1s`, then it retries the other worker).
2. **Kubernetes** must stop routing to pods on the dead server. It finds out only when the node stops reporting and is marked `NotReady` (typically 40 to 50 seconds), and it replaces those pods only after a toleration expires (300 seconds by default).

With the default `externalTrafficPolicy: Cluster`, kube-proxy on the **surviving** node forwards part of its traffic to pods on the **dead** node until step 2 happens. So the expected weak spot is not Nginx, it is the gap before Kubernetes reacts. The experiments measure that gap and close it.

## Experiments

Same procedure for each: load through Nginx (10 parallel clients, max 200 requests/second), and for failure runs, worker2 is force-stopped (`aws ec2 stop-instances --force`) at second 20. A watcher on the master logs, once per second, node status and which pod IPs are behind the Service, so the user-side errors can be lined up with what the cluster did (`scripts/timeline.py`).

### E1: How Nginx and kube-proxy share traffic

```bash
make deploy STEP=1-baseline DOCKERHUB_USER=<you>
make experiment NAME=e1-baseline DURATION=60
```

**Hypothesis:** about 50/50 between worker1 and worker2. But not only because of Nginx: with `Cluster`, a connection that reaches worker1 can be served by the pod on worker2 (a second hop, and the app sees a node IP instead of the real client IP).

**Result:** _TBD_ (share per node, `seenClientIp` values)

### E2: `externalTrafficPolicy: Local` with a node that has no pod

```bash
make deploy STEP=2-local DOCKERHUB_USER=<you>
make scale REPLICAS=1
make experiment NAME=e2-local-one-pod DURATION=60
```

**Hypothesis:** no second hop, and the app sees the Nginx IP as client. But the worker without a pod does not answer on 30001 at all, so every connection Nginx sends there waits for the 1 s connect timeout before being retried: no errors, but slow requests.

**Result:** _TBD_ (slow requests, latency p99)

### E3: A worker dies, lab default setup

```bash
make deploy STEP=1-baseline DOCKERHUB_USER=<you>     # check: one pod on each worker
make experiment NAME=e3-node-down EVENT=stop-worker2 DURATION=240
make start-worker2 && make rebalance
```

**Hypothesis:** Nginx reacts within about a second, but worker1's kube-proxy keeps sending part of the traffic to the dead pod until the node is marked `NotReady`. Expect failures (timeouts) for 40 to 50 seconds, and the dead pod is not replaced during the whole run (300 s default).

**Result:** _TBD_ (failed requests, error window, time to `NotReady`, time until the endpoint was removed)

### E4: A worker dies, resilient setup

```bash
make deploy STEP=3-resilient DOCKERHUB_USER=<you>   # check: two pods on each worker
make experiment NAME=e4-resilient-node-down EVENT=stop-worker2 DURATION=240
make start-worker2 && make rebalance
```

What changes:

| Setting | Why |
|---|---|
| `externalTrafficPolicy: Local` | worker1 only ever sends to its own pods, so the dead node's pods are never in its path |
| 4 replicas, `topologySpreadConstraints` | each worker always has local pods, which avoids E2's problem |
| `tolerationSeconds: 30` for `unreachable` / `not-ready` | pods on a dead node are replaced after 30 s, not 300 s |
| Nginx: `max_fails=1 fail_timeout=10s`, `proxy_next_upstream` | after one failed connect, Nginx skips the dead worker for 10 s and retries the other one |

**Hypothesis:** close to zero failed requests. The cost shows up as a few slow requests (about 1 s) while Nginx discovers the dead worker.

**Result:** _TBD_

![Requests per second while worker2 was stopped](screenshots/node-failure.png)

## Run it yourself

Requirements on your machine: AWS CLI (configured), Pulumi, Node.js, Docker, Python 3, a Docker Hub account.

```bash
make keys                       # EC2 key pairs -> infra/*.pem (git-ignored)
make infra                      # VPC + nginx + master + 2 workers (Pulumi)
make env                        # Pulumi outputs -> .env.mk and ssh/config
make image DOCKERHUB_USER=<you> # Spring Boot image, built for linux/amd64, pushed
make k3s                        # K3s on master, workers joined and labelled role=worker-node
make nginx                      # Layer 4 load balancer with the workers' private IPs
make deploy STEP=1-baseline DOCKERHUB_USER=<you>
make check                      # 6 requests: which node answered?
make ports                      # the lab's telnet checks (nc): you -> :80, nginx -> :30001
```

Then the experiments above. When finished: **`make destroy`** (the instances cost money while they run).

`make help` lists every target. Optional: `pulumi config set adminCidr <your-ip>/32` (in `infra/`) before `make infra` to allow SSH and HTTP only from your own IP.

## Repository layout

| Path | What it is |
|---|---|
| `app/` | Spring Boot service: `/api/whoami` returns pod, node, pod IP, and the client IP it sees |
| `infra/` | Pulumi program (VPC, subnet, security group, 4 EC2 instances) |
| `k8s/1-baseline` | the lab's Deployment + NodePort Service, with probes added |
| `k8s/2-local` | same, with `externalTrafficPolicy: Local` |
| `k8s/3-resilient` | 4 spread replicas, short eviction, graceful shutdown, `Local` |
| `nginx/` | Layer 4 (`stream`) config template and Dockerfile |
| `scripts/loadtest.py` | constant-rate load tester, counts answers per node, can trigger an event |
| `scripts/watch-cluster.sh` | runs on the master, logs node status and Service endpoints every second |
| `scripts/timeline.py` | merges load-test and cluster logs into one timeline |
| `scripts/plot.py` | chart of requests per second for several runs |
| `results/` | raw output of every run |

## Changes from the Poridhi lab

- Flask replaced by a Spring Boot service that reports which pod and node answered.
- The lab's Kubernetes manifest has broken indentation; fixed here.
- Workers join the master and Nginx reaches the workers over **private** IPs.
- The security group allows all traffic only inside the VPC; SSH and HTTP from outside can be limited to one IP.
- The whole lab is scripted (`make`), and every step after it is measured.
