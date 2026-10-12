#pragma once

// ddsclient.cpp에서만 포함하는 CLI 내부 구현이다.
#include "cli_options.hpp"
#include "dds_cpp/DdsCpp.hpp"

#include <chrono>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <sstream>
#include <thread>
#include <unordered_map>

#include <dds/dds.hpp>
#include <ndds/ndds_c.h>
#include <ndds/dds_c/dds_c_dynamicdataformatter.h>
#include <rti/apputils/DynamicDataConverter.hpp>

namespace {

dds_cpp::DdsClient connect(const CliOptions& options)
{
    return dds_cpp::DdsClient::Connect(options.connection);
}

std::string read_json(const CliOptions& options)
{
    if (!options.json_path.empty()) {
        std::ifstream input(std::filesystem::u8path(options.json_path), std::ios::binary);
        if (!input) throw std::invalid_argument("JSON 파일을 읽을 수 없습니다: " + options.json_path);
        std::ostringstream content;
        content << input.rdbuf();
        return content.str();
    }
    if (options.read_stdin) {
        std::ostringstream content;
        content << std::cin.rdbuf();
        return content.str();
    }
    return {};
}

std::string normalize_json_names(std::string json)
{
    static const std::unordered_map<std::string, std::string> canonical_names = [] {
        std::unordered_map<std::string, std::string> names;
#define DDSCPP_JSON_NAME(name) names.emplace(lower(name), name);
#include "dds_cpp_json_names.inc"
#undef DDSCPP_JSON_NAME
        return names;
    }();

    std::size_t cursor = 0;
    while ((cursor = json.find('"', cursor)) != std::string::npos) {
        const auto value_begin = ++cursor;
        bool escaped = false;
        while (cursor < json.size()) {
            if (json[cursor] == '\\') { escaped = true; cursor += 2; continue; }
            if (json[cursor] == '"') break;
            ++cursor;
        }
        if (cursor >= json.size()) break;
        auto after_quote = cursor + 1;
        while (after_quote < json.size() &&
               std::isspace(static_cast<unsigned char>(json[after_quote]))) ++after_quote;
        const auto is_member_name = after_quote < json.size() && json[after_quote] == ':';
        if (!escaped && is_member_name) {
            const auto value = json.substr(value_begin, cursor - value_begin);
            if (const auto found = canonical_names.find(lower(value)); found != canonical_names.end()) {
                json.replace(value_begin, cursor - value_begin, found->second);
                cursor = value_begin + found->second.size();
            }
        }
        ++cursor;
    }
    return json;
}

bool contains_json_member(const std::string& json, const std::string& member_name)
{
    if (json.empty()) return false;
    const auto normalized = normalize_json_names(json);
    const auto needle = "\"" + member_name + "\"";
    std::size_t cursor = 0;
    while ((cursor = normalized.find(needle, cursor)) != std::string::npos) {
        auto after = cursor + needle.size();
        while (after < normalized.size() && std::isspace(static_cast<unsigned char>(normalized[after]))) ++after;
        if (after < normalized.size() && normalized[after] == ':') return true;
        cursor = after;
    }
    return false;
}

template <class T>
T from_json(const std::string& json)
{
    T sample;
    if (json.empty()) return sample;

    const auto& type = rti::topic::dynamic_type<T>::get();
    dds::core::xtypes::DynamicData dynamic_sample(type);
    const auto normalized_json = normalize_json_names(json);
    if (DDS_DynamicDataFormatter_from_json(&dynamic_sample.native(), normalized_json.c_str()) != DDS_RETCODE_OK) {
        throw std::invalid_argument("JSON을 요청한 DDS 메시지 타입으로 변환할 수 없습니다.");
    }

    rti::apputils::DynamicDataConverter converter(
        type, rti::apputils::DynamicBufferProperty(64 * 1024, false));
    auto buffer = converter.buffer(dynamic_sample, DDS_XCDR_DATA_REPRESENTATION);
    const auto* begin = buffer.get<const char>();
    std::vector<char> cdr(begin, begin + buffer.length());
    using topic_support = dds::topic::topic_type_support<T>;
    topic_support::from_cdr_buffer(sample, cdr);
    return sample;
}

ENUM::SimulatorID simulator_id(const char* variable, ENUM::SimulatorID default_value)
{
    const auto value = dds_cli::environment(variable);
    if (!value) return default_value;
    const auto selected = lower(*value);
#define DDSCPP_SIM_ID(name) if (selected == lower(#name)) return ENUM::SimulatorID::name
    DDSCPP_SIM_ID(TCC); DDSCPP_SIM_ID(TDS); DDSCPP_SIM_ID(VGD); DDSCPP_SIM_ID(DOLU);
    DDSCPP_SIM_ID(ELU); DDSCPP_SIM_ID(ATS_A); DDSCPP_SIM_ID(ATS_B); DDSCPP_SIM_ID(ATS_C);
    DDSCPP_SIM_ID(ATS_D); DDSCPP_SIM_ID(MSS_A); DDSCPP_SIM_ID(MSS_B);
#undef DDSCPP_SIM_ID
    throw std::invalid_argument(std::string(variable) + "의 SimulatorID 값이 잘못되었습니다: " + *value);
}

template <class T>
void apply_defaults(T& sample, ENUM::MessageID message_id, const std::string& json)
{
    if constexpr (requires(T& value) { value.Header(); }) {
        auto& header = sample.Header();
        if (header.TimeStamp() == 0) {
            const auto now = std::chrono::system_clock::now().time_since_epoch();
            header.TimeStamp(static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(now).count()));
        }
        if (!contains_json_member(json, "MsgID") || static_cast<int>(header.MsgID()) == 0) {
            header.MsgID(message_id);
        }
        if (!contains_json_member(json, "SrcSimID") || static_cast<int>(header.SrcSimID()) == 0) {
            header.SrcSimID(simulator_id("DDS_CLI_SRC_SIM_ID", ENUM::SimulatorID::TCC));
        }
        if (!contains_json_member(json, "DstSimID") || static_cast<int>(header.DstSimID()) == 0) {
            header.DstSimID(simulator_id("DDS_CLI_DST_SIM_ID", ENUM::SimulatorID::TDS));
        }
    }
}

