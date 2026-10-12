using DdsAmbassador.DDSClient;

internal partial class Program
{
    private static async Task<int> Main(string[] args)
    {
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        var command = args.FirstOrDefault();
        if (string.IsNullOrWhiteSpace(command) || IsHelp(command))
        {
            PrintUsage();
            return command is null ? 1 : 0;
        }

        try
        {
            var options = CliOptions.Parse(args.Skip(1).ToArray());
            switch (command.ToLowerInvariant())
            {
                case "list":
                    var clientOptions = options.Connection;
                    var configuration = DdsConfigurationReader.Load(clientOptions);
                    PrintTopics(configuration);

                    return 0;

                case "shell":
                case "daemon":
                    return await RunShell(options).ConfigureAwait(false);

                case "idle":
                case "wait":
                    using (var client = DdsClient.Connect(options.Connection))
                    using (var shutdown = new CancellationTokenSource())
                    {
                        Console.CancelKeyPress += (_, eventArgs) =>
                        {
                            eventArgs.Cancel = true;
                            shutdown.Cancel();
                        };

                        Console.WriteLine(
                            $"DDS participant가 초기화되었습니다. domain={client.Options.DomainId}. 중지하려면 Ctrl+C를 누르세요.");
                        await Task.Delay(Timeout.InfiniteTimeSpan, shutdown.Token).ConfigureAwait(false);
                    }

                    return 0;

                case "publish":
                case "send":
                    RequireTopic(options.Topic);
                    var publishTopic = options.Topic!;
                    using (var client = DdsClient.Connect(options.Connection))
                    {
                        var sampleType = ResolveMessageType(publishTopic);
                        var sample = await CreateSample(sampleType, options);
                        await PublishBatch(client, publishTopic, sampleType, sample, options, CancellationToken.None);
                        Console.WriteLine($"DDS 발행 완료: {publishTopic} ({sampleType.FullName}), count={options.Repeat}");
                    }

                    return 0;

                case "subscribe":
                case "listen":
                    RequireTopic(options.Topic);
                    var subscribeTopic = options.Topic!;
                    using (var client = DdsClient.Connect(options.Connection))
                    using (var shutdown = new CancellationTokenSource())
                    {
                        Console.CancelKeyPress += (_, eventArgs) =>
                        {
                            eventArgs.Cancel = true;
                            shutdown.Cancel();
                        };

                        var sampleType = ResolveMessageType(subscribeTopic);
                        var receivedCount = 0;
                        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                        using var subscription = client.Subscribe(subscribeTopic, sampleType, sample =>
                        {
                            Console.WriteLine($"[{DateTimeOffset.Now:O}] {subscribeTopic}");
                            Console.WriteLine(sample);
                            if (options.Count > 0 && Interlocked.Increment(ref receivedCount) >= options.Count)
                            {
                                completed.TrySetResult();
                            }
                        });

                        Console.WriteLine($"수신 대기 중: {subscribeTopic}, DDS domain={client.Options.DomainId}. 중지하려면 Ctrl+C를 누르세요.");
                        if (options.Count > 0)
                        {
                            if (options.TimeoutMs > 0)
                            {
                                await completed.Task.WaitAsync(TimeSpan.FromMilliseconds(options.TimeoutMs), shutdown.Token).ConfigureAwait(false);
                            }
                            else
                            {
                                await completed.Task.WaitAsync(shutdown.Token).ConfigureAwait(false);
                            }
                        }
                        else if (options.TimeoutMs > 0)
                        {
                            await Task.Delay(options.TimeoutMs, shutdown.Token).ConfigureAwait(false);
                        }
                        else
                        {
                            await Task.Delay(Timeout.InfiniteTimeSpan, shutdown.Token).ConfigureAwait(false);
                        }
                    }

                    return 0;

                default:
                    Console.Error.WriteLine($"알 수 없는 명령입니다: {command}");
                    PrintUsage();
                    return 1;
            }
        }
        catch (OperationCanceledException)
        {
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    static bool IsHelp(string value)
    {
        return value.Equals("-h", StringComparison.OrdinalIgnoreCase)
            || value.Equals("--help", StringComparison.OrdinalIgnoreCase)
            || value.Equals("help", StringComparison.OrdinalIgnoreCase);
    }

    static void RequireTopic(string? topic)
    {
        if (string.IsNullOrWhiteSpace(topic))
        {
            throw new ArgumentException("메시지/topic 이름이 필요합니다.");
        }
    }

    static void PrintTopics(DdsConfiguration configuration)
    {
        foreach (var topic in configuration.Topics.OrderBy(topic => topic.Name, StringComparer.Ordinal))
        {
            Console.WriteLine($"{topic.Name} direction={topic.Direction} qos={topic.QualifiedQosProfile}");
        }
    }

    static void PrintUsage()
    {
        Console.WriteLine(
            """
            DDS 클라이언트 명령줄

            사용법:
              연결 옵션: --domain <id> --participant <name>
              --qos <path>
              ddsclient list [연결 옵션]
              ddsclient shell [연결 옵션]
              ddsclient idle [연결 옵션]
              ddsclient publish <MessageName> [연결 옵션] [--json <path>|--stdin] [--repeat <n>] [--interval-ms <n>] [--wait-for-subscribers <n>] [--wait-for-acks] [--wait-timeout-ms <n>]
              ddsclient subscribe <MessageName> [연결 옵션] [--count <n>] [--timeout-ms <n>]

            예시:
              ddsclient list
              ddsclient shell
              ddsclient idle
              ddsclient publish TimeTickInformation
              ddsclient publish SetSimulation --json /tmp/set-simulation.json
              ddsclient subscribe TimeTickInformation

            디버그 로그:
              코드에서 LogLevel=Debug 또는 CLI의 DDS_LOG_LEVEL=Debug 환경변수를 설정하세요.
            """);
    }
}
