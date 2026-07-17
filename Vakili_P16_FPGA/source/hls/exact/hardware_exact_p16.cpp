#include "hardware_exact_p16.h"

namespace hardware_exact_p16 {

product_t exact_mul8s(data_t lhs, data_t rhs) {
#pragma HLS INLINE
    const product_t product = product_t(lhs) * product_t(rhs);
#pragma HLS BIND_OP variable=product op=mul impl=fabric
    return product;
}

void exact_mul8s_top(data_t lhs, data_t rhs, product_t& product) {
    product = exact_mul8s(lhs, rhs);
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

void hardware_exact_p16(
    const data_t input[NUM_INPUTS],
    const data_t weights[PARALLEL_LANES][WEIGHT_BANK_DEPTH],
    const accum_t biases[NUM_BIASES],
    accum_t outputs[NUM_OUTPUTS]
) {
#pragma HLS ARRAY_PARTITION variable=weights complete dim=1
#pragma HLS ALLOCATION function instances=exact_mul8s limit=16

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
                lane_acc[lane] += accum_t(
                    exact_mul8s(weights[lane][bank_index], activation)
                );
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
                lane_acc[lane] += accum_t(
                    exact_mul8s(weights[lane][bank_index], activation)
                );
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
                lane_acc[lane] += accum_t(
                    exact_mul8s(weights[lane][bank_index], activation)
                );
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

}  // namespace hardware_exact_p16

void hardware_exact_p16_top(
    const hardware_exact_p16::data_t input[hardware_exact_p16::NUM_INPUTS],
    const hardware_exact_p16::data_t
        weights[hardware_exact_p16::PARALLEL_LANES]
               [hardware_exact_p16::WEIGHT_BANK_DEPTH],
    const hardware_exact_p16::accum_t
        biases[hardware_exact_p16::NUM_BIASES],
    hardware_exact_p16::accum_t
        outputs[hardware_exact_p16::NUM_OUTPUTS]
) {
    hardware_exact_p16::hardware_exact_p16(input, weights, biases, outputs);
}


void vakili_r1_p16_top(
    const hardware_exact_p16::data_t input[hardware_exact_p16::NUM_INPUTS],
    const hardware_exact_p16::data_t
        weights[hardware_exact_p16::PARALLEL_LANES]
               [hardware_exact_p16::WEIGHT_BANK_DEPTH],
    const hardware_exact_p16::accum_t
        biases[hardware_exact_p16::NUM_BIASES],
    hardware_exact_p16::accum_t
        outputs[hardware_exact_p16::NUM_OUTPUTS]
) {
    hardware_exact_p16::hardware_exact_p16(input, weights, biases, outputs);
}
