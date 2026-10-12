#include "AddedAfterFreezeMessages.hpp"
#include <dds_cpp/api/DdsClient.hpp>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using Sample = DdsModules_AddedAfterFreeze::CompatibilityProbe::ProbeSample;

int main(int argc, char** argv)
{
    try {
        if (argc != 4) throw std::runtime_error("Expected QoS path, domain and unique topic.");
        dds_cpp::DdsClientOptions options;
        options.DomainId() = std::stoi(argv[2]);
        options.QosProfilesXmlPath() = argv[1];
        options.MessageModules() = {dds_cpp::AddedAfterFreezeMessages()};
        options.Topics() = std::vector<dds_cpp::TopicDefinition>{dds_cpp::Topic::Named<Sample>(argv[3])};
        std::mutex mutex;
        std::condition_variable arrived;
        std::vector<std::pair<std::uint64_t, bool>> values;
        {
            auto receiver = dds_cpp::DdsClient::Connect(options);
            auto subscription = receiver.Subscribe<Sample>([&](const Sample& sample) {
                std::lock_guard lock(mutex);
                values.emplace_back(sample.Counter(), sample.Healthy());
                arrived.notify_all();
            });
            auto sender = dds_cpp::DdsClient::Connect(options);
            auto publisher = sender.CreatePublisher<Sample>();
            publisher.WaitForSubscribers(1, std::chrono::seconds(15));
            for (std::uint64_t i = 1; i <= 4; ++i) {
                Sample sample; sample.Counter(i); sample.Healthy(true); publisher.Publish(sample);
            }
            publisher.WaitForAcknowledgments(std::chrono::seconds(10));
            std::unique_lock lock(mutex);
            if (!arrived.wait_for(lock, std::chrono::seconds(10), [&] { return values.size() >= 4; }))
                throw std::runtime_error("New-module RTI delivery timed out.");
        }
        std::lock_guard lock(mutex);
        if (values != std::vector<std::pair<std::uint64_t, bool>>{{1, true}, {2, true}, {3, true}, {4, true}})
            throw std::runtime_error("Expected exactly four ordered new-module RTI samples with intact payloads.");
        std::cout << "MODULE_ADDITION_PASS cpp 4\n";
        return 0;
    }
    catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
