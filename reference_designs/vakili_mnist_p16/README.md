# Vakili MNIST P16 reference design

This directory contains the deployable `784-64-32-10` MNIST classifier used on
the Nexys A7-100T. The classifier's core uses sixteen parallel signed 8-bit approximate
multipliers and returns ten signed 32-bit logits. Parameters, images and logits
are transferred over UDP through the board's Ethernet interface.

## Layout

```text
hls/             Vitis HLS inference core
rtl/             FPGA wrapper, memories and UDP/RMII endpoint
constraints/     Nexys A7-100T pin and clock constraints
model/           Frozen INT8 weights and INT32 biases
host.py          Parameter loader and MNIST board test
build_hls.tcl    HLS synthesis
build_fpga.tcl   Vivado implementation and bitstream generation
```

The design targets `xc7a100tcsg324-1` at 100 MHz. Its network settings are:

```text
FPGA address: 192.168.7.2
UDP port:     5005
FPGA MAC:     02:00:00:00:07:02
Host address: 192.168.7.1/24
```

## Build

Run Vitis HLS first:

```text
vitis_hls -f build_hls.tcl
```

Then build the FPGA image:

```text
vivado -mode batch -source build_fpga.tcl
```

The bitstream is written to `build/vakili_mnist_p16.bit`. Vivado utilization
and timing reports are written under `build/reports/`.

## Host setup

Install the Python dependencies:

```text
python -m pip install -r requirements.txt
```

Configure the directly connected host adapter as `192.168.7.1/24`. If dynamic
ARP is unreliable, add a permanent neighbor entry mapping
`192.168.7.2` to `02:00:00:00:07:02`

Example (powershell):
```text
New-NetNeighbor `
   -InterfaceIndex 9 `
   -IPAddress 192.168.7.2 `
   -LinkLayerAddress "02-00-00-00-07-02" `
   -State Permanent
```

After programming the FPGA, check the link:

```text
python host.py ping
```

Load the frozen parameters and evaluate the MNIST test set:

```text
python host.py run --download --count 10000 --progress 100
```

Parameter loading and evaluation may also be run separately with the `load`
and `evaluate` commands. Use `python host.py --help` for network options.

## Model

The parameter file contains `w1`, `w2`, `w3`, `b1`, `b2` and `b3`. Inputs
are scaled from unsigned pixels to signed INT8 values in the range 0 through
to 127. Hidden accumulators use arithmetic right shifts of 9 bits followed by
an ReLU and saturation at 127. The frozen Vakili MNIST model was benchmarked at 
an accuracy of 98.07% (simulation).
