#include "vakili_r1_p16.h"

namespace vakili_r1_p16 {

#ifdef VAKILI_R1_AP_INT
using byte_t = ap_uint<8>;
#else
using byte_t = std::uint8_t;
#endif

static unsigned bit_value(byte_t value, int index) {
#pragma HLS INLINE
#ifdef VAKILI_R1_AP_INT
    return value[index] ? 1U : 0U;
#else
    return (static_cast<unsigned>(value) >> index) & 1U;
#endif
}

product_t vakili_r1_mul8s(data_t weight, data_t activation) {
#pragma HLS INLINE off
    // Direct R1/REFINEMENT_PART=1 equations. Operands are raw two's-
    // complement bit patterns; low output bits are forced to zero.
    const byte_t a = byte_t(weight);
    const byte_t b = byte_t(activation);

    const unsigned ps1_term1 =
        ((1U ^ (bit_value(a, 5) & bit_value(b, 7))) << 2)
        | ((bit_value(a, 5) & bit_value(b, 6)) << 1)
        | (bit_value(a, 5) & bit_value(b, 5));
    const unsigned ps1_term2 =
        ((1U ^ (bit_value(a, 6) & bit_value(b, 7))) << 3)
        | ((bit_value(a, 6) & bit_value(b, 6)) << 2)
        | ((bit_value(a, 6) & bit_value(b, 5)) << 1);
    const unsigned ps1_term3 =
        ((bit_value(a, 7) & bit_value(b, 7)) << 4)
        | ((1U ^ (bit_value(a, 7) & bit_value(b, 6))) << 3)
        | ((1U ^ (bit_value(a, 7) & bit_value(b, 5))) << 2);
    const unsigned ps1 = (ps1_term1 + ps1_term2 + ps1_term3) & 0x1FU;

    const unsigned ps2_term1 =
        ((1U ^ (bit_value(a, 2) & bit_value(b, 7))) << 2)
        | ((bit_value(a, 2) & bit_value(b, 6)) << 1)
        | (bit_value(a, 2) & bit_value(b, 5));
    const unsigned ps2_term2 =
        ((1U ^ (bit_value(a, 3) & bit_value(b, 7))) << 3)
        | ((bit_value(a, 3) & bit_value(b, 6)) << 2)
        | ((bit_value(a, 3) & bit_value(b, 5)) << 1);
    const unsigned ps2_term3 =
        ((1U ^ (bit_value(a, 4) & bit_value(b, 7))) << 4)
        | ((bit_value(a, 4) & bit_value(b, 6)) << 3)
        | ((bit_value(a, 4) & bit_value(b, 5)) << 2);
    const unsigned ps2 =
        (ps2_term1 + ps2_term2 + ps2_term3 + 8U) & 0x3FU;

    const unsigned ps3_term1 =
        ((bit_value(a, 5) & bit_value(b, 4)) << 2)
        | ((bit_value(a, 5) & bit_value(b, 3)) << 1)
        | (bit_value(a, 5) & bit_value(b, 2));
    const unsigned ps3_term2 =
        ((bit_value(a, 6) & bit_value(b, 4)) << 3)
        | ((bit_value(a, 6) & bit_value(b, 3)) << 2)
        | ((bit_value(a, 6) & bit_value(b, 2)) << 1);
    const unsigned ps3_term3 =
        ((1U ^ (bit_value(a, 7) & bit_value(b, 4))) << 4)
        | ((1U ^ (bit_value(a, 7) & bit_value(b, 3))) << 3)
        | ((1U ^ (bit_value(a, 7) & bit_value(b, 2))) << 2);
    const unsigned ps3 = (ps3_term1 + ps3_term2 + ps3_term3) & 0x3FU;

    const unsigned ps4_term1 =
        ((bit_value(a, 2) & bit_value(b, 4)) << 2)
        | ((bit_value(a, 2) & bit_value(b, 3)) << 1)
        | (bit_value(a, 2) & bit_value(b, 2));
    const unsigned ps4_term2 =
        ((bit_value(a, 3) & bit_value(b, 4)) << 3)
        | ((bit_value(a, 3) & bit_value(b, 3)) << 2)
        | ((bit_value(a, 3) & bit_value(b, 2)) << 1);
    const unsigned ps4_term3 =
        ((bit_value(a, 4) & bit_value(b, 4)) << 4)
        | ((bit_value(a, 4) & bit_value(b, 3)) << 3)
        | ((bit_value(a, 4) & bit_value(b, 2)) << 2);
    const unsigned ps4 = (ps4_term1 + ps4_term2 + ps4_term3) & 0x3FU;

    const unsigned ps5_term1 =
        ((bit_value(a, 1) & bit_value(b, 6)) << 1)
        | (bit_value(a, 1) & bit_value(b, 5));
    const unsigned ps5_term2 =
        ((bit_value(a, 6) & bit_value(b, 1)) << 1)
        | (bit_value(a, 6) & bit_value(b, 0));
    const unsigned ps5 = (ps5_term1 + ps5_term2) & 0x7U;

    const unsigned raw = (
        (ps1 << 6) + (ps2 << 3) + (ps3 << 3) + ps4 + (ps5 << 2)
    ) & 0x7FFU;
    const int raw_signed = (raw & 0x400U)
        ? static_cast<int>(raw) - 0x800
        : static_cast<int>(raw);
    return product_t(raw_signed * 16);
}

void vakili_r1_mul8s_top(
    data_t weight,
    data_t activation,
    product_t& product
) {
    product = vakili_r1_mul8s(weight, activation);
}

static data_t relu_shift_clip(accum_t value, int shift) {
#pragma HLS INLINE
    if (value < 0) {
        return data_t(0);
    }
    const accum_t shifted = value >> shift;
    if (shifted > 127) {
        return data_t(127);
    }
    return data_t(shifted);
}

void vakili_r1_p16(
    const data_t input[NUM_INPUTS],
    const data_t weights[PARALLEL_LANES][WEIGHT_BANK_DEPTH],
    const accum_t biases[NUM_BIASES],
    accum_t outputs[NUM_OUTPUTS]
) {
#pragma HLS ARRAY_PARTITION variable=weights complete dim=1
#pragma HLS ALLOCATION function instances=vakili_r1_mul8s limit=16

    data_t hidden1[NUM_HIDDEN1];
    data_t hidden2[NUM_HIDDEN2];
    accum_t lane_acc[PARALLEL_LANES];

#pragma HLS ARRAY_PARTITION variable=hidden1 cyclic factor=16 dim=1
#pragma HLS ARRAY_PARTITION variable=hidden2 cyclic factor=16 dim=1
#pragma HLS ARRAY_PARTITION variable=lane_acc complete dim=1

layer1_groups:
    for (int group = 0; group < LAYER1_GROUPS; ++group) {
    layer1_init:
        for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
            const int output_index = group * PARALLEL_LANES + lane;
            lane_acc[lane] = biases[B1_BASE + output_index];
        }
    layer1_inputs:
        for (int index = 0; index < NUM_INPUTS; ++index) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=784 max=784
            const data_t activation = input[index];
            const int bank_index = W1_BANK_BASE + group * NUM_INPUTS + index;
        layer1_lanes:
            for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
                lane_acc[lane] += accum_t(vakili_r1_mul8s(
                    weights[lane][bank_index], activation
                ));
            }
        }
    layer1_store:
        for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
            const int output_index = group * PARALLEL_LANES + lane;
            hidden1[output_index] = relu_shift_clip(
                lane_acc[lane], HIDDEN1_SHIFT
            );
        }
    }

