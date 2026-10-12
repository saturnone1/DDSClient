#pragma once

// ddsclient.cpp에서만 포함하는 CLI 내부 구현이다.
#include "cli_commands.hpp"

#include <csignal>

namespace {

volatile std::sig_atomic_t stopped = 0;

void on_signal(int) { stopped = 1; }
std::vector<std::string> split_line(const std::string& line)
{
    std::vector<std::string> result;
    std::string token;
    bool quoted = false;
    for (const char ch : line) {
        if (ch == '"') quoted = !quoted;
        else if (std::isspace(static_cast<unsigned char>(ch)) && !quoted) {
            if (!token.empty()) { result.push_back(std::move(token)); token.clear(); }
        } else token += ch;
    }
    if (!token.empty()) result.push_back(std::move(token));
    return result;
}

void print_shell_help()
{
    std::cout << "list | status | subscribe <topic> | publish <topic> [--json path] | "
                 "unsubscribe <topic|all> | help | exit\n";
}

int run_shell(const CliOptions& options)
{
    auto client = connect(options);
    std::unordered_map<std::string, std::unique_ptr<dds_cpp::Subscription>> subscriptions;
    std::cout << "DDS 클라이언트 대화형 모드 - domain=" << client.Options().DomainId() << '\n';
    print_shell_help();
    std::string line;
    while (!stopped) {
        std::cout << "ddsclient(도움말)> " << std::flush;
        if (!std::getline(std::cin, line)) break;
        auto tokens = split_line(line);
        if (tokens.empty()) continue;
        try {
            const auto command = lower(tokens.front());
            if (command == "exit" || command == "quit") break;
            if (command == "help" || command == "?") print_shell_help();
            else if (command == "list") print_topics(client.Configuration());
            else if (command == "status") {
                std::cout << "domain=" << client.Options().DomainId()
                          << ", 수신 중인 topic=" << subscriptions.size() << '\n';
            } else if (command == "publish" || command == "send") {
                publish(client, parse_options(std::vector<std::string>(tokens.begin() + 1, tokens.end())));
            } else if (command == "subscribe" || command == "listen") {
                const auto nested = parse_options(std::vector<std::string>(tokens.begin() + 1, tokens.end()));
                if (nested.topic.empty()) throw std::invalid_argument("메시지/topic 이름이 필요합니다.");
                if (nested.read_stdin) throw std::invalid_argument("shell 모드에서는 --stdin을 지원하지 않습니다.");
                if (!subscriptions.contains(nested.topic)) subscriptions[nested.topic] = subscribe(client, nested.topic);
            } else if (command == "unsubscribe" || command == "unsub") {
                if (tokens.size() < 2) throw std::invalid_argument("unsubscribe에는 topic 이름 또는 all이 필요합니다.");
                if (tokens[1] == "all") subscriptions.clear(); else subscriptions.erase(tokens[1]);
            } else std::cerr << "알 수 없는 shell 명령입니다: " << command << '\n';
        } catch (const std::exception& exception) {
            std::cerr << "[오류] " << exception.what() << '\n';
        }
    }
    return 0;
}

} // namespace
