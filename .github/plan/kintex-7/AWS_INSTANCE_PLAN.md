# AWS EC2 Instance Plan — Vivado P&R for LLIU

**Purpose:** Run Vivado ML Standard synthesis + place-and-route for the LLIU
`xc7k160tffg676-2` target. The instance is kept alive across all timing-closure
iteration cycles, then terminated when WNS ≥ 0 on all `clk_300` paths.

---

## Prerequisites (Mac, before launching)

- AWS account with billing set up
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed and configured (`aws configure`)
- An EC2 key pair downloaded (`.pem` file, `chmod 400`)
- The repo pushed to GitHub (already done)
- VS Code with the **Remote - SSH** extension installed
  (`Ctrl+Shift+X` → search `Remote - SSH` → Install)

> **Recommended working method: VS Code Remote SSH**
> Connect VS Code directly to the EC2 instance. Copilot edits files and runs
> commands in the integrated terminal — everything executes on the instance where
> Vivado is installed. No `scp` or `git pull` needed between iterations:
>
> ```
> VS Code (macOS) ──SSH──▶ EC2 instance
>                           ├── edit constraints.xdc  ← Copilot does this
>                           ├── vivado -mode batch ... ← runs here natively
>                           └── syn/reports/timing.txt ← readable directly
> ```

---

## Step 1 — Subscribe to the FPGA Developer AMI

1. Go to **AWS Marketplace** → search `FPGA Developer AMI`
2. Click **Continue to Subscribe** → **Accept Terms** (free subscription; you pay only for EC2 compute)
3. Note the AMI ID for your chosen region (e.g. `us-east-1`)

> The FPGA Developer AMI ships with Vivado ML Standard pre-installed and
> pre-licensed for all standard 7-series parts including `xc7k160t`.
> No separate Vivado licence file is needed.

---

## Step 2 — Launch the instance

### Recommended instance type

| Need | Minimum | Recommended |
|------|---------|-------------|
| RAM | 16 GB | 32 GB |
| vCPU | 4 | 16 |
| Instance | `c5.2xlarge` | `c5.4xlarge` (spot) |
| Spot price (us-east-1) | ~$0.14/hr | ~$0.34/hr |

Use **spot pricing** — `vivado_impl.tcl` writes checkpoints after `place_design` and `phys_opt_design`, so a spot interruption during routing loses at most the routing phase (~1 hr), not the full run. If you prefer zero restart risk, use on-demand pricing (+~$0.50–1.00 total).

### Launch via AWS Console

1. EC2 → **Launch Instance**
2. **AMI**: select the FPGA Developer AMI (from Marketplace subscriptions)
3. **Instance type**: `c5.4xlarge`
4. **Key pair**: select your existing `.pem` key pair
5. **Storage**: set root volume to **120 GB gp3** (AMI base ~80 GB + Vivado runtime artefacts)
6. **Security group**: allow **SSH (port 22)** from your IP only — no other inbound rules
7. **Advanced → Purchasing option**: Request Spot Instance, set max price to on-demand rate
8. Launch

### Or via AWS CLI

```sh
# Replace <ami-id>, <key-name>, <sg-id>, <subnet-id> with your values
aws ec2 run-instances \
  --image-id <ami-id> \
  --instance-type c5.4xlarge \
  --key-name <key-name> \
  --security-group-ids <sg-id> \
  --subnet-id <subnet-id> \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":120,"VolumeType":"gp3"}}]' \
  --instance-market-options '{"MarketType":"spot"}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lliu-par}]'
```

Save the `InstanceId` from the output.

---

## Step 3 — Connect via VS Code Remote SSH

**3.1 — Get the public IP**

```sh
aws ec2 describe-instances --instance-ids <instance-id> \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

**3.2 — Add the instance to `~/.ssh/config`**

```
Host lliu-par
    HostName <public-ip>
    User ec2-user
    IdentityFile ~/Downloads/<key>.pem
