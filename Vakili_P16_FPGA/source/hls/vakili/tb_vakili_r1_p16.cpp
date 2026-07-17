#include "vakili_r1_p16.h"

#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::vector<long long> read_values(const std::string& path) {
    std::ifstream stream(path);
    if (!stream) {
        throw std::runtime_error("Could not open " + path);
    }
    std::vector<long long> values;
    long long value = 0;
    while (stream >> value) {
        values.push_back(value);
    }
    return values;
}

std::string read_first_line_or(
    const std::string& path,
    const std::string& fallback
) {
    std::ifstream stream(path);
    if (!stream) {
        return fallback;
    }
    std::string value;
    std::getline(stream, value);
    return value.empty() ? fallback : value;
}

std::string json_escape(const std::string& value) {
    std::string result;
    result.reserve(value.size());
    for (const char character : value) {
        switch (character) {
        case '\\': result += "\\\\"; break;
        case '"': result += "\\\""; break;
        case '\b': result += "\\b"; break;
        case '\f': result += "\\f"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default: result += character; break;
        }
    }
    return result;
}

long long as_long_long(vakili_r1_p16::accum_t value) {
#ifdef VAKILI_R1_AP_INT
    return value.to_int64();
#else
    return static_cast<long long>(value);
#endif
}

long long product_as_long_long(vakili_r1_p16::product_t value) {
#ifdef VAKILI_R1_AP_INT
    return value.to_int64();
#else
    return static_cast<long long>(value);
#endif
}

int argmax(const vakili_r1_p16::accum_t values[vakili_r1_p16::NUM_OUTPUTS]) {
    int result = 0;
    for (int index = 1; index < vakili_r1_p16::NUM_OUTPUTS; ++index) {
        if (values[index] > values[result]) {
            result = index;
        }
    }
    return result;
}

void write_report(
    const std::string& path,
    const std::string& status,
    const std::string& model_id,
    const std::string& manifest_path,
    long long multiplier_mismatches,
    std::size_t samples,
    long long logit_mismatches,
    long long prediction_mismatches,
    long long correct
) {
    if (path.empty()) {
        return;
    }
    std::ofstream stream(path);
    if (!stream) {
        throw std::runtime_error("Could not write " + path);
    }
    stream << "{\n"
           << "  \"schema_version\": 1,\n"
           << "  \"stage\": \"vakili_r1_p16_host_or_hls_csim\",\n"
           << "  \"status\": \"" << status << "\",\n"
           << "  \"model_id\": \"" << json_escape(model_id) << "\",\n"
           << "  \"frozen_manifest\": \"" << json_escape(manifest_path) << "\",\n"
           << "  \"hardware_call_order\": \"R1(weight, activation)\",\n"
           << "  \"adapt_lut_index_order\": \"lut[activation_byte][weight_byte]\",\n"
           << "  \"hidden_shifts\": [9, 9],\n"
           << "  \"signed_activation_weight_truth_sha256\": \"4bb7ec402d3ae050cbff31e9e99c4ec5350d18b586dcbaa502be7c561557503e\",\n"
           << "  \"multiplier_pairs\": 65536,\n"
           << "  \"multiplier_mismatches\": " << multiplier_mismatches << ",\n"
           << "  \"network_samples\": " << samples << ",\n"
           << "  \"network_logits\": " << samples * vakili_r1_p16::NUM_OUTPUTS << ",\n"
           << "  \"network_logit_mismatches\": " << logit_mismatches << ",\n"
           << "  \"network_prediction_mismatches\": " << prediction_mismatches << ",\n"
           << "  \"label_correct\": " << correct << ",\n"
           << "  \"official_test_evaluated\": false\n"
           << "}\n";
}

}  // namespace

