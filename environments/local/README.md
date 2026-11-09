# Local kind cluster

A throwaway Kubernetes cluster on my laptop for testing charts before they go to
the prod cluster on Oracle. It uses the same charts as prod; only these local files differ.

- Cluster name: `local-projects-kind-cluster` (kubectl context `kind-local-projects-kind-cluster`)
- Nodes: 1 control-plane + 2 workers
- Traffic: `localhost:80` / `:443` -> control-plane `:30080` / `:30443` (NodePort) -> Traefik

Run everything from the repo root (`projects-infra/`), top to bottom.

## Prerequisites

- Docker, kind, kubectl, Helm 4

## 1. Create the cluster

```bash
kind create cluster --config environments/local/kind-config.yaml
kubectl config current-context   # kind-local-projects-kind-cluster
kubectl get nodes                # 3 nodes, all Ready
```

## 2. Gateway API CRDs (must come before Traefik)

Adds the `GatewayClass`, `Gateway` and `HTTPRoute` object types. The Traefik chart
no longer ships them. Needed again every time the cluster is recreated.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
kubectl get crds | grep gateway.networking.k8s.io
```

## 3. Traefik (Gateway API controller)

Chart `traefik/traefik` 42.3.1 (Traefik v3.7.17). Settings in `traefik-values.yaml`:
Gateway API provider on, Service type NodePort, nodePorts 30080 / 30443, and the
Gateway's `web` listener accepts HTTPRoutes from **all** namespaces
(`gateway.listeners.web.namespacePolicy.from: All`; the default `Same` would ignore
routes in app namespaces). The chart also creates a default `GatewayClass` and
`Gateway` in the `traefik` namespace.

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

# preview without touching the cluster
helm template traefik traefik/traefik --version 42.3.1 -n traefik \
  --kube-version 1.37.0 -f environments/local/traefik-values.yaml

# install
helm install traefik traefik/traefik --version 42.3.1 \
  -n traefik --create-namespace \
  -f environments/local/traefik-values.yaml
```

Check:

```bash
kubectl get pods -n traefik -o wide   # Running, 1/1
kubectl get svc -n traefik            # NodePort 80:30080, 443:30443
kubectl get gateway -n traefik        # PROGRAMMED True
curl -i http://localhost              # 404 page not found = Traefik reached, no routes yet
```

Change settings later: edit `traefik-values.yaml`, then

```bash
helm upgrade traefik traefik/traefik --version 42.3.1 -n traefik -f environments/local/traefik-values.yaml
```

## 4. Load app images into the nodes

kind nodes can't see images in the laptop's Docker. Build, then copy the image into
every node. Use a fixed tag (not `latest`), otherwise Kubernetes tries to pull from Docker Hub.

```bash
# from /mnt/data/projects/projects-service
docker build -t projects-service:0.0.1 .
kind load docker-image projects-service:0.0.1 --name local-projects-kind-cluster

# check (any node)
docker exec local-projects-kind-cluster-worker crictl images | grep projects-service
```

After a code change: rebuild with a new tag (e.g. `0.0.2`), load it again, and update the tag in the values file.

## 5. Database credentials Secret (manual, never in git)

One Secret with the Postgres username/password. Secrets are namespace-scoped, so it is
needed in BOTH namespaces: `postgres` (the server creates the user from it) and
`projects-service` (the app logs in with it). Same values in both. Vault replaces this later.

```bash
kubectl create namespace postgres
kubectl create namespace projects-service
for ns in postgres projects-service; do
  kubectl create secret generic postgres-credentials -n $ns \
    --from-literal=username=projects \
    --from-literal=password='<choose-one>'
done

# check (keys only; values are just base64, not encrypted)
kubectl describe secret postgres-credentials -n postgres
```

## 6. Postgres (hand-written StatefulSet, kind only)

Chart `charts/postgres` (Postgres 18): headless Service `postgres` (port 5432) +
StatefulSet `postgres` (1 replica, PVC `data-postgres-0` from `volumeClaimTemplates`,
mounted at `/var/lib/postgresql`). Chart defaults are the kind settings, so no local
values file. Prod uses CloudNativePG instead of this chart.

