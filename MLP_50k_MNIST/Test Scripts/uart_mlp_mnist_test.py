import argparse
import gzip
import math
import os
import random
import re
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

NUM_INPUTS = 784
NUM_HIDDEN1 = 64
NUM_HIDDEN2 = 32
NUM_OUTPUTS = 10

W1_SIZE = NUM_INPUTS * NUM_HIDDEN1
W2_SIZE = NUM_HIDDEN1 * NUM_HIDDEN2
W3_SIZE = NUM_HIDDEN2 * NUM_OUTPUTS

W1_BASE = 0
W2_BASE = W1_BASE + W1_SIZE
W3_BASE = W2_BASE + W2_SIZE

NUM_WEIGHTS = W1_SIZE + W2_SIZE + W3_SIZE

B1_BASE = 0
B2_BASE = B1_BASE + NUM_HIDDEN1
B3_BASE = B2_BASE + NUM_HIDDEN2

NUM_BIASES = NUM_HIDDEN1 + NUM_HIDDEN2 + NUM_OUTPUTS

DEFAULT_CHECKPOINT = "mnist_fpga_mlp_64_32.pt"


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


def send_packet(ser, cmd, addr=0, payload=b"", inter_packet_delay=0.02):
    packet = make_packet(cmd, addr, payload)
    ser.write(packet)
    ser.flush()
    time.sleep(inter_packet_delay)


def read_exact(ser, nbytes):
    data = ser.read(nbytes)
    if len(data) != nbytes:
        raise TimeoutError(f"Timed out reading {nbytes} byte(s), got {len(data)}")
    return data


def read_packet(ser):
    while True:
        b = ser.read(1)
        if len(b) == 0:
            raise TimeoutError("Timed out waiting for start byte")
        if b[0] == START_BYTE:
            break

    header_rest = read_exact(ser, 5)
    cmd = header_rest[0]
    addr = (header_rest[1] << 8) | header_rest[2]
    length = (header_rest[3] << 8) | header_rest[4]

    payload = read_exact(ser, length)
    rx_checksum = read_exact(ser, 1)[0]
    expected = checksum(bytes([START_BYTE]) + header_rest + payload)

    if rx_checksum != expected:
        raise ValueError(
            f"Bad checksum: received 0x{rx_checksum:02X}, expected 0x{expected:02X}"
        )

    return cmd, addr, payload


def expect_ack(ser, expected_cmd, inter_packet_delay):
    cmd, _addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        code = payload[0] if payload else None
        raise RuntimeError(f"FPGA returned ERROR code: {code}")

    if cmd != CMD_ACK:
        raise RuntimeError(f"Expected ACK, got 0x{cmd:02X}")

    if len(payload) != 1 or payload[0] != expected_cmd:
        raise RuntimeError(
            f"Bad ACK payload: got {payload.hex()}, expected {expected_cmd:02X}"
        )

    time.sleep(inter_packet_delay)


def send_command(ser, cmd, addr=0, payload=b"", expect_ack_response=True,
                 inter_packet_delay=0.02):
    send_packet(ser, cmd, addr, payload, inter_packet_delay)

    if expect_ack_response:
        expect_ack(ser, cmd, inter_packet_delay)


def write_int8_array_chunked(ser, cmd, values, max_chunk_bytes, inter_packet_delay,
                             verbose=True):
    offset = 0

    while offset < len(values):
        chunk = values[offset:offset + max_chunk_bytes]

        for v in chunk:
            if v < -128 or v > 127:
                raise ValueError(f"int8 value out of range: {v}")

        payload = struct.pack(f"<{len(chunk)}b", *chunk)
        if verbose:
            print(f"  writing {len(chunk):2d} int8 values at addr {offset}")
        send_command(
            ser,
            cmd,
            addr=offset,
            payload=payload,
            expect_ack_response=True,
            inter_packet_delay=inter_packet_delay,
        )

        offset += len(chunk)


