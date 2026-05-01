#!/bin/bash
# =============================================================================
# setup.sh — One-click GCP e2-micro + PrestaShop deployment
# Runs entirely in Google Cloud Shell (no local tools needed)
#
# Usage:
#   bash setup.sh                        # interactive prompts
#   bash setup.sh --project my-proj-123  # skip project prompt
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
banner()  {
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║   GCP e2-micro + PrestaShop Installer   ║"
  echo "  ║         Always Free Tier Setup           ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ── Parse arguments ───────────────────────────────────────────────────────────
PROJECT_ID=""
ZONE="us-central1-a"
REGION="us-central1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --zone)    ZONE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

REGION="${ZONE%-*}"   # derive region from zone

# ── Banner ────────────────────────────────────────────────────────────────────
banner

# ── Resolve project ───────────────────────────────────────────────────────────
section "Project setup"

if [[ -z "$PROJECT_ID" ]]; then
  # Try to detect current project from gcloud config
  DETECTED=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -n "$DETECTED" && "$DETECTED" != "(unset)" ]]; then
    echo -e "Detected project: ${BOLD}${DETECTED}${NC}"
    read -rp "Use this project? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
      read -rp "Enter your GCP Project ID: " PROJECT_ID
    else
      PROJECT_ID="$DETECTED"
    fi
  else
    echo "Find your Project ID at: https://console.cloud.google.com"
    read -rp "Enter your GCP Project ID: " PROJECT_ID
  fi
fi

gcloud config set project "$PROJECT_ID"
info "Using project: $PROJECT_ID"

# ── Enable required APIs ──────────────────────────────────────────────────────
section "Enabling Compute Engine API"
gcloud services enable compute.googleapis.com --project="$PROJECT_ID"
info "Compute Engine API enabled"

# ── Check / create Terraform state bucket ────────────────────────────────────
section "Terraform initialisation"

cd "$(dirname "$0")"

# Write the tfvars file from detected values
cat > terraform.tfvars <<EOF
project_id = "${PROJECT_ID}"
region     = "${REGION}"
zone       = "${ZONE}"
EOF

info "terraform.tfvars written"

terraform init -input=false
info "Terraform initialised"

# ── Plan & Apply ──────────────────────────────────────────────────────────────
section "Provisioning infrastructure (this takes ~2 minutes)"
terraform apply -auto-approve -input=false

EXTERNAL_IP=$(terraform output -raw external_ip)
info "Instance created — IP: ${EXTERNAL_IP}"

# ── Wait for SSH to become available ─────────────────────────────────────────
section "Waiting for instance to boot"
echo -n "  Waiting for SSH"
for i in $(seq 1 30); do
  if gcloud compute ssh webserver \
      --zone="$ZONE" \
      --project="$PROJECT_ID" \
      --command="echo ok" \
      --strict-host-key-checking=no \
      --quiet 2>/dev/null; then
    echo ""
    info "SSH is ready"
    break
  fi
  echo -n "."
  sleep 5
done

# ── Upload and run the PrestaShop installer ───────────────────────────────────
section "Uploading PrestaShop installer to server"
gcloud compute scp install-prestashop.sh webserver:/tmp/install-prestashop.sh \
  --zone="$ZONE" \
  --project="$PROJECT_ID" \
  --strict-host-key-checking=no \
  --quiet

section "Installing LEMP stack + PrestaShop (this takes ~5 minutes)"
gcloud compute ssh webserver \
  --zone="$ZONE" \
  --project="$PROJECT_ID" \
  --strict-host-key-checking=no \
  --quiet \
  --command="sudo bash /tmp/install-prestashop.sh"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║              🎉 Setup Complete!                  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  🌐 Open your store:   ${BOLD}http://${EXTERNAL_IP}${NC}"
echo -e "  🔑 DB credentials:   ${BOLD}sudo cat /root/prestashop-credentials.txt${NC}"
echo ""
echo -e "  Complete the PrestaShop web installer in your browser,"
echo -e "  then run the post-install cleanup:"
echo ""
echo -e "  ${CYAN}gcloud compute ssh webserver --zone=${ZONE} --project=${PROJECT_ID}${NC}"
echo -e "  ${CYAN}sudo rm -rf /var/www/prestashop/install${NC}"
echo -e "  ${CYAN}sudo chmod 444 /var/www/prestashop/app/config/parameters.php${NC}"
echo ""