layer2_groups:
    for (int group = 0; group < LAYER2_GROUPS; ++group) {
    layer2_init:
        for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
            const int output_index = group * PARALLEL_LANES + lane;
            lane_acc[lane] = biases[B2_BASE + output_index];
        }
    layer2_inputs:
        for (int index = 0; index < NUM_HIDDEN1; ++index) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=64 max=64
            const data_t activation = hidden1[index];
            const int bank_index = W2_BANK_BASE + group * NUM_HIDDEN1 + index;
        layer2_lanes:
            for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
                lane_acc[lane] += accum_t(vakili_r1_mul8s(
                    weights[lane][bank_index], activation
                ));
            }
        }
    layer2_store:
        for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
            const int output_index = group * PARALLEL_LANES + lane;
            hidden2[output_index] = relu_shift_clip(
                lane_acc[lane], HIDDEN2_SHIFT
            );
        }
    }

layer3_groups:
    for (int group = 0; group < LAYER3_GROUPS; ++group) {
    layer3_init:
        for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
            const int output_index = group * PARALLEL_LANES + lane;
            lane_acc[lane] = output_index < NUM_OUTPUTS
                ? biases[B3_BASE + output_index]
                : accum_t(0);
        }
    layer3_inputs:
        for (int index = 0; index < NUM_HIDDEN2; ++index) {
#pragma HLS PIPELINE II=1
#pragma HLS LOOP_TRIPCOUNT min=32 max=32
            const data_t activation = hidden2[index];
            const int bank_index = W3_BANK_BASE + group * NUM_HIDDEN2 + index;
        layer3_lanes:
            for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
                lane_acc[lane] += accum_t(vakili_r1_mul8s(
                    weights[lane][bank_index], activation
                ));
            }
        }
    layer3_store:
        for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
#pragma HLS UNROLL
            const int output_index = group * PARALLEL_LANES + lane;
            if (output_index < NUM_OUTPUTS) {
                outputs[output_index] = lane_acc[lane];
            }
        }
    }
}

}  // namespace vakili_r1_p16

void vakili_r1_p16_top(
    const vakili_r1_p16::data_t input[vakili_r1_p16::NUM_INPUTS],
    const vakili_r1_p16::data_t
        weights[vakili_r1_p16::PARALLEL_LANES]
               [vakili_r1_p16::WEIGHT_BANK_DEPTH],
    const vakili_r1_p16::accum_t biases[vakili_r1_p16::NUM_BIASES],
    vakili_r1_p16::accum_t outputs[vakili_r1_p16::NUM_OUTPUTS]
) {
    vakili_r1_p16::vakili_r1_p16(input, weights, biases, outputs);
}

