# Vakili_P16_FPGA

This directory contains everything needed to program and test the 16-lane
Vakili MNIST accelerator on a Digilent Nexys A7-100T.

## First-time setup

Install:

- AMD Vivado or Vivado Lab Edition with the Digilent cable drivers
- Python 3
- A wired Ethernet adapter

Open a terminal in this directory and run:

```powershell
.\SETUP.cmd
```

Configure the wired adapter as:

```text
IP address: 192.168.7.1
Subnet mask: 255.255.255.0
```

For the most reliable connection, open Administrator PowerShell, find the
adapter index, and add the board address:

```powershell
Get-NetAdapter

New-NetNeighbor -InterfaceIndex <INDEX> -IPAddress 192.168.7.2 `
  -LinkLayerAddress "02-00-00-00-07-02" -State Permanent
```

## Run the Vakili model

1. Connect the FPGA by USB and Ethernet and turn it on.
2. Open Vivado Hardware Manager and program:

   ```text
   bitstreams\Vakili_P16_Ethernet.bit
   ```

3. Run:

   ```powershell
   .\RUN_MNIST_TEST.cmd
   ```

That single command checks the Ethernet connection, uploads the model
parameters, downloads MNIST if necessary, and evaluates all 10,000 test images.

## Run the exact-multiplier comparison

Program:

```text
bitstreams\Exact_P16_Ethernet.bit
```

Then run:

```powershell
.\RUN_EXACT_MNIST_TEST.cmd
```

## Connection check

To test only the Ethernet connection:

```powershell
.\TEST_CONNECTION.cmd
```

## Directory contents

- `bitstreams`: FPGA images to program in Vivado
- `models`: parameters loaded automatically by the run commands
- `host`: Ethernet communication and reference-model code
- `reports`: resource comparisons, timing reports, and routed core checkpoints
- `source`: optional HLS/FPGA source files; not required to program or test the board
- `PACKAGE_MANIFEST.json`: file sizes and SHA-256 checksums

The core-only `.dcp` files under `reports` are resource-characterization
checkpoints, not programmable FPGA images.
