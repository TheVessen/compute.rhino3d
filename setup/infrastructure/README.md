gcloud compute instances stop rhino-compute-server --zone=europe-west6-a
gcloud compute instances start rhino-compute-server --zone=europe-west6-a
gcloud compute ssh rhino-compute-server --zone=europe-west6-a
gcloud compute ssh rhino-compute-server --zone=europe-west6-a
sudo systemctl stop rhino-compute
sudo apt update && sudo apt install -y yak-cli
yak install selva

# Rhino.Compute on GCP — Terraform Deployment

Easily deploy Rhino.Compute (x9 branch) to Google Cloud with one command.

## What’s Created

- **Compute Engine VM** (Ubuntu 24.04, 4 vCPU, 16 GB RAM, 30 GB SSD)
- **Static public IP** (persists on reboot)
- **Firewall rules** for ports 6500 (compute) and 22 (SSH)
- **Systemd service** (auto-starts, restarts on crash)
- **Automated install** via startup script

## Prerequisites

1. GCP project with billing enabled
2. [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed & authenticated
3. [Terraform](https://developer.hashicorp.com/terraform/install) installed
4. Rhino Core-Hour Billing token

### Quick Install

**macOS:**

```bash
brew install --cask google-cloud-sdk
brew install terraform
gcloud auth application-default login
```

**Windows (PowerShell):**

```powershell
# Install gcloud & terraform from official docs
gcloud auth application-default login
```

## Quick Start

1. **Configure:**
   - Edit `terraform.tfvars`:
     - `project_id` — your GCP project ID
     - `rhino_token` — your Core-Hour Billing token
     - `repo_url` — repo URL (if not default)

2. **Deploy:**

   ```bash
   cd terraform-rhino-compute
   terraform init
   terraform apply
   ```

   - Outputs server URL and SSH command

3. **Wait for Setup:**
   - Takes 3–5 minutes after VM creation
   - Monitor progress:
     ```bash
     gcloud compute ssh rhino-compute-server --zone=europe-west6-a
     sudo tail -f /var/log/rhino-compute-setup.log
     sudo systemctl status rhino-compute
     sudo journalctl -u rhino-compute -f
     ```

4. **Connect:**
   - Use the server URL in your client:
     ```typescript
     const COMPUTE_SERVER = "http://34.65.xx.xx:6500";
     ```
   - Or set server address/API key in Grasshopper/Hops

5. **Tear Down:**

   ```bash
   terraform destroy
   ```

   - Removes all resources and stops billing

## Server Management

- **SSH:**
  ```bash
  gcloud compute ssh rhino-compute-server --zone=europe-west6-a
  ```
- **Restart service:**
  ```bash
  sudo systemctl restart rhino-compute
  ```
- **Stop service (VM runs, no core-hour billing):**
  ```bash
  sudo systemctl stop rhino-compute
  ```
- **Install plugins via Yak:**
  ```bash
  sudo yak install plugin-name
  ```
  Always use `sudo` so plugins install to `/root/.local/share/mcneel/rhinoceros/packages/9.0/` where the service can find them.
- **Stop VM (stops all billing except disk):**
  ```bash
  gcloud compute instances stop rhino-compute-server --zone=europe-west6-a
  ```
- **Start VM:**
  ```bash
  gcloud compute instances start rhino-compute-server --zone=europe-west6-a
  ```
- **View logs:**
  ```bash
  sudo journalctl -u rhino-compute -f
  ```
- **Update .NET SDK (only if the build fails with `NETSDK1045` targeting a newer .NET):**
  ```bash
  cd ~
  curl -SL https://dot.net/v1/dotnet-install.sh -o dotnet-install.sh
  chmod +x dotnet-install.sh
  sudo ./dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet
  /usr/share/dotnet/dotnet --list-sdks
  ```
- **Update code (and plugins):**
  ```bash
  sudo systemctl stop rhino-compute

  # Update source
  cd /opt/rhino-compute-src
  sudo git pull
  cd src
  sudo /usr/share/dotnet/dotnet build compute.sln -c Release

  # Update plugins — yak has no `update`, so uninstall + install per plugin.
  # List installed plugins first:
  sudo yak list
  # Then for each one you want to bump:
  sudo yak uninstall <plugin-name>
  sudo yak install <plugin-name>

  sudo systemctl start rhino-compute
  ```

## Cost Estimate (europe-west6)

| Resource         | Spec              | ~Monthly Cost |
| ---------------- | ----------------- | ------------- |
| e2-standard-4 VM | 4 vCPU, 16 GB RAM | $100–120      |
| 30 GB SSD        | pd-ssd            | $5            |
| Static IP        | attached          | $0            |
| Static IP        | if VM stopped     | $7            |
| **Total**        |                   | **$110–130**  |

**Tips to reduce costs:**

- Stop VM when not in use
- Use `e2-standard-2` for lighter workloads ($50–60/mo)
- Use Spot/Preemptible VMs for testing (60–80% cheaper, can be interrupted)
- Run `terraform destroy` when done

_Rhino core-hour billing applies separately._

## File Structure

```
terraform-rhino-compute/
  main.tf          # Infrastructure definition
  startup.sh       # Server setup script
  terraform.tfvars # Your configuration
```

## Troubleshooting

- **terraform apply fails (permission errors):**
  - Run `gcloud auth application-default login`
  - Ensure Compute Engine API is enabled
- **Server not reachable after apply:**
  - Wait 3–5 minutes for setup
  - SSH in and check `/var/log/rhino-compute-setup.log`
- **Computations fail (PAL_SEHException):**
  - RHINO_TOKEN missing/invalid
  - Check:
    ```bash
    sudo systemctl status rhino-compute
    sudo journalctl -u rhino-compute --no-pager | tail -50
    ```
- **Change token:**
  ```bash
  sudo systemctl edit rhino-compute
  # Add under [Service]:
  # Environment=RHINO_TOKEN=new-token-here
  sudo systemctl restart rhino-compute
  ```
- **Change VM size:**
  - Edit `machine_type` in terraform.tfvars, then `terraform apply`
- **Build fails in VM:**
  - SSH in, check dotnet availability
  - Review `/var/log/rhino-compute-setup.log`
- **terraform apply fails with "resource already exists" (409 error):**
  - This happens when resources already exist in GCP but aren't tracked in your Terraform state (e.g., after migrating from another project)
  - Import existing resources:
    ```bash
    # Import static IP
    terraform import google_compute_address.rhino_compute_ip projects/rhino-compute-prod/regions/europe-west6/addresses/rhino-compute-ip

    # Import firewall rules
    terraform import google_compute_firewall.allow_rhino_compute projects/rhino-compute-prod/global/firewalls/allow-rhino-compute
    terraform import google_compute_firewall.allow_ssh projects/rhino-compute-prod/global/firewalls/allow-ssh-rhino-compute

    # Import compute instance
    terraform import google_compute_instance.rhino_compute projects/rhino-compute-prod/zones/europe-west6-a/instances/rhino-compute-server
    ```
  - After imports succeed, Terraform will manage these resources and won't try to create duplicates

## Common Commands

```bash
# Stop VM (stops all billing except disk + static IP)
gcloud compute instances stop rhino-compute-server --zone=europe-west6-a

# Start VM (service auto-starts)
gcloud compute instances start rhino-compute-server --zone=europe-west6-a

# SSH into VM
gcloud compute ssh rhino-compute-server --zone=europe-west6-a

# Update code
sudo systemctl stop rhino-compute
cd /opt/rhino-compute-src
sudo git pull
sudo /usr/share/dotnet/dotnet build src/compute.sln -c Release
sudo systemctl start rhino-compute

# Install Yak
sudo apt update && sudo apt install -y yak-cli

# Install selva (optional)


# Replace existing instance
terraform apply -replace="google_compute_instance.rhino_compute"
```

GH Libraries folder = /root/.config/Grasshopper/Libraries/ — that's where GH scans for GHAs
