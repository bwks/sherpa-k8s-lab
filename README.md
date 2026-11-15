# sherpa-k8s-lab

A Kubernetes lab for [Sherpa](https://github.com/bwks/sherpa): a Talos Linux cluster with three
controllers and two workers, running Cilium, with Keycloak logins and Vault secrets, and a util
node with the tools to drive it. It is the lab of the
[Kubernetes example](https://docs.sherpalabs.net/examples/kubernetes/) in the Sherpa
documentation, with a walkthrough you can follow end to end on your own Sherpa server. Two parts
go beyond that page:

- **HTTPS on the Gateway.** cert-manager, with an issuer backed by Vault's PKI engine, gives the
  cluster's `sherpa` Gateway an HTTPS listener. The certificate chains to the lab CA, which the
  util node already trusts.
- **A Keycloak login in front of Hubble UI.** The Gateway asks oauth2-proxy about every request
  to Hubble UI, through the Gateway API `ExternalAuth` filter, and oauth2-proxy sends the
  browser to Keycloak to log in.

![A Talos Linux Kubernetes cluster with three controllers and two workers, Keycloak and Vault containers, and a util VM, on the management network](lab.svg)

| Role       | Nodes                  | Model             |
| ---------- | ---------------------- | ----------------- |
| Controller | `cp01`, `cp02`, `cp03` | `talos_linux`     |
| Worker     | `wrk01`, `wrk02`       | `talos_linux`     |
| Identity   | `kc01`                 | `keycloak_server` |
| Secrets    | `vault01`              | `hashicorp_vault` |
| Tools      | `util`                 | `ubuntu_linux`    |

[`manifest.toml`](manifest.toml) is the same manifest as the documentation's. What Sherpa sets
up from it (the Cilium Gateway and Hubble UI, Keycloak login, Vault secret sync) is described on
the [Talos Linux](https://docs.sherpalabs.net/nodes/linux/talos-linux/) page.

## Tested with

This walkthrough was run end to end with:

| Component | Version |
| --------- | ------- |
| Sherpa | 0.6.5 |
| Talos Linux | 1.14.4, with Kubernetes 1.37.1 |
| Cilium | 1.20.4, with Gateway API 1.6.3 (installed by Sherpa) |
| Keycloak | 26.4 |
| Vault | 1.21 (1.21.4) |
| Vault Secrets Operator | 1.6.2 (installed by Sherpa) |
| Ubuntu (util node) | 24.04 |
| cert-manager | 1.21.3 |
| oauth2-proxy | 7.15.6 |

## Prerequisites

- **A Sherpa server** you can run `sherpa up` on, with KVM, and internet access from labs: the
  util node downloads its tools, and the cluster pulls its images.
- **About 25 GB of free memory** on the server: 4 GB for each Talos node, 2 GB each for Keycloak
  and the util node, and 1 GB for Vault. Each Talos node has a 20 GB boot disk, and the util
  node 10 GB.
- **The node images**, as the server's defaults for `talos_linux` and `ubuntu_linux`:

  | Model | Version | How to get it |
  | ----- | ------- | ------------- |
  | `talos_linux` | 1.14.4 | `sherpa server image pull --model talos_linux --version 1.14.4 --default` |
  | `ubuntu_linux` | 24.04 | import an Ubuntu cloud image, see [Ubuntu](https://docs.sherpalabs.net/nodes/linux/ubuntu-linux/) |
  | `keycloak_server` | 26.4 | `sherpa server image pull --model keycloak_server --version 26.4` |
  | `hashicorp_vault` | 1.21 | `sherpa server image pull --model hashicorp_vault --version 1.21` |

- **A root shell on the Sherpa server** for one step of the HTTPS Gateway: signing Vault's CA
  certificate with the lab CA, whose key never leaves the server. Skip that part without it.
- **A browser** that reaches the lab's management network and trusts the lab CA, for Hubble UI.
  Import `.sherpa/ca/lab-ca.crt` into it after `sherpa up`.

## Bring the lab up

```
git clone https://github.com/bwks/sherpa-k8s-lab.git
cd sherpa-k8s-lab
sherpa up
```

`sherpa up` takes about five minutes. On the util node's first boot,
[`install-tools.sh`](install-tools.sh) installs `kubectl`, `talosctl`, the `kubectl oidc-login`
plugin, the `vault` CLI and the `cilium` CLI, each pinned and checked against its SHA-256. The
output ends with the lab's credentials and addresses:

```
✅ Lab CA certificate: /home/user/sherpa-k8s-lab/.sherpa/ca/lab-ca.crt
✅ Vault vault01 credentials: /home/user/sherpa-k8s-lab/.sherpa/vault/vault-vault01.toml
   export VAULT_ADDR=https://172.31.1.27:8200 VAULT_CACERT=/home/user/sherpa-k8s-lab/.sherpa/ca/lab-ca.crt
✅ Keycloak kc01 users: /home/user/sherpa-k8s-lab/.sherpa/keycloak/keycloak-kc01.toml
   Realm issuer: https://172.31.1.26:8443/realms/sherpa
✅ Cluster k8s credentials: /home/user/sherpa-k8s-lab/.sherpa/k8s/kubeconfig-k8s and /home/user/sherpa-k8s-lab/.sherpa/talos/talosconfig-k8s
   export KUBECONFIG=/home/user/sherpa-k8s-lab/.sherpa/k8s/kubeconfig-k8s TALOSCONFIG=/home/user/sherpa-k8s-lab/.sherpa/talos/talosconfig-k8s
   Gateway: http://172.31.1.13
   Hubble UI: http://172.31.1.14
```

The addresses here are a lab on `172.31.1.0/24`; yours are in your lab's management network.
The steps below read them from the files `sherpa up` wrote, so you do not type them.

## Get onto the util node

Copy the credentials, the Kubernetes manifests in [`k8s/`](k8s) and
[`lab-env.sh`](lab-env.sh) to the util node, and log in to it. Its SSH host name is
`util.<lab-id>`, with the lab ID from `.sherpa/lab-info.toml`:

```
LAB_ID=$(awk -F'"' '/^id/ {print $2}' .sherpa/lab-info.toml)
scp -F .sherpa/ssh/config -r .sherpa/k8s/kubeconfig-k8s .sherpa/talos/talosconfig-k8s \
  .sherpa/vault/vault-vault01.toml .sherpa/keycloak/keycloak-kc01.toml k8s lab-env.sh \
  util.$LAB_ID:
sherpa ssh util
```

Every step from here runs on the util node, in its home directory, after:

```
source ~/lab-env.sh
```

It sets `KUBECONFIG`, `TALOSCONFIG`, `VAULT_ADDR` and `VAULT_TOKEN` (Vault's root token), and
`KEYCLOAK`, `KEYCLOAK_ISSUER` and `GATEWAY_IP` for the steps, and defines `kc_admin`, which
calls Keycloak's admin API. Run it again in each new shell. Check the cluster:

```
kubectl get nodes
cilium status
```

All five nodes are `Ready`; `cilium status` can show a warning for the first minute or two.
The Vault Secrets Operator is installed by a Job about two minutes after the cluster starts;
wait for it before the Vault step:

```
kubectl -n vault-secrets-operator-system wait --for=condition=Complete job/vault-secrets-operator-install --timeout=10m
kubectl -n vault-secrets-operator-system rollout status deployment --timeout=5m
```

## Publish an app through the Gateway

Run two replicas of an echo server, with an HTTPRoute from the `sherpa` Gateway to them:

```
kubectl apply -k k8s/demo
kubectl -n demo rollout status deployment/echo
until curl -fs -o /dev/null http://$GATEWAY_IP/; do sleep 2; done
```

Kubernetes warns that the pods would break the `restricted` Pod Security profile; the cluster
enforces `baseline`, which they meet. The last line waits for the Gateway to serve the new
route, a few seconds after it is created. Each request answers from one of the two pods:

```
for i in 1 2 3 4; do curl -s http://$GATEWAY_IP/ | grep Hostname; done
```

Open Hubble UI at the `Hubble UI` address `sherpa up` printed (`.14`), pick the `demo`
namespace, and run the `curl` loop again to watch the requests arrive. The Hubble login below
closes that address and puts Hubble UI behind the Gateway.

## Block it with a network policy

Deny all traffic into the `demo` namespace:

```
kubectl apply -f k8s/policy/deny-all.yaml
curl -s --max-time 5 http://$GATEWAY_IP/
```

`curl` times out after five seconds, and Hubble shows the requests dropped by policy. Allow
traffic from the Gateway only, with a Cilium policy for its `ingress` identity:

```
kubectl apply -f k8s/policy/allow-gateway.yaml
curl -s http://$GATEWAY_IP/ | grep Hostname
```

The Gateway reaches the pods again, while other pods in the cluster still cannot:

```
kubectl run probe --rm -i --restart=Never --image=registry.k8s.io/e2e-test-images/agnhost:2.66.1 \
  -- connect echo.demo:80 --timeout=5s
```

`probe` prints `TIMEOUT` and exits with an error.

## Log in to Kubernetes as a Keycloak user

Sherpa's kubeconfig has two contexts: `admin@k8s`, the default, with the cluster admin
certificate, and `oidc@k8s`, which logs in through Keycloak in a browser. The util node has no
browser, so add a context that asks for the username and password instead, through the
`kubectl oidc-login` plugin:

```
kubectl config set-credentials oidc-password@k8s \
  --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=$KEYCLOAK_ISSUER \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--grant-type=password \
  --exec-interactive-mode=IfAvailable
kubectl config set-context oidc-password@k8s --cluster=k8s --user=oidc-password@k8s
kubectl --context oidc-password@k8s auth whoami
```

Sign in as yourself: the second user in `keycloak-kc01.toml`, the lab owner, with the password
there. `kubectl` shows you as `oidc:<username>` in the group `oidc:cluster-admins`, whose
members are cluster admins. The plugin keeps the token until it expires, so the next command
does not ask again:

```
kubectl --context oidc-password@k8s get pods -A
```

## Sync a Vault secret into a pod

Write a secret under the cluster's path in Vault, `secret/k8s/`:

```
vault kv put secret/k8s/demo password=s3cret
```

Sync it into a Kubernetes Secret with a `VaultStaticSecret`, and run a pod that mounts it:

```
kubectl apply -k k8s/vault-secret
kubectl -n demo wait --for=condition=Ready pod/reader --timeout=3m
kubectl -n demo get secret demo -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n demo exec reader -- cat /secrets/password; echo
```

Both print `s3cret`. Change it in Vault:

```
vault kv put secret/k8s/demo password=changed
```

The operator syncs the Secret within 30 seconds (`refreshAfter`), and the kubelet updates the
mounted file within about a minute more. Run the `exec` again until it prints `changed`. The
cluster can read only the secrets under `secret/k8s/`.

## HTTPS on the Gateway

cert-manager issues the Gateway a certificate from Vault's PKI engine. Vault holds an
intermediate CA, signed by the lab CA, so the certificate chains to the lab CA, which the util
node trusts (Sherpa adds it to the node's trust store).

### Install cert-manager

Install cert-manager 1.21.3 from its release manifest (Sherpa does not run Helm), and wait for
its webhook:

```
kubectl apply -k k8s/cert-manager
kubectl -n cert-manager rollout status deployment --timeout=5m
```

### Make Vault an intermediate CA

Enable the PKI engine and make the intermediate CA's key in Vault. Vault writes a certificate
signing request:

```
vault secrets enable pki
vault secrets tune -max-lease-ttl=4320h pki
vault write -field=csr pki/intermediate/generate/internal \
  common_name="Sherpa Lab Vault Intermediate CA" key_type=ec key_bits=256 > vault-intermediate.csr
```

The lab CA's key is on the Sherpa server, in `/opt/sherpa/labs/<lab-id>/certs/`, readable only
by the server. Sign the request there. In the lab folder on your workstation, fetch the request
from the util node:

```
LAB_ID=$(awk -F'"' '/^id/ {print $2}' .sherpa/lab-info.toml)
scp -F .sherpa/ssh/config util.$LAB_ID:vault-intermediate.csr .
```

If your workstation is not the Sherpa server, copy `vault-intermediate.csr` to the server. Then,
on the server, in the folder with the request, with `LAB_ID` set to the lab ID, sign it as a CA
for server certificates only (`pathlen:0`: it cannot make further CAs), for 180 days, inside the
lab CA's 365:

```
cat > intermediate-ca.ext <<'EOF'
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign, digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
sudo openssl x509 -req -in vault-intermediate.csr \
  -CA /opt/sherpa/labs/$LAB_ID/certs/ca.crt -CAkey /opt/sherpa/labs/$LAB_ID/certs/ca.key \
  -set_serial 0x$(openssl rand -hex 16) -days 180 -sha256 \
  -extfile intermediate-ca.ext -out vault-intermediate.crt
```

Copy `vault-intermediate.crt` back to the lab folder on your workstation if you signed it
elsewhere, and from there to the util node:

```
scp -F .sherpa/ssh/config vault-intermediate.crt util.$LAB_ID:
```

On the util node, give Vault the signed certificate with the lab CA after it, then add a role
for the Gateway's certificates and a login for cert-manager:

```
cat vault-intermediate.crt /etc/sherpa/certs/ca.crt > vault-intermediate-chain.pem
vault write pki/intermediate/set-signed certificate=@vault-intermediate-chain.pem
vault patch pki/issuer/default leaf_not_after_behavior=truncate
vault write pki/roles/gateway allow_ip_sans=true require_cn=false key_type=any \
  max_ttl=720h not_before_duration=0s
vault policy write cert-manager - <<'EOF'
path "pki/sign/gateway" {
  capabilities = ["create", "update"]
}
EOF
vault write auth/kubernetes-k8s/role/cert-manager role_type=jwt bound_audiences=vault \
  user_claim=sub bound_subject=system:serviceaccount:default:vault-issuer \
  token_policies=cert-manager token_ttl=10m
```

- `set-signed` warns that the mount has no AIA URLs; the lab does not need them.
- `leaf_not_after_behavior=truncate` ends certificates with the intermediate instead of
  refusing ones that would outlive it.
- The `gateway` role issues certificates for IP addresses, without a common name.
  `not_before_duration=0s` starts them when they are issued: Vault's default backdates them
  30 seconds, which is before a just-signed intermediate's start and is refused.
- The login reuses the cluster's Vault auth method, `kubernetes-k8s`, which Sherpa set up. The
  `cert-manager` role accepts only the `vault-issuer` service account and may only sign with
  the `gateway` role.

### Issue the certificate and add the listener

Give cert-manager the lab CA to trust Vault with, the `vault-issuer` service account, an
`Issuer` for Vault and a `Certificate` for the Gateway's address. `envsubst` fills in
`VAULT_ADDR` and `GATEWAY_IP`:

```
kubectl -n default create secret generic lab-ca --from-file=ca.crt=/etc/sherpa/certs/ca.crt
kubectl apply -f k8s/gateway-tls/vault-issuer-rbac.yaml
envsubst '$VAULT_ADDR' < k8s/gateway-tls/issuer.yaml | kubectl apply -f -
envsubst '$GATEWAY_IP' < k8s/gateway-tls/certificate.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready issuer/vault certificate/sherpa-gateway --timeout=3m
```

Add an HTTPS listener on port 443 to the `sherpa` Gateway. Apply it server-side, under its own
field manager: Gateway listeners merge by name, so Sherpa's `http` listener stays as it is.

```
kubectl apply --server-side --field-manager=gateway-tls -f k8s/gateway-tls/listeners.yaml
```

The demo app's route attaches to the new listener too. Within a few seconds it answers over
HTTPS, and `curl` verifies the certificate with the system trust store:

```
sleep 5
curl -s https://$GATEWAY_IP/ | grep Hostname
curl -sv -o /dev/null https://$GATEWAY_IP/ 2>&1 | grep -E 'issuer|verify'
```

```
*  issuer: CN=Sherpa Lab Vault Intermediate CA
*  SSL certificate verify ok.
```

cert-manager renews the certificate ten days before its 30 days are up. A browser that trusts
the lab CA trusts it too.

## A Keycloak login in front of Hubble UI

Hubble UI moves behind the Gateway, on an HTTPS listener on port 8443. Every request is checked
by oauth2-proxy through the HTTPRoute `ExternalAuth` filter, which Cilium 1.20 implements:
oauth2-proxy answers `200` for a logged-in member of `cluster-admins`, and otherwise sends the
browser to Keycloak's login page in the `sherpa` realm. Then a Cilium policy closes Hubble UI's
own address, so the login cannot be bypassed.

### Install the experimental Gateway API CRDs

`ExternalAuth` is in the Gateway API's experimental channel. Sherpa installs the standard
channel, whose `safe-upgrades` admission policy refuses experimental CRDs over standard ones.
Delete the policy, then install the same release's experimental CRDs:

```
kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io
kubectl apply --server-side --force-conflicts -k k8s/gateway-api-experimental
kubectl explain httproute.spec.rules.filters.externalAuth.http.allowedHeaders | grep FIELD
```

The last command prints `FIELD: allowedHeaders <[]string>`: the HTTPRoute CRD has the filter.

`--force-conflicts` takes the CRDs over from Talos, which applied the standard ones while the
cluster bootstrapped. Talos does not apply them again later, also not when a controller
reboots. The experimental CRDs keep every standard field, so the Gateway and routes are
unchanged.

### Add a Keycloak client for Hubble

Make a confidential client, `hubble`, in the `sherpa` realm through Keycloak's admin API. Its
only redirect address is oauth2-proxy's callback on the Gateway, and it adds the user's groups
to its tokens:

```
jq -n --arg redirect "https://$GATEWAY_IP:8443/oauth2/callback" '{
  clientId: "hubble",
  publicClient: false,
  standardFlowEnabled: true,
  directAccessGrantsEnabled: false,
  redirectUris: [$redirect],
  attributes: { "pkce.code.challenge.method": "S256" },
  protocolMappers: [{
    name: "groups",
    protocol: "openid-connect",
    protocolMapper: "oidc-group-membership-mapper",
    config: { "claim.name": "groups", "full.path": "false", "id.token.claim": "true",
              "access.token.claim": "true", "userinfo.token.claim": "true" }
  }]
}' | kc_admin -X POST "$KEYCLOAK/admin/realms/sherpa/clients" -d @-
HUBBLE_CLIENT=$(kc_admin "$KEYCLOAK/admin/realms/sherpa/clients?clientId=hubble" | jq -r '.[0].id')
CLIENT_SECRET=$(kc_admin "$KEYCLOAK/admin/realms/sherpa/clients/$HUBBLE_CLIENT/client-secret" | jq -r .value)
```

### Run oauth2-proxy and route Hubble UI

Put the client secret and a new cookie secret in a Secret, and the lab CA, which oauth2-proxy
trusts Keycloak with, in a ConfigMap. Then run oauth2-proxy:

```
kubectl apply -f k8s/hubble-login/namespace.yaml
kubectl -n hubble-login create secret generic oauth2-proxy \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --from-literal=cookie-secret="$(openssl rand -hex 16)"
kubectl -n hubble-login create configmap lab-ca --from-file=ca.crt=/etc/sherpa/certs/ca.crt
envsubst '$KEYCLOAK_ISSUER $GATEWAY_IP' < k8s/hubble-login/oauth2-proxy.yaml | kubectl apply -f -
kubectl -n hubble-login rollout status deployment/oauth2-proxy
```

The Pod Security warning is the same as the demo app's: the pod meets `baseline`.

Add the `hubble` listener on 8443, with the Gateway's certificate, under its own field manager.
Only routes in the `hubble-login` namespace can attach to it. Then add the route, with a
ReferenceGrant that lets it reach the `hubble-ui` Service in `kube-system`:

```
kubectl apply --server-side --field-manager=hubble-login -f k8s/hubble-login/listener.yaml
kubectl apply -f k8s/hubble-login/route.yaml
```

Within a few seconds a request without a session is sent to Keycloak:

```
sleep 5
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://$GATEWAY_IP:8443/
```

```
302 https://172.31.1.26:8443/realms/sherpa/protocol/openid-connect/auth?...&client_id=hubble&...
```

### Close Hubble UI's own address

Sherpa gives Hubble UI a load balancer address, `.14`, open to the management network. Allow
traffic into Hubble UI only from the Gateway:

```
kubectl apply -f k8s/hubble-login/hubble-ui-policy.yaml
sleep 10
curl -s --max-time 5 -o /dev/null http://$(kubectl -n kube-system get service hubble-ui-sherpa \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/
```

`curl` times out. Cilium takes a few seconds to enforce a new policy, hence the `sleep`.

### Log in

Browse to `https://<gateway address>:8443/`, the `Gateway` address `sherpa up` printed with
`https` and port 8443. Keycloak's login page opens. Sign in as a member of `cluster-admins`,
such as the lab owner in `keycloak-kc01.toml`, and Hubble UI opens. oauth2-proxy keeps the
session for 7 days, its default.

A user outside `cluster-admins` is refused. Add one, in `cluster-viewers`, with a generated
password:

```
VIEWER_PASSWORD=$(openssl rand -hex 12)
jq -n --arg password "$VIEWER_PASSWORD" '{
  username: "viewer", enabled: true, email: "viewer@sherpa.lab.local", emailVerified: true,
  firstName: "viewer", lastName: "sherpa", groups: ["cluster-viewers"],
  credentials: [{ type: "password", value: $password, temporary: false }]
}' | kc_admin -X POST "$KEYCLOAK/admin/realms/sherpa/users" -d @-
echo "$VIEWER_PASSWORD"
```

In a private browser window, sign in as `viewer` with that password: oauth2-proxy answers
`403 Forbidden`.

## Destroy the lab

On your workstation, in the lab folder:

```
sherpa destroy
```

It deletes every node and the lab's files on the server, the lab CA among them. Delete the
lab's `.sherpa` folder, `vault-intermediate.*` and `intermediate-ca.ext` too if you no longer
need them.

## Notes

- **No secrets in this repository.** The Keycloak client secret, the oauth2-proxy cookie secret
  and every password and token come from the lab while you run the steps.
- **Pinned versions.** Every image and release manifest in `k8s/` has a fixed version. The
  cert-manager and Gateway API manifests are downloaded from their GitHub releases when you
  apply them.
- **Lab-specific values** (the Gateway, Keycloak and Vault addresses) are filled in by
  `envsubst` from `lab-env.sh`, in `k8s/gateway-tls/issuer.yaml`,
  `k8s/gateway-tls/certificate.yaml` and `k8s/hubble-login/oauth2-proxy.yaml`. The rest of
  `k8s/` applies as it is.
- **Redeploying Vault** (`sherpa redeploy --node vault01`) starts an empty Vault: the PKI
  engine, the `gateway` role and the `cert-manager` login are gone, and cert-manager cannot renew
  the certificate until you repeat [Make Vault an intermediate CA](#make-vault-an-intermediate-ca).
  **Redeploying Keycloak** removes the `hubble` client and the `viewer` user.
- **Why the Gateway's external auth, not oauth2-proxy as a reverse proxy.** Cilium 1.20's Gateway
  implements the `ExternalAuth` filter, so the Gateway enforces the login and oauth2-proxy only
  answers yes or no. It needs the experimental channel CRDs, and the `allowedHeaders: [Cookie]`
  in the route: an auth check carries only a few of the request's headers unless more are
  listed, and without the session cookie every request goes back to Keycloak.

## Licence

[MIT](LICENSE).
