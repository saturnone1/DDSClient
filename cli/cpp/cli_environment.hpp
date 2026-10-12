#include "DDSSimMessages.hpp"
#pragma once
namespace MSG = DdsModules_DDSSim::MSG;
namespace ENUM = DdsModules_DDSSim::ENUM;
namespace STRUCT = DdsModules_DDSSim::STRUCT;
#include "dds_cpp/configuration/DdsClientOptions.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <limits>
#include <string_view>

#include "dds_cpp/api/DdsConfigurationException.hpp"
#include "dds_cpp/api/DdsOperationException.hpp"
#include <optional>
#include "DdsUnicode.hpp"

namespace dds_cli {
using namespace dds_cpp;
namespace {

std::optional<std::string> environment(const char* key) {
    auto value = dds_cpp::detail::ReadUtf8Environment(key);
    if (!value || value->find_first_not_of(" \t\r\n") == std::string::npos) return std::nullopt;
    return value;
}

std::string trim(std::string value)
{
    const auto is_space = [](unsigned char ch) { return std::isspace(ch) != 0; };
    value.erase(value.begin(), std::find_if_not(value.begin(), value.end(), is_space));
    value.erase(std::find_if_not(value.rbegin(), value.rend(), is_space).base(), value.end());
    return value;
}

std::string lower(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::int32_t parse_domain_id(const std::string& value, const std::string& source)
{
    try {
        std::size_t consumed = 0;
        const auto parsed = std::stoll(trim(value), &consumed);
        if (consumed != trim(value).size() || parsed < (std::numeric_limits<std::int32_t>::min)() ||
            parsed > (std::numeric_limits<std::int32_t>::max)()) {
            throw std::out_of_range("domain");
        }
        return static_cast<std::int32_t>(parsed);
    } catch (const std::exception&) {
        throw DdsConfigurationException(source + "은(는) 정수여야 합니다.");
    }
}

DdsLogLevel parse_log_level(const std::string& value, const std::string& source)
{
    const auto normalized = lower(trim(value));
    if (normalized == "none") return DdsLogLevel::None;
    if (normalized == "error") return DdsLogLevel::Error;
    if (normalized == "info") return DdsLogLevel::Info;
    if (normalized == "debug") return DdsLogLevel::Debug;
    throw DdsConfigurationException(source + "은(는) None, Error, Info 또는 Debug여야 합니다.");
}

} // namespace

inline DdsClientOptions from_environment()
{
    DdsClientOptions options;
    options.MessageModules() = {dds_cpp::DDSSimMessages()};
    const auto multicast = environment("DDS_MULTICAST_RECEIVE_ADDRESS");
    const auto general_multicast = environment("DDS_MULTICAST_ADDRESS");
    options.MulticastReceiveAddress() = multicast ? *multicast : general_multicast.value_or("");
    if (const auto value = environment("DDS_SHUTDOWN_TIMEOUT_MS"))
        options.ShutdownTimeout() = std::chrono::milliseconds(std::stoi(*value));
    if (const auto value = environment("DDS_QOS_PROFILES_XML_PATH")) options.QosProfilesXmlPath() = *value;
    if (const auto value = environment("DDS_PARTICIPANT_NAME")) options.ParticipantName() = *value;
    if (const auto value = environment("DDS_DOMAIN_ID")) options.DomainId() = parse_domain_id(*value, "DDS_DOMAIN_ID");
    if (const auto value = environment("DDS_LOG_LEVEL")) options.LogLevel() = parse_log_level(*value, "DDS_LOG_LEVEL");

    return options;
}

} // namespace dds_cpp
