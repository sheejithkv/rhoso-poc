#!/usr/bin/env bash
# WHAT: Generates osp-secret with all RHOSO service passwords + Heat/Fernet encryption keys.
#       Passwords cannot be changed after control plane deploy without a manual re-sync, so
#       get this right before applying the OpenStackControlPlane CR.
# FIXED: was hardcoded to /home/claude/rhoso-poc/... (broke for anyone else / any other checkout
#       path). Now resolves its own location at runtime, same pattern used across every script
#       in this repo.
# VERIFY: oc get secret osp-secret -n openstack
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=openstack
gen() { openssl rand -hex 16; }
cat > "${SCRIPT_DIR}/02-osp-secret.yaml" << YAML
apiVersion: v1
kind: Secret
metadata:
  name: osp-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  AdminPassword: $(gen)
  DbRootPassword: $(gen)
  KeystoneDatabasePassword: $(gen)
  PlacementDatabasePassword: $(gen)
  NovaDatabasePassword: $(gen)
  NovaAPIDatabasePassword: $(gen)
  NovaCell0DatabasePassword: $(gen)
  NeutronDatabasePassword: $(gen)
  CinderDatabasePassword: $(gen)
  GlanceDatabasePassword: $(gen)
  HeatDatabasePassword: $(gen)
  HeatAuthEncryptionKey: $(python3 -c "import secrets,base64;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())")
  HeatStackDomainAdminPassword: $(gen)
  OctaviaDatabasePassword: $(gen)
  DesignateDatabasePassword: $(gen)
  SwiftDatabasePassword: $(gen)
  BarbicanDatabasePassword: $(gen)
  BarbicanSimpleCryptoKEK: $(python3 -c "import secrets,base64;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())")
  AodhDatabasePassword: $(gen)
  AodhPassword: $(gen)
  CeilometerPassword: $(gen)
YAML
echo "Wrote ${SCRIPT_DIR}/02-osp-secret.yaml. Review it, then: oc apply -f ${SCRIPT_DIR}/02-osp-secret.yaml"
