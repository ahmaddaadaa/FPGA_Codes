# FPGA UART Communication Interface

This document describes the UART protocol used for communication between the PC backend and the FPGA-based MLP accelerator.

The protocol supports:

- Loading model weights
- Loading model biases
- Loading input feature vectors
- Starting inference
- Polling accelerator status
- Reading output logits

---

## 1. UART Settings

The FPGA communicates with the PC using the Nexys A7 USB-UART interface.

Use the following serial settings:

| Setting | Value |
|---|---|
| Baud rate | `115200` |
| Data bits | `8` |
| Parity | `None` |
| Stop bits | `1` |
| Flow control | `None` |

This is standard `115200 8N1`.

Example Python setup:

```python
import serial

ser = serial.Serial("COM8", baudrate=115200, timeout=5.0)
```

The COM port may differ between machines.

---

## 2. Packet Format

All communication uses binary packets.

### Request Packet: PC to FPGA

```text
+------------+---------+--------+--------+--------+--------+-------------+----------+
| Start byte | Command | Addr_H | Addr_L | Len_H  | Len_L  | Payload     | Checksum |
+------------+---------+--------+--------+--------+--------+-------------+----------+
| 0xAA       | 1 byte  | 1 byte | 1 byte | 1 byte | 1 byte | Len bytes   | 1 byte   |
+------------+---------+--------+--------+--------+--------+-------------+----------+
```

### Response Packet: FPGA to PC

```text
+------------+---------+--------+--------+--------+--------+-------------+----------+
| Start byte | Command | Addr_H | Addr_L | Len_H  | Len_L  | Payload     | Checksum |
+------------+---------+--------+--------+--------+--------+-------------+----------+
| 0xAA       | 1 byte  | 1 byte | 1 byte | 1 byte | 1 byte | Len bytes   | 1 byte   |
+------------+---------+--------+--------+--------+--------+-------------+----------+
```

The start byte is always:

```text
0xAA
```

The address is big-endian:

```text
address = (Addr_H << 8) | Addr_L
```

The length is big-endian:

```text
length = (Len_H << 8) | Len_L
```

The checksum is:

```text
checksum = sum(all previous packet bytes) & 0xFF
```

The checksum includes:

```text
Start byte
Command
Addr_H
Addr_L
Len_H
Len_L
Payload bytes
```

The checksum does **not** include the checksum byte itself.

---

## 3. Command Summary

| Command | Hex | Direction | Payload | Description |
|---|---:|---|---|---|
| `WRITE_WEIGHT` | `0x01` | PC → FPGA | signed int8 array | Write model weights |
| `WRITE_BIAS` | `0x02` | PC → FPGA | signed int32 array | Write model biases |
| `WRITE_INPUT` | `0x03` | PC → FPGA | signed int8 array | Write input feature vector |
| `START` | `0x04` | PC → FPGA | none | Start inference |
| `READ_OUTPUT` | `0x05` | PC → FPGA | none | Read output logits |
| `STATUS` | `0x06` | PC → FPGA | none | Read accelerator status |
| `ACK` | `0xF0` | FPGA → PC | 1 byte | Command accepted |
| `OUTPUT_DATA` | `0x81` | FPGA → PC | signed int32 array | Output vector/logits |
| `STATUS_DATA` | `0x86` | FPGA → PC | 1 byte | Busy/done status |
| `ERROR` | `0xFF` | FPGA → PC | 1 byte | Error response |

---

## 4. Data Formats

### Weights

Weights are signed 8-bit integers.

```text
int8
range: -128 to 127
```

Python packing:

```python
payload = struct.pack(f"<{len(weights)}b", *weights)
```

---

### Inputs

Input feature values are signed 8-bit integers.

```text
int8
range: -128 to 127
```

Python packing:

```python
payload = struct.pack(f"<{len(input_values)}b", *input_values)
```

---

### Biases

Biases are signed 32-bit integers.

```text
int32
little-endian
```

Python packing:

```python
payload = struct.pack(f"<{len(biases)}i", *biases)
```

---

### Outputs

Outputs are signed 32-bit integers.

```text
int32
little-endian
```

For a two-output classifier:

```text
output[0] = class 0 score
output[1] = class 1 score
```

The predicted class can be computed on the PC:

```python
predicted_class = 0 if output0 > output1 else 1
```

No softmax is required on the FPGA.

---

## 5. Response Packet Types

### ACK Response

If a command succeeds, the FPGA returns an `ACK`.

```text
[AA][F0][00][00][00][01][original_command][checksum]
```

Payload:

```text
payload[0] = original command byte
```

Example ACK for `START`, command `0x04`:

```text
AA F0 00 00 00 01 04 checksum
```

---

### ERROR Response

If a command fails, the FPGA returns an `ERROR`.

```text
[AA][FF][00][00][00][01][error_code][checksum]
```

Current error codes:

| Error Code | Meaning |
|---:|---|
| `0x01` | Accelerator busy |
| `0x02` | Unknown or invalid command |
| `0x03` | Bad address or length |

---

### STATUS_DATA Response

Command:

```text
0x06 = STATUS
```

Response:

```text
[AA][86][00][00][00][01][status_byte][checksum]
```

Status byte layout:

```text
bit 0 = busy
bit 1 = done
bits 7:2 = unused
```

| Status Byte | Meaning |
|---:|---|
| `0x00` | Not busy, not done |
| `0x01` | Busy |
| `0x02` | Done |
| `0x03` | Busy and done; should generally not occur |

Python decode:

```python
busy = bool(status & 0x01)
done = bool(status & 0x02)
```

---

### OUTPUT_DATA Response

Command:

```text
0x05 = READ_OUTPUT
```

For a two-output model, the response is:

```text
[AA][81][00][00][00][08][out0_0][out0_1][out0_2][out0_3][out1_0][out1_1][out1_2][out1_3][checksum]
```

Each output is little-endian signed int32.

Python decode for two outputs:

```python
out0, out1 = struct.unpack("<ii", payload)
```

For a final model with `NUM_OUTPUTS` outputs, the payload length should be:

```text
4 * NUM_OUTPUTS bytes
```

Python decode:

```python
outputs = struct.unpack(f"<{num_outputs}i", payload)
```

---

## 6. Command Details

### 6.1 WRITE_WEIGHT

Command byte:

```text
0x01
```

Purpose:

```text
Write signed int8 weights into FPGA weight memory.
```

Packet:

```text
[AA][01][Addr_H][Addr_L][Len_H][Len_L][weight bytes...][checksum]
```

The address is the starting weight index, not a byte address.

For the current small test model:

```text
NUM_WEIGHTS = 12
```

Current weight memory layout:

```text
weights[0:4]    = W1 hidden neuron 0
weights[4:8]    = W1 hidden neuron 1
weights[8:10]   = W2 output neuron 0
weights[10:12]  = W2 output neuron 1
```

General layout:

```text
W1 address = hidden_index * NUM_INPUTS + input_index

W2_BASE = NUM_INPUTS * NUM_HIDDEN

W2 address = W2_BASE + output_index * NUM_HIDDEN + hidden_index
```

Example:

```python
weights = [
    1, 1, 1, 1,
    2, 0, -1, 1,
    1, -1,
    2, 1,
]

payload = struct.pack("<12b", *weights)
```

---

### 6.2 WRITE_BIAS

Command byte:

```text
0x02
```

Purpose:

```text
Write signed int32 biases into FPGA bias memory.
```

Packet:

```text
[AA][02][Addr_H][Addr_L][Len_H][Len_L][bias bytes...][checksum]
```

The address is the starting bias index, not a byte address.

Bias values are little-endian signed int32.

For the current small test model:

```text
NUM_BIASES = 4
```

Current bias layout:

```text
biases[0] = hidden neuron 0 bias
biases[1] = hidden neuron 1 bias
biases[2] = output neuron 0 bias
biases[3] = output neuron 1 bias
```

General layout:

```text
hidden bias address = hidden_index

output bias address = NUM_HIDDEN + output_index
```

Example:

```python
biases = [0, 0, 0, 0]
payload = struct.pack("<4i", *biases)
```

The length is in bytes. For four int32 biases:

```text
length = 16
```

---

### 6.3 WRITE_INPUT

Command byte:

```text
0x03
```

Purpose:

```text
Write signed int8 input features into FPGA input memory.
```

Packet:

```text
[AA][03][Addr_H][Addr_L][Len_H][Len_L][input bytes...][checksum]
```

The address is the starting input feature index.

For the current small test model:

```text
NUM_INPUTS = 4
```

Example:

```python
input_values = [1, 2, 3, 4]
payload = struct.pack("<4b", *input_values)
```

---

### 6.4 START

Command byte:

```text
0x04
```

Purpose:

```text
Start one inference run.
```

Packet:

```text
[AA][04][00][00][00][00][checksum]
```

No payload.

Expected response:

```text
ACK
```

If the accelerator is already busy, the FPGA returns:

```text
ERROR, error code 0x01
```

