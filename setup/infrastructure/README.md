# Rhino.Compute on GCP — Terraform Deployment

One-command deployment of Rhino.Compute (x9 branch) to Google Cloud.

## What This Creates

- **Compute Engine VM** (Ubuntu 24.04, 4 vCPU, 16 GB RAM, 30 GB SSD)
- **Static public IP** (doesn't change on reboot)
- **Firewall rules** for port 6500 (compute server) and 22 (SSH)
- **Systemd service** that auto-starts on boot and restarts on crash
- Everything installed automatically via startup script

## Prerequisites

1. **GCP account** with a project and billing enabled
2. **gcloud CLI** installed and authenticated
3. **Terraform** installed
4. **Rhino Core-Hour Billing token**

### Install on macOS

```bash
brew install --cask google-cloud-sdk
brew install terraform
gcloud auth application-default login
```

### Install on Windows (PowerShell)

```powershell
# Install gcloud: https://cloud.google.com/sdk/docs/install
# Install terraform: https://developer.hashicorp.com/terraform/install
gcloud auth application-default login
```

## Quick Start

### 1. Configure

Edit `terraform.tfvars` and fill in:

- `project_id` — your GCP project ID
- `rhino_token` — your Core-Hour Billing token
- `repo_url` — the repo URL (if different from default)

### 2. Deploy

```bash
cd terraform-rhino-compute
terraform init       # one-time setup, downloads the GCP provider
terraform apply      # creates everything, type "yes" to confirm
```

Terraform will output:

- The **server URL** (e.g. `http://34.65.xx.xx:6500`)
- The **SSH command** to access the server

### 3. Wait for Setup

The VM takes about 3-5 minutes to finish installing everything after
creation. You can monitor progress by SSHing in and checking the log:

```bash
# SSH into the server
gcloud compute ssh rhino-compute-server --zone=europe-west6-a

# Watch the setup log
sudo tail -f /var/log/rhino-compute-setup.log

# Check if the service is running
sudo systemctl status rhino-compute

# View live server logs
sudo journalctl -u rhino-compute -f
```

### 4. Connect

Once setup is complete, point your client to the server URL:

```typescript
const COMPUTE_SERVER = "http://34.65.xx.xx:6500"; // use your actual IP
```

Or from Grasshopper/Hops, set the server address and API key.

### 5. Tear Down

```bash
terraform destroy    # removes everything, type "yes" to confirm
```

This deletes the VM, static IP, and firewall rules. You stop paying immediately.

## Managing the Server

**SSH into the server:**

```bash
gcloud compute ssh rhino-compute-server --zone=europe-west6-a
```

**Restart the service:**

```bash
sudo systemctl restart rhino-compute
```

**Stop the service (VM stays running, stops billing core-hours):**

```bash
sudo systemctl stop rhino-compute
```

**Stop the VM entirely (stops all billing except disk storage):**

```bash
gcloud compute instances stop rhino-compute-server --zone=europe-west6-a
```

**Start the VM again (service auto-starts):**

```bash
gcloud compute instances start rhino-compute-server --zone=europe-west6-a
```

**View logs:**

```bash
sudo journalctl -u rhino-compute -f
```

**Pull latest code and rebuild:**

```bash
sudo systemctl stop rhino-compute
cd /opt/rhino-compute-src
sudo git pull
cd src
sudo dotnet build compute.sln -c Release
sudo systemctl start rhino-compute
```

## Cost Estimate

Running in europe-west6 (Zurich):

| Resource            | Spec              | ~Monthly Cost |
| ------------------- | ----------------- | ------------- |
| e2-standard-4 VM    | 4 vCPU, 16 GB RAM | ~$100-120     |
| 30 GB SSD           | pd-ssd            | ~$5           |
| Static IP           | (while attached)  | $0            |
| Static IP           | (if VM stopped)   | ~$7           |
| **Total (running)** |                   | **~$110-130** |

To reduce costs:

- Stop the VM when not in use (`gcloud compute instances stop ...`)
- Use `e2-standard-2` (2 vCPU, 8 GB) for lighter workloads (~$50-60/mo)
- Use Spot/Preemptible VMs for testing (~60-80% cheaper but can be interrupted)
- `terraform destroy` when done to stop all charges

Plus Rhino core-hour billing charges from McNeel based on usage.

## File Structure

```
terraform-rhino-compute/
  main.tf             # Infrastructure definition
  startup.sh          # Server setup script (runs on first boot)
  terraform.tfvars    # Your configuration (edit this)
```

## Troubleshooting

**"terraform apply" fails with permission errors:**
Make sure you ran `gcloud auth application-default login` and that your
GCP project has the Compute Engine API enabled.

**Server not reachable after terraform apply:**
The startup script takes 3-5 minutes. SSH in and check
`/var/log/rhino-compute-setup.log` for progress.

**Computations fail (PAL_SEHException):**
The RHINO_TOKEN is missing or invalid. Check with:

```bash
sudo systemctl status rhino-compute
sudo journalctl -u rhino-compute --no-pager | tail -50
```

**Need to change the token:**

```bash
sudo systemctl edit rhino-compute
# Add under [Service]:
# Environment=RHINO_TOKEN=new-token-here
sudo systemctl restart rhino-compute
```

**Want to change VM size:**
Update `machine_type` in terraform.tfvars and run `terraform apply`.

**Build fails inside the VM:**
SSH in and check if dotnet is available. The startup script logs
everything to `/var/log/rhino-compute-setup.log`.

#Comands

# Stop the VM entirely (stops all billing except disk + static IP)

gcloud compute instances stop rhino-compute-server --zone=europe-west6-a

# Start it again (service auto-starts)

gcloud compute instances start rhino-compute-server --zone=europe-west6-a

gcloud compute ssh rhino-compute-server --zone=europe-west6-a

# Update

gcloud compute ssh rhino-compute-server --zone=europe-west6-a

sudo systemctl stop rhino-compute
cd /opt/rhino-compute-src
sudo git pull
cd src
sudo /usr/share/dotnet/dotnet build src/compute.sln -c Release
sudo systemctl start rhino-compute

# Istall Yak

sudo apt update && sudo apt install -y yak-cli

for using selva install selva

yak install selva

## replace existing

terraform apply -replace="google_compute_instance.rhino_compute"
