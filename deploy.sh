#!/usr/bin/env bash
# Deploy the Trading 212 MCP server to Google Cloud Run.
# Run from this folder in Cloud Shell (or any machine with gcloud installed and logged in).
#
# Optional overrides:
#   PROJECT_ID=...  SERVICE=trading212-mcp  REGION=europe-west2  ENVIRONMENT=demo|live  ROTATE_TOKEN=1
set -euo pipefail

SERVICE="${SERVICE:-trading212-mcp}"
REGION="${REGION:-europe-west2}"      # London, close to Trading 212's API
ROTATE_TOKEN="${ROTATE_TOKEN:-0}"

# Prompts read from the terminal, so this works however the script is started.
ask() { local prompt="$1" var; read -rp "${prompt}" var </dev/tty; printf '%s' "${var}"; }

if [[ -z "${ENVIRONMENT:-}" ]]; then
  ENVIRONMENT="$(ask "Trading 212 account: demo (paper trading) or live (real money)? [demo]: ")"
  ENVIRONMENT="${ENVIRONMENT:-demo}"
fi
if [[ "${ENVIRONMENT}" != "demo" && "${ENVIRONMENT}" != "live" ]]; then
  echo "ENVIRONMENT must be 'demo' or 'live'." >&2
  exit 1
fi

SECRET_KEY="t212-api-key"
SECRET_SECRET="t212-api-secret"
SECRET_TOKEN="t212-mcp-token"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "Your Google Cloud projects:"
  gcloud projects list --format='table(projectId, name)'
  PROJECT_ID="$(ask "Project ID to deploy into: ")"
  [[ -n "${PROJECT_ID}" ]] || { echo "No project given." >&2; exit 1; }
fi
gcloud config set project "${PROJECT_ID}" >/dev/null 2>&1

# Billing check. Only stop when Google clearly says billing is off: on a new
# project the Cloud Billing API may not be enabled, so the lookup itself can
# fail even though billing is fine. In that case carry on; enabling the APIs
# below fails with a clear message if billing really is missing.
BILLING="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud billing projects describe "${PROJECT_ID}" \
  --format='value(billingEnabled)' 2>/dev/null || true)"
if [[ "${BILLING}" == "False" ]]; then
  echo "Billing isn't linked to project ${PROJECT_ID}. Cloud Run needs it." >&2
  echo "Link a billing account here, then run this script again:" >&2
  echo "  https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}" >&2
  exit 1
fi
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
# Builds run as the default compute service account. The server itself runs as a
# dedicated account with no project roles, because Google often gives the default
# compute account roles/editor on the whole project.
BUILD_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
RUNTIME_SA_NAME="t212-mcp-runtime"
RUNTIME_SA="${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Project: ${PROJECT_ID} | Region: ${REGION} | Service: ${SERVICE} | Environment: ${ENVIRONMENT}"

echo "==> Enabling APIs"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com

echo "==> Granting build permissions to the default compute service account"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${BUILD_SA}" \
  --role="roles/run.builder" \
  --condition=None >/dev/null

echo "==> Creating a dedicated runtime service account (no project roles)"
if ! gcloud iam service-accounts describe "${RUNTIME_SA}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${RUNTIME_SA_NAME}" \
    --display-name="Trading 212 MCP server runtime" >/dev/null
fi

# New service accounts take a few seconds to become usable in IAM bindings.
retry() {
  local n
  for n in 1 2 3 4 5 6; do
    "$@" && return 0
    sleep 5
  done
  return 1
}

secret_exists() { gcloud secrets describe "$1" >/dev/null 2>&1; }

# upsert_secret NAME VALUE  (empty VALUE keeps an existing secret unchanged)
upsert_secret() {
  local name="$1" value="$2"
  if [[ -z "${value}" ]]; then
    if secret_exists "${name}"; then
      echo "    ${name}: keeping existing value"
    else
      echo "    ${name}: no value given and no existing secret" >&2
      exit 1
    fi
  elif secret_exists "${name}"; then
    printf '%s' "${value}" | gcloud secrets versions add "${name}" --data-file=- >/dev/null
    echo "    ${name}: new version added"
  else
    printf '%s' "${value}" | gcloud secrets create "${name}" \
      --replication-policy=automatic --data-file=- >/dev/null
    echo "    ${name}: created"
  fi
  retry gcloud secrets add-iam-policy-binding "${name}" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role="roles/secretmanager.secretAccessor" >/dev/null
}

echo "==> Trading 212 credentials (input hidden; press Enter to keep existing secrets)"
read -rsp "    API key: " T212_KEY </dev/tty; echo
read -rsp "    API secret: " T212_SECRET </dev/tty; echo

echo "==> Storing secrets in Secret Manager"
upsert_secret "${SECRET_KEY}" "${T212_KEY}"
upsert_secret "${SECRET_SECRET}" "${T212_SECRET}"

if secret_exists "${SECRET_TOKEN}" && [[ "${ROTATE_TOKEN}" != "1" ]]; then
  MCP_TOKEN="$(gcloud secrets versions access latest --secret="${SECRET_TOKEN}")"
  upsert_secret "${SECRET_TOKEN}" ""
else
  MCP_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  upsert_secret "${SECRET_TOKEN}" "${MCP_TOKEN}"
fi
unset T212_KEY T212_SECRET

echo "==> Building and deploying (takes a few minutes)"
gcloud run deploy "${SERVICE}" \
  --source . \
  --region "${REGION}" \
  --allow-unauthenticated \
  --service-account="${RUNTIME_SA}" \
  --cpu-boost \
  --set-env-vars="ENVIRONMENT=${ENVIRONMENT}" \
  --set-secrets="TRADING212_API_KEY=${SECRET_KEY}:latest,TRADING212_API_SECRET=${SECRET_SECRET}:latest,MCP_TOKEN=${SECRET_TOKEN}:latest"

URL="$(gcloud run services describe "${SERVICE}" --region "${REGION}" --format='value(status.url)')"

echo
echo "Done. Connector URL (treat it like a password, never commit or share it):"
echo "    ${URL}/${MCP_TOKEN}/mcp"