---

### 6.5 STATUS

Command byte:

```text
0x06
```

Purpose:

```text
Check whether inference is still running.
```

Packet:

```text
[AA][06][00][00][00][00][checksum]
```

Expected response:

```text
STATUS_DATA
```

Typical polling loop:

```python
while True:
    busy, done = read_status()
    if done:
        break
```

---

### 6.6 READ_OUTPUT

Command byte:

```text
0x05
```

Purpose:

```text
Read output logits after inference is complete.
```

Packet:

```text
[AA][05][00][00][00][00][checksum]
```

Expected response:

```text
OUTPUT_DATA
```

For the current two-output model:

```python
out0, out1 = struct.unpack("<ii", payload)
```

---

## 7. Recommended Transaction Sequence

The PC should use this sequence:

```text
1. Open COM port.

2. Send WRITE_WEIGHT.
   Wait for ACK.

3. Send WRITE_BIAS.
   Wait for ACK.

4. For each input sample:

   a. Send WRITE_INPUT.
      Wait for ACK.

   b. Send START.
      Wait for ACK.

   c. Poll STATUS until done = 1.

   d. Send READ_OUTPUT.
      Decode output logits.

5. Repeat step 4 for additional samples.
```

Do not reload weights and biases for every sample unless the model changes.

Recommended final flow:

```text
load model once

for each test sample:
    load input vector
    start inference
    poll done
    read output
```

---

## 8. Example Full Exchange

Suppose the PC wants to run inference with:

```text
input = [1, 2, 3, 4]
```

### Step 1: WRITE_INPUT

Payload:

```text
01 02 03 04
```

Packet:

```text
AA 03 00 00 00 04 01 02 03 04 C8
```

Explanation:

```text
AA             start byte
03             WRITE_INPUT
00 00          address = 0
00 04          length = 4
01 02 03 04    payload
C8             checksum
```

Expected response:

```text
AA F0 00 00 00 01 03 checksum
```

---

### Step 2: START

Packet:

```text
AA 04 00 00 00 00 checksum
```

Expected response:

```text
AA F0 00 00 00 01 04 checksum
```

---

### Step 3: STATUS

Packet:

```text
AA 06 00 00 00 00 checksum
```

Response when done:

```text
AA 86 00 00 00 01 02 checksum
```

The payload `0x02` means:

```text
busy = 0
done = 1
```

---

### Step 4: READ_OUTPUT

Packet:

```text
AA 05 00 00 00 00 checksum
```

Response for exact test output `[7, 23]`:

```text
AA 81 00 00 00 08 07 00 00 00 17 00 00 00 checksum
```

Payload:

```text
07 00 00 00 = 7
17 00 00 00 = 23
```

---

## 9. Python Reference Helpers

```python
import struct
import time

START_BYTE = 0xAA

CMD_WRITE_WEIGHT = 0x01
CMD_WRITE_BIAS = 0x02
CMD_WRITE_INPUT = 0x03
CMD_START = 0x04
CMD_READ_OUTPUT = 0x05
CMD_STATUS = 0x06

CMD_ACK = 0xF0
CMD_OUTPUT_DATA = 0x81
CMD_STATUS_DATA = 0x86
CMD_ERROR = 0xFF

INTER_PACKET_DELAY = 0.02


def checksum(data: bytes) -> int:
    return sum(data) & 0xFF


def make_packet(cmd: int, addr: int = 0, payload: bytes = b"") -> bytes:
    length = len(payload)

    packet = bytes([
        START_BYTE,
        cmd & 0xFF,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
        (length >> 8) & 0xFF,
        length & 0xFF,
    ]) + payload

    return packet + bytes([checksum(packet)])


def send_packet(ser, cmd: int, addr: int = 0, payload: bytes = b""):
    packet = make_packet(cmd, addr, payload)
    ser.write(packet)
    ser.flush()
    time.sleep(INTER_PACKET_DELAY)


def read_packet(ser):
    while True:
        b = ser.read(1)
        if len(b) == 0:
            raise TimeoutError("Timed out waiting for start byte")
        if b[0] == START_BYTE:
            break

    header_rest = ser.read(5)
    if len(header_rest) != 5:
        raise TimeoutError("Timed out reading packet header")

    cmd = header_rest[0]
    addr = (header_rest[1] << 8) | header_rest[2]
    length = (header_rest[3] << 8) | header_rest[4]

    payload = ser.read(length)
    if len(payload) != length:
        raise TimeoutError("Timed out reading packet payload")

    rx_checksum_raw = ser.read(1)
    if len(rx_checksum_raw) != 1:
        raise TimeoutError("Timed out reading checksum")

    rx_checksum = rx_checksum_raw[0]
    expected = checksum(bytes([START_BYTE]) + header_rest + payload)

    if rx_checksum != expected:
        raise ValueError(
            f"Bad checksum: received 0x{rx_checksum:02X}, "
            f"expected 0x{expected:02X}"
        )

    return cmd, addr, payload


def expect_ack(ser, expected_cmd: int):
    cmd, addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        raise RuntimeError(f"FPGA returned ERROR code: {payload.hex()}")

    if cmd != CMD_ACK:
        raise RuntimeError(f"Expected ACK, got 0x{cmd:02X}")

    if len(payload) != 1 or payload[0] != expected_cmd:
        raise RuntimeError(
            f"Bad ACK payload: got {payload.hex()}, expected {expected_cmd:02X}"
        )
```

