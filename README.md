# cx8_multiplane_manager.sh

Unified **ConnectX-8 SMI manager + OpenSM launcher** for automating:

- Creation and cleanup of SMI devices (`smiN`) for ConnectX-8 cards
- Launching `opensm` per SMI Port GUID
- Verifying link states for SMI ports
- Logging all phases for debug-friendly operation

This tool is designed for IB/RDMA lab environments where you frequently bring up and tear down fabric topologies on Mellanox/NVIDIA **ConnectX-8** hardware and want a repeatable, traceable workflow.

---

## Description

`cx8_multiplane_manager.sh` is a single Bash tool that combines and extends two common workflows:

1. **SMI Manager**  
   - Detects all ConnectX-8 devices from `mst status -v`  
   - Ensures **one SMI device per ConnectX-8 mlx5_N**, named `smiN`  
   - Supports deletion / recreation of existing SMI devices  
   - Prints a status table of SMI devices (parent + per-port `ibstat` state)

2. **OpenSM Runner**  
   - For each SMI device, finds its Port GUID and launches **one `opensm` daemon per GUID**  
   - Verifies that all SMI ports are in **Active** state (configurable strictness)  
   - Writes OpenSM logs to a dedicated, timestamped directory

On top of that, this combined version adds **structured logging** for all phases and decisions so you can easily debug issues when something goes wrong.

---

## Key Features

### SMI Management

- Auto-detect **ConnectX-8** parents from `mst status -v` (e.g. `mlx5_0`, `mlx5_1`, ...)  
- Auto-create canonical **SMI devices** `smiN` for each parent `mlx5_N`:
  ```bash
  rdma dev add smiN type SMI parent mlx5_N
  ```
- Optional cleanup of existing SMI devices:
  - Delete **all** SMI devices (`--recreate-smi`)
  - Interactively delete **selected** SMI devices (`--select-smi`)
- Status table (`--smi-status`) showing:
  - SMI name
  - Parent mlx5 device
  - Port states via `ibstat` (e.g. `P1:Active`, `P2:Down`, ...)

### OpenSM Management

- Automatically discover Port GUIDs via `ibstat smiN`
- Start `opensm -g <GUID> -rvo` **only if no existing process** is running for that GUID
- Verify all SMI ports are in `State: Active`
- Option to treat non-Active ports as warnings instead of errors (`--no-require-active`)

### Logging

All runs create a **timestamped log directory**:

```text
cx8_multiplane_manager_YYYYmmdd-HHMMSS/
  master.log          # All phases, decisions, and command results
  smi_assign.log      # Detailed ConnectX-8 → SMI mapping and creation
  opensm_smi_<GUID>.log  # One per OpenSM instance
```

- `master.log` – high-level view of the whole run, including:
  - Phase transitions
  - User choices (e.g., which SMIs were deleted)
  - Commands executed and their exit codes
- `smi_assign.log` – focused on **Phase B**:
  - Which ConnectX-8 parents were detected
  - For each parent, which SMI name was targeted
  - Whether the SMI already existed or had to be created
  - Any errors encountered while creating SMIs
- `opensm_smi_<GUID>.log` – raw OpenSM output for each GUID

This makes it easy to answer: _“Why is this SMI missing?”_, _“Why is port X not Active?”_, or _“What exactly did the script do during this run?”_.

---

## Requirements

- Linux environment with Mellanox/NVIDIA tools installed
- Root privileges (recommended)
- Tools:
  - `mst`
  - `rdma` (from Mellanox/NVIDIA iproute2)
  - `ibstat`
  - `opensm`
  - `ps`, `awk`, `grep`, `sort`, `nohup`

Make sure the **MST drivers** are started before running:

```bash
mst start
```

---

## Usage

```bash
sudo ./cx8_multiplane_manager.sh [OPTIONS]
```

### Options

#### SMI management

- `--dry-run`  
  Print all `rdma` / `opensm` commands but **do not execute** them.

- `--recreate-smi`  
  Delete **all existing SMI** devices, then recreate canonical `smiN` devices for ConnectX-8 parents.