def write_int32_array_chunked(ser, cmd, values, max_chunk_bytes, inter_packet_delay,
                              verbose=True):
    max_words = max(1, max_chunk_bytes // 4)
    offset = 0

    while offset < len(values):
        chunk = values[offset:offset + max_words]
        payload = struct.pack(f"<{len(chunk)}i", *chunk)

        if verbose:
            print(f"  writing {len(chunk):2d} int32 values at addr {offset}")
        send_command(
            ser,
            cmd,
            addr=offset,
            payload=payload,
            expect_ack_response=True,
            inter_packet_delay=inter_packet_delay,
        )

        offset += len(chunk)


def start_inference(ser, inter_packet_delay, verbose=True):
    if verbose:
        print("Sending START command...")

    send_command(
        ser,
        CMD_START,
        addr=0,
        payload=b"",
        expect_ack_response=True,
        inter_packet_delay=inter_packet_delay,
    )


def read_status(ser, inter_packet_delay):
    send_packet(ser, CMD_STATUS, inter_packet_delay=inter_packet_delay)
    cmd, _addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        code = payload[0] if payload else None
        raise RuntimeError(f"FPGA returned ERROR code: {code}")

    if cmd != CMD_STATUS_DATA:
        raise RuntimeError(f"Expected STATUS_DATA, got 0x{cmd:02X}")

    if len(payload) != 1:
        raise RuntimeError(f"Expected 1 status byte, got {len(payload)}")

    status = payload[0]
    busy = bool(status & 0x01)
    done = bool(status & 0x02)

    time.sleep(inter_packet_delay)
    return busy, done


def read_outputs(ser, inter_packet_delay):
    send_packet(ser, CMD_READ_OUTPUT, inter_packet_delay=inter_packet_delay)
    cmd, _addr, payload = read_packet(ser)

    if cmd == CMD_ERROR:
        code = payload[0] if payload else None
        raise RuntimeError(f"FPGA returned ERROR code: {code}")

    if cmd != CMD_OUTPUT_DATA:
        raise RuntimeError(f"Expected OUTPUT_DATA, got 0x{cmd:02X}")

    expected_len = NUM_OUTPUTS * 4
    if len(payload) != expected_len:
        raise RuntimeError(f"Expected {expected_len} output bytes, got {len(payload)}")

    time.sleep(inter_packet_delay)
    return list(struct.unpack(f"<{NUM_OUTPUTS}i", payload))


def clip_int8(v):
    return max(-128, min(127, int(round(v))))


def clip_int32(v):
    return max(-(2 ** 31), min(2 ** 31 - 1, int(round(v))))


def relu_clip_s8(x, shift):
    if x < 0:
        return 0

    y = x >> shift
    return min(127, y)


def argmax(values):
    return max(range(len(values)), key=lambda i: values[i])


def exact_multiply(a, b):
    return a * b


def load_approx_lut_header(path):
    text = open(path, "r", encoding="utf-8").read()

    if "=" not in text:
        raise ValueError(f"{path} does not look like a C LUT header")

    values = [int(x) for x in re.findall(r"-?\d+", text.split("=", 1)[1])]

    if len(values) != 256 * 256:
        raise ValueError(f"Expected 65536 LUT entries in {path}, got {len(values)}")

    lut = [values[i * 256:(i + 1) * 256] for i in range(256)]

    def lut_multiply(a, b):
        return lut[a & 0xFF][b & 0xFF]

    # Quick signed-index sanity check for the ADAPT convention.
    if lut_multiply(0, 37) != 0 or lut_multiply(2, 2) == 0:
        print("Warning: LUT header indexing sanity check looked unusual.")

    return lut_multiply


def expected_integer_model(x, weights, biases, hidden1_shift, hidden2_shift,
                           multiply_fn=exact_multiply):
    hidden1 = []

    for h1 in range(NUM_HIDDEN1):
        acc = biases[B1_BASE + h1]

        for i in range(NUM_INPUTS):
            waddr = W1_BASE + h1 * NUM_INPUTS + i
            acc += multiply_fn(x[i], weights[waddr])

        hidden1.append(relu_clip_s8(acc, hidden1_shift))

    hidden2 = []

    for h2 in range(NUM_HIDDEN2):
        acc = biases[B2_BASE + h2]

        for h1 in range(NUM_HIDDEN1):
            waddr = W2_BASE + h2 * NUM_HIDDEN1 + h1
            acc += multiply_fn(hidden1[h1], weights[waddr])

        hidden2.append(relu_clip_s8(acc, hidden2_shift))

    outputs = []

    for o in range(NUM_OUTPUTS):
        acc = biases[B3_BASE + o]

        for h2 in range(NUM_HIDDEN2):
            waddr = W3_BASE + o * NUM_HIDDEN2 + h2
            acc += multiply_fn(hidden2[h2], weights[waddr])

        outputs.append(acc)

    return outputs, hidden1, hidden2


def get_state_dict(checkpoint_path):
    try:
        import torch
    except ImportError as exc:
        raise RuntimeError(
            "This script needs PyTorch to load the .pt checkpoint. "
            "Run it in the same Python environment you used for training, "
            "or install torch for this test environment."
        ) from exc

    try:
        checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    except TypeError:
        checkpoint = torch.load(checkpoint_path, map_location="cpu")

    if isinstance(checkpoint, dict) and "state_dict" in checkpoint:
        state = checkpoint["state_dict"]
    elif isinstance(checkpoint, dict) and "model_state_dict" in checkpoint:
        state = checkpoint["model_state_dict"]
    elif isinstance(checkpoint, dict):
        state = checkpoint
    else:
        state = checkpoint.state_dict()

    return state


def get_tensor(state, name):
    candidates = [
        name,
        "module." + name,
        "model." + name,
        "net." + name,
    ]

    for candidate in candidates:
        if candidate in state:
            tensor = state[candidate]
            if hasattr(tensor, "detach"):
                tensor = tensor.detach().cpu()
            return tensor

    raise KeyError(f"Could not find tensor {name!r} in checkpoint")


def tensor_to_rows(tensor):
    return [[float(v) for v in row] for row in tensor.tolist()]


def tensor_to_list(tensor):
    return [float(v) for v in tensor.tolist()]


def fuse_linear_batchnorm(state, fc_name, bn_name=None, eps=1e-5):
    w = tensor_to_rows(get_tensor(state, f"{fc_name}.weight"))
    b = tensor_to_list(get_tensor(state, f"{fc_name}.bias"))

    if bn_name is None:
        return w, b

    gamma = tensor_to_list(get_tensor(state, f"{bn_name}.weight"))
    beta = tensor_to_list(get_tensor(state, f"{bn_name}.bias"))
    mean = tensor_to_list(get_tensor(state, f"{bn_name}.running_mean"))
    var = tensor_to_list(get_tensor(state, f"{bn_name}.running_var"))

    fused_w = []
    fused_b = []

    for o in range(len(w)):
        scale = gamma[o] / math.sqrt(var[o] + eps)
        fused_w.append([scale * x for x in w[o]])
        fused_b.append(scale * (b[o] - mean[o]) + beta[o])

    return fused_w, fused_b


def quantize_rows(rows, scale):
    return [[clip_int8(v * scale) for v in row] for row in rows]


def flatten_rows(rows):
    return [v for row in rows for v in row]


def load_fused_model(args):
    state = get_state_dict(args.checkpoint)

    w1_f, b1_f = fuse_linear_batchnorm(state, "fc1", "bc1", eps=args.bn_eps)
    w2_f, b2_f = fuse_linear_batchnorm(state, "fc2", "bc2", eps=args.bn_eps)
    w3_f, b3_f = fuse_linear_batchnorm(state, "fc3", None, eps=args.bn_eps)

    return {
        "w1": w1_f,
        "b1": b1_f,
        "w2": w2_f,
        "b2": b2_f,
        "w3": w3_f,
        "b3": b3_f,
    }


def quantize_fused_model(fused, input_scale, w1_scale, w2_scale, w3_scale,
                         hidden1_shift, hidden2_shift):
    w1_q = quantize_rows(fused["w1"], w1_scale)
    w2_q = quantize_rows(fused["w2"], w2_scale)
    w3_q = quantize_rows(fused["w3"], w3_scale)

    # Biases must be in the same integer accumulator domain as their layer.
    s1 = input_scale * w1_scale
    s2 = (s1 / (2 ** hidden1_shift)) * w2_scale
    s3 = (s2 / (2 ** hidden2_shift)) * w3_scale

    b1_q = [clip_int32(v * s1) for v in fused["b1"]]
    b2_q = [clip_int32(v * s2) for v in fused["b2"]]
    b3_q = [clip_int32(v * s3) for v in fused["b3"]]

    weights = flatten_rows(w1_q) + flatten_rows(w2_q) + flatten_rows(w3_q)
    biases = b1_q + b2_q + b3_q

    if len(weights) != NUM_WEIGHTS:
        raise ValueError(f"Expected {NUM_WEIGHTS} weights, got {len(weights)}")

    if len(biases) != NUM_BIASES:
        raise ValueError(f"Expected {NUM_BIASES} biases, got {len(biases)}")

    return weights, biases


def load_quantized_model(args):
    fused = load_fused_model(args)
    weights, biases = quantize_fused_model(
        fused,
        args.input_scale,
        args.w1_scale,
        args.w2_scale,
        args.w3_scale,
        args.hidden1_shift,
        args.hidden2_shift,
    )

    print("Loaded checkpoint and prepared FPGA memories")
    print(f"  weights: {len(weights)} int8 values")
    print(f"  biases:  {len(biases)} int32 values")
    print(f"  scales:  w1={args.w1_scale}, w2={args.w2_scale}, w3={args.w3_scale}")
    print(f"  shifts:  hidden1={args.hidden1_shift}, hidden2={args.hidden2_shift}")
    print(f"  MNIST input: {args.mnist_input_mode}, input_scale={args.input_scale}")

    return weights, biases


def make_zero_input():
    return [0 for _ in range(NUM_INPUTS)]


def make_sparse_input():
    x = [0 for _ in range(NUM_INPUTS)]

    # A simple deterministic "digit-ish" block in the center of a 28x28 image.
    for r in range(9, 19):
        for c in range(12, 16):
            x[r * 28 + c] = 96
    for c in range(10, 18):
        x[9 * 28 + c] = 96
        x[18 * 28 + c] = 96

    return x


def make_random_input(seed):
    rng = random.Random(seed)
    return [rng.randint(0, 127) for _ in range(NUM_INPUTS)]


def load_input_file(path):
    values = []

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            for token in line.replace(",", " ").split():
                values.append(int(token))

    if len(values) != NUM_INPUTS:
        raise ValueError(f"Expected {NUM_INPUTS} input values, got {len(values)}")

    for v in values:
        if v < -128 or v > 127:
            raise ValueError(f"Input int8 value out of range: {v}")

    return values


def quantize_mnist_pixels(pixel_values, input_scale, input_mode):
    if input_mode == "normalized":
        values = [clip_int8((int(v) / 255.0) * input_scale) for v in pixel_values]
    elif input_mode == "raw":
        values = [clip_int8(int(v) * input_scale) for v in pixel_values]
    else:
        raise ValueError(f"Unknown MNIST input mode: {input_mode}")

    if len(values) != NUM_INPUTS:
        raise ValueError(f"Expected {NUM_INPUTS} MNIST pixels, got {len(values)}")

    return values


def find_mnist_file(root, base_name):
    candidates = [
        os.path.join(root, base_name),
        os.path.join(root, base_name + ".gz"),
        os.path.join(root, "raw", base_name),
        os.path.join(root, "raw", base_name + ".gz"),
        os.path.join(root, "MNIST", "raw", base_name),
        os.path.join(root, "MNIST", "raw", base_name + ".gz"),
    ]

    for path in candidates:
        if os.path.exists(path):
            return path

    return None


def read_mnist_idx_images(path):
    opener = gzip.open if path.endswith(".gz") else open

    with opener(path, "rb") as f:
        magic, count, rows, cols = struct.unpack(">IIII", f.read(16))

        if magic != 2051:
            raise ValueError(f"{path} is not an IDX image file")

        if rows * cols != NUM_INPUTS:
            raise ValueError(f"Expected 28x28 images, got {rows}x{cols}")

        raw = f.read(count * rows * cols)

    images = []
    image_size = rows * cols

    for i in range(count):
        start = i * image_size
        images.append(raw[start:start + image_size])

    return images


def read_mnist_idx_labels(path):
    opener = gzip.open if path.endswith(".gz") else open

    with opener(path, "rb") as f:
        magic, count = struct.unpack(">II", f.read(8))

        if magic != 2049:
            raise ValueError(f"{path} is not an IDX label file")

        labels = list(f.read(count))

    return labels


def load_mnist_with_torchvision(args):
    try:
        from torchvision.datasets import MNIST
    except ImportError as exc:
        raise RuntimeError("torchvision is not installed") from exc

    dataset = MNIST(root=args.mnist_root, train=False, download=args.mnist_download)
    samples = []

    for i in range(len(dataset)):
        image = dataset.data[i].reshape(-1).tolist()
        label = int(dataset.targets[i])
        samples.append((image, label))

    return samples


def load_mnist_with_idx_files(args):
    image_path = find_mnist_file(args.mnist_root, "t10k-images-idx3-ubyte")
    label_path = find_mnist_file(args.mnist_root, "t10k-labels-idx1-ubyte")

    if image_path is None or label_path is None:
        raise FileNotFoundError(
            "Could not find MNIST test IDX files. Expected t10k-images-idx3-ubyte "
            "and t10k-labels-idx1-ubyte, optionally .gz, under --mnist-root."
        )

    images = read_mnist_idx_images(image_path)
    labels = read_mnist_idx_labels(label_path)

    if len(images) != len(labels):
        raise ValueError(f"MNIST image/label count mismatch: {len(images)} vs {len(labels)}")

    return list(zip(images, labels))


def load_mnist_test_vectors(args):
    try:
        samples = load_mnist_with_torchvision(args)
    except Exception as tv_exc:
        if args.mnist_download:
            raise

        print(f"torchvision MNIST load unavailable ({tv_exc}); trying IDX files.")
        samples = load_mnist_with_idx_files(args)

    indices = list(range(len(samples)))

    if args.mnist_shuffle:
        rng = random.Random(args.random_seed)
        rng.shuffle(indices)

    indices = indices[args.mnist_start:]

    if args.mnist_count is not None:
        indices = indices[:args.mnist_count]

    vectors = []

    for dataset_index in indices:
        pixels, label = samples[dataset_index]
        x = quantize_mnist_pixels(pixels, args.input_scale, args.mnist_input_mode)
        vectors.append((f"mnist-{dataset_index}", x, int(label)))

    if not vectors:
        raise ValueError("MNIST selection produced zero samples")

    return vectors


def make_test_vectors(args):
    vectors = []

    if args.input_file:
        vectors.append(("file", load_input_file(args.input_file)))

    if args.zero:
        vectors.append(("zero", make_zero_input()))

    if args.sparse:
        vectors.append(("sparse", make_sparse_input()))

    for i in range(args.random_tests):
        vectors.append((f"random-{i}", make_random_input(args.random_seed + i)))

    if not vectors:
        vectors.append(("zero", make_zero_input()))

    return vectors


def run_inference(ser, input_values, args, verbose=True):
    write_int8_array_chunked(
        ser,
        CMD_WRITE_INPUT,
        input_values,
        args.max_chunk_bytes,
        args.inter_packet_delay,
        verbose=verbose,
    )

    start_inference(ser, args.inter_packet_delay, verbose=verbose)

    if verbose:
        print("Polling status...")

    deadline = time.time() + args.inference_timeout
    polls = 0

    while time.time() < deadline:
        busy, done = read_status(ser, args.inter_packet_delay)
        polls += 1

        if args.verbose_status:
            print(f"  poll {polls}: busy={busy}, done={done}")

        if done:
            break

        time.sleep(args.poll_delay)
    else:
        raise TimeoutError("FPGA did not finish inference")

    return read_outputs(ser, args.inter_packet_delay)


def run_single_test(ser, name, input_values, weights, biases, args):
    expected, hidden1, hidden2 = expected_integer_model(
        input_values,
        weights,
        biases,
        args.hidden1_shift,
        args.hidden2_shift,
        args.multiply_fn,
    )

    print(f"\n=== Test: {name} ===")
    print(f"Input min/max: {min(input_values)} / {max(input_values)}")
    print(f"Reference hidden1 nonzero: {sum(1 for v in hidden1 if v != 0)} / {NUM_HIDDEN1}")
    print(f"Reference hidden2 nonzero: {sum(1 for v in hidden2 if v != 0)} / {NUM_HIDDEN2}")

    fpga_outputs = run_inference(ser, input_values, args, verbose=True)

    expected_pred = argmax(expected)
    fpga_pred = argmax(fpga_outputs)
    errors = [fpga_outputs[i] - expected[i] for i in range(NUM_OUTPUTS)]

    print(f"Reference logits: {expected}")
    print(f"FPGA logits:      {fpga_outputs}")
    print(f"Logit errors:     {errors}")
    print(f"Reference class:  {expected_pred}")
    print(f"FPGA class:       {fpga_pred}")

    if args.exact:
        if fpga_outputs == expected:
            print("TEST PASSED: exact logits match")
        else:
            print("TEST FAILED: exact logits differ")
    else:
        if fpga_pred == expected_pred:
            print("CLASSIFICATION MATCHED")
        else:
            print("CLASSIFICATION CHANGED")


def run_mnist_tests(ser, mnist_vectors, weights, biases, args):
    correct_label = 0
    matched_reference = 0
    exact_logit_matches = 0
    confusion = [[0 for _ in range(NUM_OUTPUTS)] for _ in range(NUM_OUTPUTS)]

    print(f"\nRunning {len(mnist_vectors)} MNIST test sample(s)...")

    for sample_num, (name, input_values, label) in enumerate(mnist_vectors, start=1):
        expected, _hidden1, _hidden2 = expected_integer_model(
            input_values,
            weights,
            biases,
            args.hidden1_shift,
            args.hidden2_shift,
            args.multiply_fn,
        )

        fpga_outputs = run_inference(
            ser,
            input_values,
            args,
            verbose=args.verbose_samples,
        )

        expected_pred = argmax(expected)
        fpga_pred = argmax(fpga_outputs)
        label_match = fpga_pred == label
        reference_match = fpga_pred == expected_pred
        exact_match = fpga_outputs == expected

        if label_match:
            correct_label += 1

        if reference_match:
            matched_reference += 1

        if exact_match:
            exact_logit_matches += 1

        confusion[label][fpga_pred] += 1

        running_acc = 100.0 * correct_label / sample_num
        ref_acc = 100.0 * matched_reference / sample_num

        print(
            f"{sample_num:4d}/{len(mnist_vectors)} {name:>12s} "
            f"label={label} ref={expected_pred} fpga={fpga_pred} "
            f"acc={running_acc:6.2f}% ref_match={ref_acc:6.2f}%"
        )

        if args.verbose_samples:
            errors = [fpga_outputs[i] - expected[i] for i in range(NUM_OUTPUTS)]
            print(f"    reference logits: {expected}")
            print(f"    fpga logits:      {fpga_outputs}")
            print(f"    logit errors:     {errors}")

    total = len(mnist_vectors)
    print("\nMNIST summary")
    print(f"  FPGA vs label accuracy:      {correct_label}/{total} = {100.0 * correct_label / total:.2f}%")
    print(f"  FPGA vs {args.reference_name} reference: {matched_reference}/{total} = {100.0 * matched_reference / total:.2f}%")
    print(f"  Logit matches vs reference:  {exact_logit_matches}/{total} = {100.0 * exact_logit_matches / total:.2f}%")

    if args.show_confusion:
        print("\nConfusion matrix: rows=true label, columns=FPGA prediction")
        print("      " + " ".join(f"{i:4d}" for i in range(NUM_OUTPUTS)))
        for label in range(NUM_OUTPUTS):
            row = " ".join(f"{confusion[label][pred]:4d}" for pred in range(NUM_OUTPUTS))
            print(f"{label:4d}: {row}")


def parse_shift_values(text):
    values = []

    for part in text.split(","):
        part = part.strip()

        if not part:
            continue

        if ":" in part:
            fields = [int(x) for x in part.split(":")]

            if len(fields) == 2:
                start, stop = fields
                step = 1
            elif len(fields) == 3:
                start, stop, step = fields
            else:
                raise ValueError(f"Bad shift range: {part}")

            if step == 0:
                raise ValueError("Shift range step cannot be zero")

            if step > 0:
                values.extend(range(start, stop + 1, step))
            else:
                values.extend(range(start, stop - 1, step))
        else:
            values.append(int(part))

    return sorted(set(values))


def parse_float_values(text):
    values = []

    for part in text.split(","):
        part = part.strip()

        if part:
            values.append(float(part))

    if not values:
        raise ValueError("Expected at least one scale value")

    return sorted(set(values))


def evaluate_integer_reference(mnist_vectors, weights, biases, hidden1_shift, hidden2_shift,
                               multiply_fn=exact_multiply):
    correct = 0
    pred_counts = [0 for _ in range(NUM_OUTPUTS)]
    h1_nonzero_total = 0
    h2_nonzero_total = 0
    h1_sat_total = 0
    h2_sat_total = 0

    for _name, input_values, label in mnist_vectors:
        logits, hidden1, hidden2 = expected_integer_model(
            input_values,
            weights,
            biases,
            hidden1_shift,
            hidden2_shift,
            multiply_fn,
        )

        pred = argmax(logits)
        pred_counts[pred] += 1

        if pred == label:
            correct += 1

        h1_nonzero_total += sum(1 for v in hidden1 if v != 0)
        h2_nonzero_total += sum(1 for v in hidden2 if v != 0)
        h1_sat_total += sum(1 for v in hidden1 if v == 127)
        h2_sat_total += sum(1 for v in hidden2 if v == 127)

    total = len(mnist_vectors)
    h1_total = total * NUM_HIDDEN1
    h2_total = total * NUM_HIDDEN2

    return {
        "correct": correct,
        "total": total,
        "accuracy": 100.0 * correct / total,
        "pred_counts": pred_counts,
        "h1_nonzero_pct": 100.0 * h1_nonzero_total / h1_total,
        "h2_nonzero_pct": 100.0 * h2_nonzero_total / h2_total,
        "h1_sat_pct": 100.0 * h1_sat_total / h1_total,
        "h2_sat_pct": 100.0 * h2_sat_total / h2_total,
    }


def run_shift_sweep(mnist_vectors, weights, biases, args):
    h1_values = parse_shift_values(args.sweep_hidden1_shifts)
    h2_values = parse_shift_values(args.sweep_hidden2_shifts)
    results = []

    print(f"\nSweeping integer reference shifts over {len(mnist_vectors)} MNIST sample(s)")
    print("h1_shift h2_shift   acc   correct   h1_sat  h2_sat  h1_nz   h2_nz   pred_counts")

    for h1_shift in h1_values:
        for h2_shift in h2_values:
            result = evaluate_integer_reference(
                mnist_vectors,
                weights,
                biases,
                h1_shift,
                h2_shift,
                args.multiply_fn,
            )

            results.append((result["accuracy"], h1_shift, h2_shift, result))

            print(
                f"{h1_shift:8d} {h2_shift:8d} "
                f"{result['accuracy']:6.2f}% "
                f"{result['correct']:4d}/{result['total']:<4d} "
                f"{result['h1_sat_pct']:7.2f}% "
                f"{result['h2_sat_pct']:7.2f}% "
                f"{result['h1_nonzero_pct']:7.2f}% "
                f"{result['h2_nonzero_pct']:7.2f}% "
                f"{result['pred_counts']}"
            )

    results.sort(reverse=True, key=lambda item: item[0])

    best_acc, best_h1, best_h2, best = results[0]
    print("\nBest shift pair")
    print(f"  HIDDEN1_SCALE_SHIFT = {best_h1}")
    print(f"  HIDDEN2_SCALE_SHIFT = {best_h2}")
    print(f"  Integer-reference accuracy = {best['correct']}/{best['total']} = {best_acc:.2f}%")
    print("  Rebuild the HDL with these constants before expecting FPGA label accuracy to match.")


def run_scale_sweep(args):
    fused = load_fused_model(args)

    input_scales = parse_float_values(args.sweep_input_scales)
    weight_scales = parse_float_values(args.sweep_weight_scales)
    h1_values = parse_shift_values(args.sweep_hidden1_shifts)
    h2_values = parse_shift_values(args.sweep_hidden2_shifts)
    results = []
    vectors_by_input_scale = {}

    print("\nSweeping integer-reference scales")
    print("in_scale w_scale h1_shift h2_shift   acc   correct   h1_sat  h2_sat   pred_counts")

    for input_scale in input_scales:
        args.input_scale = input_scale
        vectors_by_input_scale[input_scale] = load_mnist_test_vectors(args)

        for weight_scale in weight_scales:
            for h1_shift in h1_values:
                for h2_shift in h2_values:
                    weights, biases = quantize_fused_model(
                        fused,
                        input_scale,
                        weight_scale,
                        weight_scale,
                        weight_scale,
                        h1_shift,
                        h2_shift,
                    )

                    result = evaluate_integer_reference(
                        vectors_by_input_scale[input_scale],
                        weights,
                        biases,
                        h1_shift,
                        h2_shift,
                        args.multiply_fn,
                    )

                    results.append((result["accuracy"], input_scale, weight_scale,
                                    h1_shift, h2_shift, result))

                    print(
                        f"{input_scale:8.3g} {weight_scale:7.3g} "
                        f"{h1_shift:8d} {h2_shift:8d} "
                        f"{result['accuracy']:6.2f}% "
                        f"{result['correct']:4d}/{result['total']:<4d} "
                        f"{result['h1_sat_pct']:7.2f}% "
                        f"{result['h2_sat_pct']:7.2f}% "
                        f"{result['pred_counts']}"
                    )

    results.sort(reverse=True, key=lambda item: item[0])

    print("\nTop scale configurations")
    for rank, (accuracy, input_scale, weight_scale, h1_shift, h2_shift, result) in enumerate(results[:10], start=1):
        print(
            f"{rank:2d}. acc={accuracy:6.2f}% "
            f"correct={result['correct']}/{result['total']} "
            f"input_scale={input_scale:g} "
            f"w1=w2=w3={weight_scale:g} "
            f"h1_shift={h1_shift} h2_shift={h2_shift} "
            f"pred_counts={result['pred_counts']}"
        )

    best_accuracy, best_input, best_weight, best_h1, best_h2, _best = results[0]
    lut_header_arg = ""
    if args.approx_lut_header is not None:
        lut_header_arg = f"--approx-lut-header {args.approx_lut_header} "

    print("\nBest command for a software check")
    print(
        "  python uart_mlp_mnist_test.py --checkpoint mnist_fpga_mlp_64_32.pt "
        f"--mnist-test --mnist-count {args.mnist_count if args.mnist_count is not None else -1} "
        f"--mnist-input-mode {args.mnist_input_mode} "
        f"--input-scale {best_input:g} --w1-scale {best_weight:g} "
        f"--w2-scale {best_weight:g} --w3-scale {best_weight:g} "
        f"--hidden1-shift {best_h1} --hidden2-shift {best_h2} "
        f"{lut_header_arg}--dry-run"
    )
    print("\nIf this looks good, rebuild HDL with:")
    print(f"  HIDDEN1_SCALE_SHIFT = {best_h1}")
    print(f"  HIDDEN2_SCALE_SHIFT = {best_h2}")
    print("and reload weights generated with the listed input/weight scales.")


def print_dry_run_summary(name, input_values, weights, biases, args):
    expected, hidden1, hidden2 = expected_integer_model(
        input_values,
        weights,
        biases,
        args.hidden1_shift,
        args.hidden2_shift,
        args.multiply_fn,
    )

    print(f"\n=== Dry run: {name} ===")
    print(f"Input min/max: {min(input_values)} / {max(input_values)}")
    print(f"Hidden1 nonzero: {sum(1 for v in hidden1 if v != 0)} / {NUM_HIDDEN1}")
    print(f"Hidden2 nonzero: {sum(1 for v in hidden2 if v != 0)} / {NUM_HIDDEN2}")
    print(f"Reference logits: {expected}")
    print(f"Reference class:  {argmax(expected)}")


def print_mnist_dry_run_summary(mnist_vectors, weights, biases, args):
    correct = 0
    confusion = [[0 for _ in range(NUM_OUTPUTS)] for _ in range(NUM_OUTPUTS)]
    misses = []

    for name, input_values, label in mnist_vectors:
        expected, _hidden1, _hidden2 = expected_integer_model(
            input_values,
            weights,
            biases,
            args.hidden1_shift,
            args.hidden2_shift,
            args.multiply_fn,
        )

        pred = argmax(expected)
        confusion[label][pred] += 1

        if pred == label:
            correct += 1
        else:
            misses.append((name, label, pred))

    total = len(mnist_vectors)

    print("\nMNIST dry-run summary")
    print(f"  {args.reference_name} reference accuracy: {correct}/{total} = {100.0 * correct / total:.2f}%")
    print(f"  Misses: {len(misses)}")

    if misses:
        shown = ", ".join(f"{name}: {label}->{pred}" for name, label, pred in misses[:20])
        print(f"  First misses: {shown}")

        if len(misses) > 20:
            print(f"  ... {len(misses) - 20} more")

    if args.show_confusion:
        print(f"\nConfusion matrix: rows=true label, columns={args.reference_name} reference prediction")
        print("      " + " ".join(f"{i:4d}" for i in range(NUM_OUTPUTS)))
        for label in range(NUM_OUTPUTS):
            row = " ".join(f"{confusion[label][pred]:4d}" for pred in range(NUM_OUTPUTS))
            print(f"{label:4d}: {row}")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Load a 784-64-32-10 MNIST MLP checkpoint into the FPGA over UART."
    )

    parser.add_argument("--port", default="COM8")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--checkpoint", default=DEFAULT_CHECKPOINT)

    parser.add_argument("--max-chunk-bytes", type=int, default=8)
    parser.add_argument("--inter-packet-delay", type=float, default=0.02)
    parser.add_argument("--poll-delay", type=float, default=0.02)
    parser.add_argument("--inference-timeout", type=float, default=10.0)
    parser.add_argument("--verbose-status", action="store_true")

    parser.add_argument("--w1-scale", type=float, default=64.0)
    parser.add_argument("--w2-scale", type=float, default=64.0)
    parser.add_argument("--w3-scale", type=float, default=64.0)
    parser.add_argument("--input-scale", type=float, default=127.0)
    parser.add_argument("--bn-eps", type=float, default=1e-5)

    # These must match HIDDEN1_SCALE_SHIFT and HIDDEN2_SCALE_SHIFT in the HDL.
    parser.add_argument("--hidden1-shift", type=int, default=0)
    parser.add_argument("--hidden2-shift", type=int, default=0)

    parser.add_argument("--zero", action="store_true", help="Run an all-zero input test.")
    parser.add_argument("--sparse", action="store_true", help="Run a deterministic sparse input test.")
    parser.add_argument("--random-tests", type=int, default=0)
    parser.add_argument("--random-seed", type=int, default=1234)
    parser.add_argument("--input-file", help="Text/CSV file containing 784 signed int8 values.")

    parser.add_argument("--mnist-test", action="store_true",
                        help="Run samples from the MNIST test dataset.")
    parser.add_argument("--mnist-root", default="./data",
                        help="Directory containing torchvision MNIST data or raw IDX files.")
    parser.add_argument("--mnist-count", type=int, default=20,
                        help="Number of MNIST test samples to run. Use -1 for all selected samples.")
    parser.add_argument("--mnist-start", type=int, default=0,
                        help="Starting index in the MNIST test set after optional shuffling.")
    parser.add_argument("--mnist-download", action="store_true",
                        help="Allow torchvision to download MNIST if it is not already present.")
    parser.add_argument("--mnist-input-mode", choices=("normalized", "raw"), default="normalized",
                        help="normalized uses pixel/255*input_scale; raw uses pixel*input_scale.")
    parser.add_argument("--mnist-shuffle", action="store_true",
                        help="Shuffle MNIST test indices using --random-seed before selection.")
    parser.add_argument("--verbose-samples", action="store_true",
                        help="Print per-sample logits and input-write details for MNIST tests.")
    parser.add_argument("--show-confusion", action="store_true",
                        help="Print a 10x10 confusion matrix after MNIST tests.")
    parser.add_argument("--sweep-shifts", action="store_true",
                        help="Software-only sweep of hidden activation shifts on MNIST.")
    parser.add_argument("--sweep-hidden1-shifts", default="0:14",
                        help="Comma/range list for layer-1 shift sweep, e.g. 8:14 or 8,10,12.")
    parser.add_argument("--sweep-hidden2-shifts", default="0:14",
                        help="Comma/range list for layer-2 shift sweep, e.g. 4:12 or 4,6,8.")
    parser.add_argument("--sweep-scales", action="store_true",
                        help="Software-only sweep of input scale, shared weight scale, and hidden shifts.")
    parser.add_argument("--sweep-input-scales", default="1,2,4,8,16,32,64,127",
                        help="Comma-separated input_scale values for --sweep-scales.")
    parser.add_argument("--sweep-weight-scales", default="8,16,32,64,128,256",
                        help="Comma-separated shared w1/w2/w3 scale values for --sweep-scales.")
    parser.add_argument("--approx-lut-header",
                        help="C header containing const int16_t lut[256][256] for the reference multiplier.")

    weight_load_group = parser.add_mutually_exclusive_group()
    weight_load_group.add_argument(
        "--reload-weights",
        dest="reload_weights",
        action="store_true",
        default=True,
        help="Upload quantized weights and biases before running tests. This is the default.",
    )
    weight_load_group.add_argument(
        "--no-reload-weights",
        "--skip-weight-load",
        dest="reload_weights",
        action="store_false",
        help="Skip weight/bias upload and reuse the values already stored in FPGA BRAM.",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--exact", action="store_true",
                        help="Require bit-exact logits. Use this with the exact multiplier.")

    return parser.parse_args()