```

**3.3 — Connect VS Code to the instance**

1. `Ctrl+Shift+P` → **Remote-SSH: Connect to Host** → `lliu-par`
2. VS Code reopens connected to the instance
3. **File → Open Folder** → select the cloned repo root (after Step 4)

From this point, all Copilot edits, terminal commands, and file reads happen
directly on the instance. No `scp` required during the iteration loop.

**3.4 — Locate and source Vivado (in the VS Code integrated terminal)**

```sh
# Locate the Vivado settings script (path varies by AMI version)
VIVADO_SETTINGS=$(find / -name "settings64.sh" -path "*/Vivado/*" 2>/dev/null | head -1)
echo "Found: $VIVADO_SETTINGS"
source "$VIVADO_SETTINGS"

# Verify
vivado -version
```

> Add the `source` line to `~/.bashrc` on the instance so it persists across
> reconnects: `echo "source $VIVADO_SETTINGS" >> ~/.bashrc`

---

## Step 4 — Clone repo and prepare sources

```sh
cd ~
git clone https://github.com/robtmadsen/low_latency_inference_unit.git
cd low_latency_inference_unit

# Populate the verilog-ethernet submodule (registered in .gitmodules)
git submodule update --init lib/verilog-ethernet
# Verify it populated correctly
ls lib/verilog-ethernet/rtl/*.v | wc -l   # expect ~98

# Create the reports output directory
mkdir -p syn/reports
```

---

## Step 5 — Run P&R (first attempt)

```sh
# Still inside tmux session 'par', from repo root
vivado -mode batch -source syn/vivado_impl.tcl \
       -tclargs ./lib/verilog-ethernet \
       2>&1 | tee syn/reports/vivado.log
```

Expected wall-clock time: **2–4 hours** on `c5.4xlarge`.

The VS Code integrated terminal stays connected while the run executes.
If the SSH connection drops mid-run, Vivado keeps running on the instance
(the process is not attached to your terminal). Reconnect via Remote SSH
and check progress:

```sh
tail -f syn/reports/vivado.log
```

---

## Step 6 — Check results and iterate

After P&R completes, check timing directly in the VS Code integrated terminal
(already connected to the instance — no file transfer needed):

```sh
grep "WNS" syn/reports/timing.txt | head -5
```

**Decision:**
- **WNS ≥ 0** on all `clk_300` paths → timing closed, proceed to Step 7
- **WNS < 0** → paste the output here; Copilot will diagnose the critical path
  and edit `syn/constraints.xdc` or `syn/vivado_impl.tcl` directly on the
  instance via the Remote SSH session, then rerun from Step 5 — no `git pull`
  or `scp` required

---

## Step 7 — Retrieve artefacts and terminate

Once WNS ≥ 0:

```sh
# From your Mac — copy all reports and the routed checkpoint
scp -i ~/Downloads/<key>.pem -r \
    ec2-user@<public-ip>:low_latency_inference_unit/syn/reports/ \
    syn/reports/

scp -i ~/Downloads/<key>.pem \
    ec2-user@<public-ip>:low_latency_inference_unit/syn/lliu_routed.dcp \
    syn/lliu_routed.dcp

scp -i ~/Downloads/<key>.pem \
    ec2-user@<public-ip>:low_latency_inference_unit/syn/lliu.bit \
    syn/lliu.bit
```

**Terminate the instance immediately after retrieval:**

```sh
aws ec2 terminate-instances --instance-ids <instance-id>
```

Verify termination in the EC2 console to confirm billing stops.

---

## Cost estimate

| Scenario | Duration | Cost (spot `c5.4xlarge`, ~$0.34/hr) |
|----------|----------|--------------------------------------|
| First run closes timing | ~3 hrs | ~$1.00 |
| One tuning iteration | ~6 hrs | ~$2.00 |
| Two tuning iterations | ~10 hrs | ~$3.40 |

---

## Completion Checklist

| Step | Item | Status |
|------|------|--------|
| 1 | Subscribed to FPGA Developer AMI | ⬜ |
| 2 | `c5.4xlarge` spot instance launched, 120 GB gp3 | ⬜ |
| 3 | SSH connected, tmux session started, Vivado sourced | ⬜ |
| 4 | Repo cloned, submodule populated | ⬜ |
| 5 | First P&R run completed | ⬜ |
| 6 | Timing closed (WNS ≥ 0 on all `clk_300` paths) | ⬜ |
| 7 | Reports + `lliu_routed.dcp` + `lliu.bit` retrieved | ⬜ |
| 7 | Instance terminated | ⬜ |