```bash
# validate against the API server (nothing is saved)
helm template postgres charts/postgres -n postgres \
  | kubectl apply -n postgres --dry-run=server -f -

helm install postgres charts/postgres -n postgres
kubectl get pods,pvc -n postgres -w   # postgres-0 1/1 Running, PVC Bound
```

Check you can log in (uses the env vars from the Secret inside the pod):

```bash
kubectl exec -n postgres postgres-0 -- sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select current_user, current_database();"'
```

DNS name for clients: `postgres-0.postgres.postgres.svc.cluster.local:5432`
(pod `postgres-0`, Service `postgres`, namespace `postgres`).

Note: the PVC lives on the laptop's disk (kind's local-path provisioner); the `1Gi`
size is not enforced. `kind delete cluster` deletes the data.

## 7. projects-service (manual for now, Argo CD later)

Needs steps 4–6 first (image loaded, Secret in the `projects-service` namespace,
Postgres running).

Chart defaults are in `charts/projects-service/values.yaml`; kind overrides
(1 replica, local image tag, `db.host`, route on `api.localhost`) are in
`projects-service-values.yaml`.

The app serves everything under its context path `/projects` (Spring
`server.servlet.context-path`), so probes use `/projects/livez` and `/projects/readyz`.

How the app gets its DB settings:
- ConfigMap named after the Helm release, here `projects-service` (rendered from `db.*` values) → `envFrom` →
  `APP_POSTGRES_URL=jdbc:postgresql://postgres.postgres.svc.cluster.local:5432/projects`.
  `db.host` is `required`: rendering fails if an environment doesn't set it.
- Secret `postgres-credentials` → `env` + `secretKeyRef` → `POSTGRES_USERNAME` / `POSTGRES_PASSWORD`.
- The pod template has a `checksum/config` annotation, so a ConfigMap change rolls out new pods.

How it is reached from outside (path-based routing on one API host):
- HTTPRoute `projects-service` (only if `routes.enabled`; fails to render if enabled with
  empty `routes.hostnames`) attaches to Gateway `traefik-gateway` (ns `traefik`), listener
  `web`: host `api.localhost`, `PathPrefix /projects` → Service `projects-service:80`.
- `http://api.localhost/projects/...` → localhost:80 → kind :30080 → Traefik → route → pod.

Always pass `-n projects-service`: the release lives in that namespace, and without
`-n` Helm looks in `default` ("has no deployed releases").

```bash
# preview the rendered YAML (no cluster needed)
helm template projects-service charts/projects-service -n projects-service \
  -f environments/local/projects-service-values.yaml

# validate against the real API server (nothing is saved)
helm template projects-service charts/projects-service -n projects-service \
  -f environments/local/projects-service-values.yaml \
  | kubectl apply -n projects-service --dry-run=server -f -

# first install
helm install projects-service charts/projects-service \
  -n projects-service --create-namespace \
  -f environments/local/projects-service-values.yaml

# after changing the chart or values
helm upgrade projects-service charts/projects-service -n projects-service \
  -f environments/local/projects-service-values.yaml

kubectl get pods -n projects-service -w             # 1/1 Running
helm history projects-service -n projects-service   # one revision per install/upgrade
```

Check it end to end from inside the cluster (throwaway curl pod):

```bash
kubectl run curl-test -n projects-service --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://projects-service/projects/readyz
# {"status":"UP","components":{"db":{"status":"UP"},"readinessState":{"status":"UP"}}}
```

From the laptop, through Traefik and the HTTPRoute:

```bash
kubectl describe httproute projects-service -n projects-service | sed -n '/Status:/,$p'
#   Accepted True, ResolvedRefs True  (False + NotAllowedByListeners = Gateway namespacePolicy)
curl -i http://api.localhost/projects/readyz   # 200 {"status":"UP",...}
curl -i http://api.localhost/nothing           # 404 "404 page not found"  = Traefik, no route
curl -i http://api.localhost/projects/nope     # 404 JSON {"status":404,...} = Spring, route worked
```

Debugging:

```bash
kubectl logs -n projects-service deploy/projects-service              # app output
kubectl logs -n projects-service deploy/projects-service --previous   # last crashed attempt
kubectl describe pod -n projects-service <pod-name>                   # Events at the bottom
```

## Delete everything

```bash
kind delete cluster --name local-projects-kind-cluster
```

Deletes all nodes and everything in them (CRDs, Traefik, data). Start again from step 1.