int main(int argc, char** argv) {
    using namespace vakili_r1_p16;
    if (argc < 2 || argc > 3) {
        std::cerr << "Usage: tb_vakili_r1_p16 <reference-dir> [report-json]\n";
        return 2;
    }
    const std::string data_dir = argv[1];
    const std::string report_path = argc == 3 ? argv[2] : std::string();
    const std::string model_id = read_first_line_or(
        data_dir + "/model_id.txt",
        "mnist_mlp_784_64_32_10_fixed_vakili_r1_ptq_development_20260714"
    );
    const std::string manifest_path = read_first_line_or(
        data_dir + "/manifest_path.txt",
        "architectures/vakili_adapt_ga_hls/models/manifests/"
        "hardware_exact_int8_development_frozen.json"
    );

    long long multiplier_mismatches = 0;
    long long logit_mismatches = 0;
    long long prediction_mismatches = 0;
    long long correct = 0;
    std::size_t sample_count = 0;

    try {
        const auto truth = read_values(
            data_dir + "/vakili_r1_activation_weight_truth.txt"
        );
        if (truth.size() != 65536U) {
            throw std::runtime_error("Unexpected Vakili-R1 truth-table size");
        }
        // File order is signed activation-major, weight-minor. The HLS call
        // remains weight first; swapping these operands changes 35,328 pairs.
        std::size_t truth_index = 0;
        for (int activation = -128; activation <= 127; ++activation) {
            for (int weight = -128; weight <= 127; ++weight, ++truth_index) {
                const long long actual = product_as_long_long(vakili_r1_mul8s(
                    data_t(weight), data_t(activation)
                ));
                const long long expected = truth[truth_index];
                if (actual != expected) {
                    ++multiplier_mismatches;
                    if (multiplier_mismatches <= 20) {
                        std::cerr << "MULTIPLIER_MISMATCH activation="
                                  << activation << " weight=" << weight
                                  << " got=" << actual
                                  << " expected=" << expected << '\n';
                    }
                }
            }
        }

        const auto weight_values = read_values(data_dir + "/weight_banks.txt");
        const auto bias_values = read_values(data_dir + "/biases.txt");
        const auto input_values = read_values(data_dir + "/inputs.txt");
        const auto expected_values = read_values(data_dir + "/logits.txt");
        const auto labels = read_values(data_dir + "/labels.txt");

        if (weight_values.size() != PARALLEL_LANES * WEIGHT_BANK_DEPTH) {
            throw std::runtime_error("Unexpected P16 weight-bank value count");
        }
        if (bias_values.size() != NUM_BIASES) {
            throw std::runtime_error("Unexpected bias value count");
        }
        if (labels.empty()) {
            throw std::runtime_error("No network samples were exported");
        }
        sample_count = labels.size();
        if (input_values.size() != sample_count * NUM_INPUTS) {
            throw std::runtime_error("Unexpected input value count");
        }
        if (expected_values.size() != sample_count * NUM_OUTPUTS) {
            throw std::runtime_error("Unexpected logit value count");
        }

        static data_t weights[PARALLEL_LANES][WEIGHT_BANK_DEPTH];
        static accum_t biases[NUM_BIASES];
        static data_t input[NUM_INPUTS];
        static accum_t outputs[NUM_OUTPUTS];
        for (int lane = 0; lane < PARALLEL_LANES; ++lane) {
            for (int index = 0; index < WEIGHT_BANK_DEPTH; ++index) {
                weights[lane][index] = data_t(
                    weight_values[lane * WEIGHT_BANK_DEPTH + index]
                );
            }
        }
        for (int index = 0; index < NUM_BIASES; ++index) {
            biases[index] = accum_t(bias_values[index]);
        }

        for (std::size_t sample = 0; sample < sample_count; ++sample) {
            for (int index = 0; index < NUM_INPUTS; ++index) {
                input[index] = data_t(input_values[sample * NUM_INPUTS + index]);
            }
            vakili_r1_p16_top(input, weights, biases, outputs);

            int reference_prediction = 0;
            for (int output = 0; output < NUM_OUTPUTS; ++output) {
                const long long expected = expected_values[
                    sample * NUM_OUTPUTS + output
                ];
                const long long actual = as_long_long(outputs[output]);
                if (actual != expected) {
                    ++logit_mismatches;
                    if (logit_mismatches <= 20) {
                        std::cerr << "LOGIT_MISMATCH sample=" << sample
                                  << " output=" << output << " got=" << actual
                                  << " expected=" << expected << '\n';
                    }
                }
                if (expected > expected_values[
                        sample * NUM_OUTPUTS + reference_prediction
                    ]) {
                    reference_prediction = output;
                }
            }
            const int actual_prediction = argmax(outputs);
            prediction_mismatches += actual_prediction != reference_prediction ? 1 : 0;
            correct += actual_prediction == labels[sample] ? 1 : 0;
        }

        const bool pass = multiplier_mismatches == 0
            && logit_mismatches == 0
            && prediction_mismatches == 0;
        write_report(
            report_path, pass ? "PASS" : "FAIL", model_id, manifest_path,
            multiplier_mismatches, sample_count, logit_mismatches,
            prediction_mismatches, correct
        );
        if (!pass) {
            std::cerr << "VAKILI_R1_P16_EQUIVALENCE_FAIL\n";
            return 1;
        }
        std::cout << "VAKILI_R1_P16_EQUIVALENCE_PASS\n"
                  << "Vakili-R1 multiplier pairs: 65536/65536\n"
                  << "Network logits: " << sample_count * NUM_OUTPUTS << '/'
                  << sample_count * NUM_OUTPUTS << "\n"
                  << "Label accuracy: " << correct << '/' << sample_count << '\n';
        return 0;
    } catch (const std::exception& exception) {
        try {
            write_report(
                report_path, "ERROR", model_id, manifest_path,
                multiplier_mismatches, sample_count, logit_mismatches,
                prediction_mismatches, correct
            );
        } catch (...) {
        }
        std::cerr << "Testbench error: " << exception.what() << '\n';
        return 2;
    }
}
