#pragma once

// ddsclient.cpp에서만 포함하는 CLI 내부 구현이다.
#include "cli_environment.hpp"

#include <algorithm>
#include <cctype>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct CliOptions {
    dds_cpp::DdsClientOptions connection = dds_cli::from_environment();
    std::string topic;
    std::string json_path;
    bool read_stdin{};
    int count{};
    int timeout_ms{};
    int repeat{1};
    int interval_ms{};
    int wait_for_subscribers{}; // 0은 대기 없음. 양수는 명시적으로 선택한 진단용 대기다.
    int wait_timeout_ms{10000};
    bool wait_for_acks{};
};
std::string lower(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string read_value(const std::vector<std::string>& args, std::size_t& index)
{
    if (++index >= args.size()) throw std::invalid_argument(args[index - 1] + " 옵션에는 값이 필요합니다.");
    return args[index];
}

int read_integer(const std::vector<std::string>& args, std::size_t& index, bool positive)
{
    const auto option = args[index];
    const auto value = read_value(args, index);
    try {
        std::size_t consumed = 0;
        const auto parsed = std::stoll(value, &consumed);
        if (consumed != value.size() || parsed > (std::numeric_limits<int>::max)() ||
            (positive ? parsed <= 0 : parsed < 0)) throw std::invalid_argument("range");
        return static_cast<int>(parsed);
    } catch (const std::exception&) {
        throw std::invalid_argument(option + (positive
            ? " 옵션에는 1 이상의 정수가 필요합니다."
            : " 옵션에는 0 이상의 정수가 필요합니다."));
    }
}

CliOptions parse_options(const std::vector<std::string>& args)
{
    CliOptions options;
    for (std::size_t i = 0; i < args.size(); ++i) {
        if (args[i] == "--domain") options.connection.DomainId() = read_integer(args, i, false);
        else if (args[i] == "--participant") options.connection.ParticipantName() = read_value(args, i);
        else if (args[i] == "--qos") options.connection.QosProfilesXmlPath() = read_value(args, i);
        else if (args[i] == "--json" || args[i] == "-j") options.json_path = read_value(args, i);
        else if (args[i] == "--stdin") options.read_stdin = true;
        else if (args[i] == "--count") options.count = read_integer(args, i, false);
        else if (args[i] == "--timeout-ms") options.timeout_ms = read_integer(args, i, false);
        else if (args[i] == "--wait-for-subscribers") options.wait_for_subscribers = read_integer(args, i, false);
        else if (args[i] == "--wait-timeout-ms") options.wait_timeout_ms = read_integer(args, i, true);
        else if (args[i] == "--wait-for-acks") options.wait_for_acks = true;
        else if (args[i] == "--repeat") options.repeat = read_integer(args, i, true);
        else if (args[i] == "--interval-ms") options.interval_ms = read_integer(args, i, false);
        else if (!args[i].empty() && args[i].front() == '-') {
            throw std::invalid_argument("알 수 없는 옵션입니다: " + args[i]);
        } else if (options.topic.empty()) options.topic = args[i];
        else throw std::invalid_argument("예상하지 않은 추가 인수입니다: " + args[i]);
    }
    if (!options.json_path.empty() && options.read_stdin) {
        throw std::invalid_argument("--json과 --stdin은 동시에 사용할 수 없습니다.");
    }
    return options;
}

} // namespace