def main():
    args = parse_args()

    if args.max_chunk_bytes < 1 or args.max_chunk_bytes > 16:
        raise ValueError("The HDL parser supports --max-chunk-bytes from 1 to 16.")

    if args.mnist_count == -1:
        args.mnist_count = None

    if args.approx_lut_header:
        args.multiply_fn = load_approx_lut_header(args.approx_lut_header)
        args.reference_name = "approx-LUT"
        print(f"Loaded approximate LUT reference: {args.approx_lut_header}")
    else:
        args.multiply_fn = exact_multiply
        args.reference_name = "exact"

    if args.sweep_scales:
        if not args.mnist_test:
            raise ValueError("--sweep-scales requires --mnist-test")

        run_scale_sweep(args)
        return

    weights, biases = load_quantized_model(args)
    mnist_vectors = load_mnist_test_vectors(args) if args.mnist_test else []
    test_vectors = make_test_vectors(args) if not args.mnist_test else []

    print("Model: 784 -> 64 -> 32 -> 10")
    print(f"Number of test vectors: {len(test_vectors) + len(mnist_vectors)}")

    if args.dry_run:
        for name, x, label in mnist_vectors:
            if args.verbose_samples:
                print_dry_run_summary(f"{name} label={label}", x, weights, biases, args)

        if mnist_vectors:
            print_mnist_dry_run_summary(mnist_vectors, weights, biases, args)

        for name, x in test_vectors:
            print_dry_run_summary(name, x, weights, biases, args)

        return

    if args.sweep_shifts:
        if not mnist_vectors:
            raise ValueError("--sweep-shifts requires --mnist-test")

        run_shift_sweep(mnist_vectors, weights, biases, args)
        return

    import serial

    with serial.Serial(args.port, baudrate=args.baud, timeout=args.timeout) as ser:
        time.sleep(0.5)
        ser.reset_input_buffer()
        ser.reset_output_buffer()

        if args.reload_weights:
            print("\nWriting weights...")
            write_int8_array_chunked(
                ser,
                CMD_WRITE_WEIGHT,
                weights,
                args.max_chunk_bytes,
                args.inter_packet_delay,
            )

            print("\nWriting biases...")
            write_int32_array_chunked(
                ser,
                CMD_WRITE_BIAS,
                biases,
                args.max_chunk_bytes,
                args.inter_packet_delay,
            )
        else:
            print("Skipping weight/bias upload; reusing existing FPGA BRAM contents.")

        if mnist_vectors:
            run_mnist_tests(ser, mnist_vectors, weights, biases, args)

        for name, x in test_vectors:
            run_single_test(ser, name, x, weights, biases, args)


if __name__ == "__main__":
    main()