---

## 10. Higher-Level Python API

```python
def write_weights(ser, weights):
    payload = struct.pack(f"<{len(weights)}b", *weights)
    send_packet(ser, CMD_WRITE_WEIGHT, addr=0, payload=payload)
    expect_ack(ser, CMD_WRITE_WEIGHT)


def write_biases(ser, biases):
    payload = struct.pack(f"<{len(biases)}i", *biases)
    send_packet(ser, CMD_WRITE_BIAS, addr=0, payload=payload)
    expect_ack(ser, CMD_WRITE_BIAS)


def write_input_vector(ser, input_values):
    payload = struct.pack(f"<{len(input_values)}b", *input_values)
    send_packet(ser, CMD_WRITE_INPUT, addr=0, payload=payload)
    expect_ack(ser, CMD_WRITE_INPUT)


def start_inference(ser):
    send_packet(ser, CMD_START)
    expect_ack(ser, CMD_START)


def read_status(ser):
    send_packet(ser, CMD_STATUS)
    cmd, addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        raise RuntimeError(f"FPGA returned ERROR code: {payload.hex()}")

    if cmd != CMD_STATUS_DATA:
        raise RuntimeError(f"Expected STATUS_DATA, got 0x{cmd:02X}")

    if len(payload) != 1:
        raise RuntimeError(f"Expected 1 status byte, got {len(payload)}")

    status = payload[0]

    busy = bool(status & 0x01)
    done = bool(status & 0x02)

    return busy, done


def read_outputs(ser, num_outputs):
    send_packet(ser, CMD_READ_OUTPUT)
    cmd, addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        raise RuntimeError(f"FPGA returned ERROR code: {payload.hex()}")

    if cmd != CMD_OUTPUT_DATA:
        raise RuntimeError(f"Expected OUTPUT_DATA, got 0x{cmd:02X}")

    expected_len = 4 * num_outputs

    if len(payload) != expected_len:
        raise RuntimeError(
            f"Expected {expected_len} output bytes, got {len(payload)}"
        )

    return struct.unpack(f"<{num_outputs}i", payload)
```

---

## 11. Scaling to the Final Model

The UART command interface can stay the same when scaling the model.

Only the following constants need to change in the FPGA and PC code:

```text
NUM_INPUTS
NUM_HIDDEN
NUM_OUTPUTS
NUM_WEIGHTS
NUM_BIASES
```

The weight layout should remain:

```text
Layer 1:
    W1 address = hidden_index * NUM_INPUTS + input_index

Layer 2:
    W2_BASE = NUM_INPUTS * NUM_HIDDEN
    W2 address = W2_BASE + output_index * NUM_HIDDEN + hidden_index
```

The bias layout should remain:

```text
hidden biases:
    bias[0 ... NUM_HIDDEN - 1]

output biases:
    bias[NUM_HIDDEN ... NUM_HIDDEN + NUM_OUTPUTS - 1]
```

The output payload length should be:

```text
4 * NUM_OUTPUTS
```

---

## 12. Practical Notes

The PC should wait for a response after every command.

Do not send multiple commands back-to-back without reading the previous response.

Recommended serial setup:

```python
serial.Serial("COM8", baudrate=115200, timeout=5.0)
```

A small delay between transactions is useful:

```python
INTER_PACKET_DELAY = 0.02
```

Do not clear the input buffer before every command. A delayed FPGA response could be accidentally discarded.

Clear buffers only once when opening the serial port:

```python
ser.reset_input_buffer()
ser.reset_output_buffer()
```

The FPGA currently supports one command at a time.

Use this request/response pattern:

```text
send command
wait for response
send next command
wait for response
...
```