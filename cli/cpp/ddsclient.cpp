#include "cli_shell.hpp"
#include "DdsConfigurationReader.hpp"

#include <atomic>

namespace {

void print_usage()
{
    std::cout << "DDS 클라이언트 명령줄\n"
                 "  연결 옵션: --domain <id> --participant <name>\n"
                 "  --qos <path>\n"
                 "  ddsclient list [연결 옵션]\n"
                 "  ddsclient shell [연결 옵션]\n"
                 "  ddsclient idle [연결 옵션]\n"
                 "  ddsclient publish <MessageName> [연결 옵션] [--json <path>|--stdin] [--repeat <n>] [--interval-ms <n>] [--wait-for-subscribers <n>] [--wait-for-acks] [--wait-timeout-ms <n>]\n"
                 "  ddsclient subscribe <MessageName> [연결 옵션] [--count <n>] [--timeout-ms <n>]\n";
}

} // namespace

int run(const std::vector<std::string>& arguments)
{
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    if (arguments.size() < 2) { print_usage(); return 1; }
    const std::string command = lower(arguments[1]);
    if (command == "help" || command == "-h" || command == "--help") { print_usage(); return 0; }
    try {
        std::vector<std::string> args(arguments.begin() + 2, arguments.end());
        const auto options = parse_options(args);
        if (command == "list") {
            const auto& client_options = options.connection;
            print_topics(dds_cpp::DdsConfigurationReader::Load(client_options));
            return 0;
        }
        if (command == "shell" || command == "daemon") return run_shell(options);
        if (command == "idle" || command == "wait") {
            auto client = connect(options);
            std::cout << "DDS participant가 초기화되었습니다. domain=" << client.Options().DomainId() << '\n';
            while (!stopped) std::this_thread::sleep_for(std::chrono::milliseconds(100));
            return 0;
        }
        if (options.topic.empty()) throw std::invalid_argument("메시지/topic 이름이 필요합니다.");
        auto client = connect(options);
        if (command == "publish" || command == "send") { publish(client, options); return 0; }
        if (command == "subscribe" || command == "listen") {
            std::atomic_int received_count{0};
            auto subscription = subscribe(client, options.topic, [&] { ++received_count; });
            std::cout << "수신 대기 중: " << options.topic << ", DDS domain=" << client.Options().DomainId() << '\n';
            const auto started = std::chrono::steady_clock::now();
            while (!stopped && (options.count == 0 || received_count.load() < options.count)) {
                if (options.timeout_ms > 0 &&
                    std::chrono::steady_clock::now() - started >= std::chrono::milliseconds(options.timeout_ms)) {
                    if (options.count > 0) throw std::runtime_error("수신 대기 시간이 초과되었습니다.");
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            return 0;
        }
        std::cerr << "알 수 없는 명령입니다: " << command << '\n';
        print_usage();
        return 1;
    } catch (const std::exception& exception) {
        std::cerr << exception.what() << '\n';
        return 1;
    }
}

#if defined(_WIN32)
int wmain(int argc, wchar_t** argv)
{
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
    try {
        std::vector<std::string> arguments;
        for (int i = 0; i < argc; ++i) arguments.push_back(dds_cpp::detail::to_utf8(argv[i]));
        return run(arguments);
    } catch (const std::exception& exception) {
        std::cerr << exception.what() << '\n';
        return 1;
    }
}
#else
int main(int argc, char** argv)
{
    return run(std::vector<std::string>(argv, argv + argc));
}
#endif
