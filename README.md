# GCP e2-micro + PrestaShop — One-Click Setup

Deploy a free PrestaShop ecommerce store on Google Cloud in one click.
Runs on an **e2-micro** instance under the **Always Free** tier.

---

## ▶ One-Click Deploy

Click the button below to open this project directly in Google Cloud Shell:

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/danb001/gcproject1&cloudshell_tutorial=README.md&cloudshell_open_in_editor=terraform.tfvars&cloudshell_workspace=.)

> **Before the button works:** Push this project to a public GitHub repo and replace `YOUR_GITHUB_USERNAME/YOUR_REPO_NAME` in the URL above.

---

## What gets deployed

| Resource | Spec | Cost |
|---|---|---|
| Compute instance | e2-micro, Debian 12 | Free |
| Disk | 30 GB standard persistent | Free |
| Static IP | 1 external IP | Free (while attached) |
| Web server | Nginx | — |
| Database | MariaDB | — |
| PHP | PHP 8.1-FPM | — |
| Store | PrestaShop 8.1.7 | — |

---

## Manual setup (if not using the button)

### Option A — Run entirely in Cloud Shell (recommended)

1. Open Cloud Shell: https://shell.cloud.google.com

2. Clone this repo:
   ```bash
   git clone https://github.com/danb001/gcproject1.git
   cd YOUR_REPO_NAME
   ```

3. Run the one-click script:
   ```bash
   bash setup.sh
   ```
   Total time: ~7 minutes.

### Option B — Run from VS Code on Windows

1. Edit `terraform.tfvars` with your project ID
2. In the VS Code terminal:
   ```powershell
   gcloud auth application-default login
   terraform init
   terraform apply -auto-approve
   gcloud compute scp install-prestashop.sh webserver:/tmp/ --zone=us-central1-a
   gcloud compute ssh webserver --zone=us-central1-a --command="sudo bash /tmp/install-prestashop.sh"
   ```

---

## After deployment

1. Open `http://YOUR_EXTERNAL_IP` in your browser
2. Complete the PrestaShop web installer:
   - DB host: `localhost`
   - DB name: `prestashop`
   - DB user: `psuser`
   - DB password: SSH in and run `sudo cat /root/prestashop-credentials.txt`
3. After the installer finishes run the cleanup:
   ```bash
   sudo rm -rf /var/www/prestashop/install
   sudo chmod 444 /var/www/prestashop/app/config/parameters.php
   ```
4. Admin panel: `http://YOUR_EXTERNAL_IP/admin_secure`

---

## Tear down

```bash
terraform destroy -auto-approve
```

