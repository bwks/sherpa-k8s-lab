# Settings for the README's steps on the util node: `source ~/lab-env.sh` in each new shell.
# Everything is read from the files `sherpa up` wrote, copied to the home directory, so
# nothing here is specific to one lab.

export KUBECONFIG="$HOME/kubeconfig-k8s" TALOSCONFIG="$HOME/talosconfig-k8s"

# Vault on vault01, with the root token. The util node trusts the lab CA, so the vault CLI
# needs no VAULT_CACERT.
VAULT_ADDR="$(awk -F'"' '/^address/ {print $2}' "$HOME/vault-vault01.toml")"
VAULT_TOKEN="$(awk -F'"' '/^root_token/ {print $2}' "$HOME/vault-vault01.toml")"
export VAULT_ADDR VAULT_TOKEN

# Keycloak on kc01, and its `sherpa` realm's issuer.
KEYCLOAK="$(awk -F'"' '/^address/ {print $2}' "$HOME/keycloak-kc01.toml")"
KEYCLOAK_ISSUER="$(awk -F'"' '/^issuer/ {print $2}' "$HOME/keycloak-kc01.toml")"
export KEYCLOAK KEYCLOAK_ISSUER

# The `sherpa` Gateway's address, the lab's .13.
GATEWAY_IP="$(kubectl get gateway sherpa -o jsonpath='{.status.addresses[0].value}')"
export GATEWAY_IP

# Call Keycloak's admin API as the master realm's admin, `sherpa`, whose password is the
# `sherpa` user's in keycloak-kc01.toml. Each call gets a new token: they last a minute.
kc_admin() {
    local password token
    password="$(awk -F'"' '/^username = "sherpa"/ {getline; print $2}' "$HOME/keycloak-kc01.toml")"
    token="$(curl -fsS "$KEYCLOAK/realms/master/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=admin-cli -d username=sherpa \
        --data-urlencode "password=$password" | jq -r .access_token)"
    curl -fsS -H "Authorization: Bearer $token" -H "Content-Type: application/json" "$@"
}
