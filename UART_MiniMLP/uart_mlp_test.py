import serial
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

USE_APPROX_MULTIPLIER = True

INTER_PACKET_DELAY = 0.01 # 20 ms delay between UART transactions


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


def send_packet(ser, cmd, addr=0, payload=b""):
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
        raise TimeoutError("Timed out reading header")

    cmd = header_rest[0]
    addr = (header_rest[1] << 8) | header_rest[2]
    length = (header_rest[3] << 8) | header_rest[4]

    payload = ser.read(length)
    if len(payload) != length:
        raise TimeoutError("Timed out reading payload")

    rx_checksum_raw = ser.read(1)
    if len(rx_checksum_raw) != 1:
        raise TimeoutError("Timed out reading checksum")

    rx_checksum = rx_checksum_raw[0]
    expected = checksum(bytes([START_BYTE]) + header_rest + payload)

    if rx_checksum != expected:
        raise ValueError(
            f"Bad checksum: received 0x{rx_checksum:02X}, expected 0x{expected:02X}"
        )

    return cmd, addr, payload


def expect_ack(ser, expected_cmd):
    cmd, addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        raise RuntimeError(f"FPGA returned ERROR code: {payload.hex()}")

    if cmd != CMD_ACK:
        raise RuntimeError(f"Expected ACK, got 0x{cmd:02X}")

    if len(payload) != 1 or payload[0] != expected_cmd:
        raise RuntimeError(
            f"Bad ACK payload: got {payload.hex()}, expected {expected_cmd:02X}"
        )

    time.sleep(INTER_PACKET_DELAY)


def write_weights(ser, weights):
    if len(weights) != 12:
        raise ValueError("Expected exactly 12 int8 weights")

    for w in weights:
        if w < -128 or w > 127:
            raise ValueError("Weights must fit in signed int8")

    payload = struct.pack("<12b", *weights)

    print(f"Writing weights: {weights}")
    send_packet(ser, CMD_WRITE_WEIGHT, addr=0, payload=payload)
    expect_ack(ser, CMD_WRITE_WEIGHT)


def write_biases(ser, biases):
    if len(biases) != 4:
        raise ValueError("Expected exactly 4 int32 biases")

    payload = struct.pack("<4i", *biases)

    print(f"Writing biases: {biases}")
    send_packet(ser, CMD_WRITE_BIAS, addr=0, payload=payload)
    expect_ack(ser, CMD_WRITE_BIAS)


def write_input_vector(ser, values):
    if len(values) != 4:
        raise ValueError("Expected exactly 4 input values")

    for v in values:
        if v < -128 or v > 127:
            raise ValueError("Inputs must fit in signed int8")

    payload = struct.pack("<4b", *values)

    print(f"Writing input vector: {values}")
    send_packet(ser, CMD_WRITE_INPUT, addr=0, payload=payload)
    expect_ack(ser, CMD_WRITE_INPUT)


def start_inference(ser):
    print("Sending START command...")
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

    time.sleep(INTER_PACKET_DELAY)

    return busy, done


def read_outputs(ser):
    # Give the FPGA TX FSM a moment after the last status response.
    time.sleep(INTER_PACKET_DELAY)

    send_packet(ser, CMD_READ_OUTPUT)
    cmd, addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        raise RuntimeError(f"FPGA returned ERROR code: {payload.hex()}")

    if cmd != CMD_OUTPUT_DATA:
        raise RuntimeError(f"Expected OUTPUT_DATA, got 0x{cmd:02X}")

    if len(payload) != 8:
        raise RuntimeError(f"Expected 8 output bytes, got {len(payload)}")

    time.sleep(INTER_PACKET_DELAY)

    return struct.unpack("<ii", payload)


def expected_python_model(x, weights, biases):
    w1 = [
        weights[0:4],
        weights[4:8],
    ]

    w2 = [
        weights[8:10],
        weights[10:12],
    ]

    b1 = biases[0:2]
    b2 = biases[2:4]

    h = []

    for j in range(2):
        acc = b1[j]
        for i in range(4):
            acc += x[i] * w1[j][i]

        # ReLU + int8 clipping
        if acc < 0:
            acc = 0
        elif acc > 127:
            acc = 127

        h.append(acc)

    out = []

    for k in range(2):
        acc = b2[k]
        for j in range(2):
            acc += h[j] * w2[k][j]
        out.append(acc)

    return out[0], out[1]


def run_single_test(ser, input_values, weights, biases):
    expected0, expected1 = expected_python_model(input_values, weights, biases)

    write_input_vector(ser, input_values)
    start_inference(ser)

    print("Polling status...")
    for _ in range(100):
        busy, done = read_status(ser)
        print(f"busy={busy}, done={done}")

        if done:
            break

        time.sleep(0.01)
    else:
        raise TimeoutError("FPGA did not finish inference")

    out0, out1 = read_outputs(ser)

    exact_pred = 0 if expected0 > expected1 else 1
    fpga_pred = 0 if out0 > out1 else 1

    print(f"FPGA out0 = {out0}")
    print(f"FPGA out1 = {out1}")
    print(f"Exact reference out0 = {expected0}")
    print(f"Exact reference out1 = {expected1}")

    print(f"Output error 0 = {out0 - expected0}")
    print(f"Output error 1 = {out1 - expected1}")
    print(f"Exact predicted class = {exact_pred}")
    print(f"FPGA predicted class  = {fpga_pred}")

    if USE_APPROX_MULTIPLIER:
        if fpga_pred == exact_pred:
            print("CLASSIFICATION MATCHED")
        else:
            print("CLASSIFICATION CHANGED")
    else:
        if out0 == expected0 and out1 == expected1:
            print("TEST PASSED")
        else:
            print("TEST FAILED")

    print()


def main():
    port = "COM8"
    baud = 115200

    if USE_APPROX_MULTIPLIER:
        print("Running in APPROXIMATE multiplier comparison mode")

        weights = [
            12,  -8,  16,   4,
            -20, 24, -12,   8,
            16, -12,
            -8,  20,
        ]

        biases = [0, 0, 0, 0]

        test_vectors = [
            [32,  16, -24,   8],
            [64, -32,  16, -16],
            [-48, 24,  40,  -8],
            [20,  36, -44,  28],
        ]

    else:
        print("Running in EXACT multiplier verification mode")

        weights = [
            1, 1, 1, 1,
            2, 0, -1, 1,
            1, -1,
            2, 1,
        ]

        biases = [0, 0, 0, 0]

        test_vectors = [
            [1, 2, 3, 4],
            [2, 2, 2, 2],
            [4, 3, 2, 1],
            [-1, 2, -3, 4],
        ]

    with serial.Serial(port, baudrate=baud, timeout=5.0) as ser:
        time.sleep(0.5)
        ser.reset_input_buffer()
        ser.reset_output_buffer()

        write_weights(ser, weights)
        write_biases(ser, biases)

        for x in test_vectors:
            run_single_test(ser, x, weights, biases)


if __name__ == "__main__":
    main()