- `--select-smi`  
  Interactively select SMI devices to delete (single/multiple/all); canonical `smiN` devices will then be recreated as needed.

- `--smi-status`  
  Print a status table of all **SMI devices** (not just ConnectX-8), showing:
  - SMI name
  - Parent mlx5 device
  - Port states via `ibstat`

#### OpenSM management

- `--run-opensm`  
  After SMI management, launch/verify OpenSM for each ConnectX-8 SMI (`smiN`).

- `--no-require-active`  
  By default, if any SMI port is **not Active**, the script returns a failure code.  
  With this flag, non-Active ports generate warnings only and do **not** cause a non-zero exit status.

#### Misc

- `-h`, `--help`  
  Show usage and built-in examples.

---

## Flow Overview

1. **Phase A – Discover Existing SMI Devices**
   - `rdma dev` → collect all `type smi` devices
   - Optionally:
     - Delete all (`--recreate-smi`)
     - Delete selected (`--select-smi`)
   - Optionally: `--smi-status` can show a status table.

2. **Phase B – ConnectX-8 Detection & SMI Creation**
   - Parse `mst status -v` for `ConnectX8*` devices with `mlx5_N` RDMA handles.
   - For each parent `mlx5_N`, ensure `smiN` exists:
     - If present: reuse it
     - If missing: create via `rdma dev add smiN type SMI parent mlx5_N`
   - Final list `SMIS=(smi0 smi1 ...)` represents all ConnectX-8 SMI devices.

3. **Phase C – OpenSM per SMI (optional)**
   - For each `smiX` in `SMIS`:
     - Get its Port GUID via `ibstat`
     - If no matching `opensm -g GUID` is running, start one
     - Discover ports and check `State: Active`
     - Honour `--no-require-active` for failure vs warning behavior

Throughout the run, detailed information is written to `master.log` and `smi_assign.log`.

---

## Example Commands

### 1. Basic: Ensure SMI devices for all ConnectX-8 cards

```bash
sudo ./cx8_smi_opensm_mgr.sh
```

### 2. Show SMI status only (no modification)

```bash
sudo ./cx8_smi_opensm_mgr.sh --smi-status
```

### 3. Recreate all SMIs and show status

```bash
sudo ./cx8_smi_opensm_mgr.sh --recreate-smi --smi-status
```

### 4. Interactively delete selected SMIs

```bash
sudo ./cx8_smi_opensm_mgr.sh --select-smi
```

### 5. Ensure SMIs and run OpenSM (strict Active requirement)

```bash
sudo ./cx8_smi_opensm_mgr.sh --run-opensm
```

### 6. Run OpenSM but allow non-Active ports (warning only)

```bash
sudo ./cx8_smi_opensm_mgr.sh --run-opensm --no-require-active
```

### 7. Full flow: recreate SMIs, run OpenSM, and show status

```bash
sudo ./cx8_smi_opensm_mgr.sh --recreate-smi --run-opensm --smi-status
```

### 8. Safe “dry run” scenario (no changes)

```bash
sudo ./cx8_smi_opensm_mgr.sh --recreate-smi --run-opensm --smi-status --dry-run
```

---

## Exit Codes

- `0` – All operations successful, including SMI creation and optional OpenSM checks.  
- Non-zero – Error or warning condition, such as:
  - Tools missing (`mst`, `rdma`, `ibstat`, `opensm`, ...)  
  - No ConnectX-8 parents found  
  - Failed to create SMI device(s)  
  - Failed to start OpenSM or ports not Active (unless `--no-require-active`)

---

## Notes & Best Practices

- Always ensure MST is running before use:
  ```bash
  mst start
  ```
- Recommended to **stop any manually started OpenSM instances** or at least verify which GUIDs they’re bound to, to avoid confusion.
- Use `--dry-run` on new systems or large clusters to preview actions before making changes.
- All runs are self-contained under `cx8_smi_opensm_mgr_YYYYmmdd-HHMMSS/` directories for easier troubleshooting and archiving.