void publish(dds_cpp::DdsClient& client, const CliOptions& options)
{
    const auto json = read_json(options);
#define DDSCPP_REGISTER_RTI_TYPE(cpp_type, enum_name, dds_name) \
    if (options.topic == dds_name) { \
        auto sample = from_json<cpp_type>(json); \
        apply_defaults(sample, ENUM::MessageID::enum_name, json); \
        auto publisher = client.CreatePublisher<cpp_type>(); \
        if (options.wait_for_subscribers > 0) publisher.WaitForSubscribers(options.wait_for_subscribers, std::chrono::milliseconds(options.wait_timeout_ms)); \
        for (int index = 0; index < options.repeat; ++index) { \
            publisher.Publish(sample); \
            if (index + 1 < options.repeat && options.interval_ms > 0) \
                std::this_thread::sleep_for(std::chrono::milliseconds(options.interval_ms)); \
        } \
        if (options.wait_for_acks) publisher.WaitForAcknowledgments(std::chrono::milliseconds(options.wait_timeout_ms)); \
        std::cout << "DDS 발행 완료: " << options.topic << " (MSG::" << dds_name << "), count=" << options.repeat << "\n"; \
        return; \
    }
#include "dds_cpp_rti_type_registry.inc"
#undef DDSCPP_REGISTER_RTI_TYPE
    throw dds_cpp::DdsConfigurationException("MSG." + options.topic + " 타입을 찾을 수 없습니다.");
}

std::unique_ptr<dds_cpp::Subscription> subscribe(
    dds_cpp::DdsClient& client,
    const std::string& topic,
    std::function<void()> on_sample = {})
{
#define DDSCPP_REGISTER_RTI_TYPE(cpp_type, enum_name, dds_name) \
    if (topic == dds_name) { \
        return client.Subscribe<cpp_type>([topic, on_sample](const cpp_type& sample) { \
            std::cout << '\n' << topic << '\n' << sample << std::endl; \
            if (on_sample) on_sample(); \
        }); \
    }
#include "dds_cpp_rti_type_registry.inc"
#undef DDSCPP_REGISTER_RTI_TYPE
    throw dds_cpp::DdsConfigurationException("MSG." + topic + " 타입을 찾을 수 없습니다.");
}

void print_topics(const dds_cpp::DdsConfiguration& configuration)
{
    auto topics = configuration.Topics();
    std::sort(topics.begin(), topics.end(), [](const auto& left, const auto& right) {
        return left.name < right.name;
    });
    for (const auto& topic : topics) {
        const char* direction = topic.direction == dds_cpp::TopicDirection::Both ? "Both"
            : topic.direction == dds_cpp::TopicDirection::Publish ? "Publish" : "Subscribe";
        std::cout << topic.name << " direction=" << direction
                  << " qos=" << topic.QualifiedQosProfile() << '\n';
    }
}

} // namespace
