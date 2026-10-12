using DdsAmbassador.DDSClient;

internal partial class Program
{
    static async Task<int> RunShell(CliOptions options)
    {
        using var client = DdsClient.Connect(options.Connection);
        using var shutdown = new CancellationTokenSource();
        var subscriptions = new Dictionary<string, IDisposable>(StringComparer.OrdinalIgnoreCase);

        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };

        PrintShellWelcome(client);

        try
        {
            while (!shutdown.IsCancellationRequested)
            {
                Console.Write("ddsclient(도움말)> ");
                var line = await ReadShellLine(shutdown.Token).ConfigureAwait(false);
                if (line is null)
                {
                    continue;
                }

                var tokens = SplitCommandLine(line);
                if (tokens.Count == 0)
                {
                    PrintShellWelcome(client);
                    continue;
                }

                try
                {
                    var command = tokens[0].ToLowerInvariant();
                    switch (command)
                    {
                        case "help":
                        case "?":
                            PrintShellWelcome(client);
                            break;

                        case "exit":
                        case "quit":
                            shutdown.Cancel();
                            break;

                        case "list":
                            PrintTopics(client.Configuration);
                            break;

                        case "status":
                            WriteInfo($"domain={client.Options.DomainId}, 수신 중인 topic={subscriptions.Count}");
                            foreach (var topic in subscriptions.Keys.OrderBy(topic => topic, StringComparer.Ordinal))
                            {
                                Console.WriteLine($"  수신 중: {topic}");
                            }
                            break;

                        case "publish":
                        case "send":
                            var publishOptions = CliOptions.Parse(tokens.Skip(1).ToArray());
                            RequireTopic(publishOptions.Topic);
                            if (publishOptions.ReadStdin)
                            {
                                throw new ArgumentException("shell 모드에서는 --stdin을 지원하지 않습니다. --json <path>를 쓰거나 payload를 생략하세요.");
                            }

                            var publishTopic = publishOptions.Topic!;
                            var publishType = ResolveMessageType(publishTopic);
                            var sample = await CreateSample(publishType, publishOptions).ConfigureAwait(false);
                            await PublishBatch(client, publishTopic, publishType, sample, publishOptions, shutdown.Token);
                            WriteSuccess($"DDS ACK 확인 완료: {publishTopic} ({publishType.FullName}), count={publishOptions.Repeat}");
                            break;

                        case "subscribe":
                        case "listen":
                            var subscribeOptions = CliOptions.Parse(tokens.Skip(1).ToArray());
                            RequireTopic(subscribeOptions.Topic);
                            var subscribeTopic = subscribeOptions.Topic!;
                            if (subscriptions.ContainsKey(subscribeTopic))
                            {
                                WriteWarning($"이미 수신 중입니다: {subscribeTopic}");
                                break;
                            }

                            var subscribeType = ResolveMessageType(subscribeTopic);
                            subscriptions[subscribeTopic] = client.Subscribe(subscribeTopic, subscribeType, received =>
                            {
                                Console.WriteLine();
                                Console.WriteLine($"[{DateTimeOffset.Now:O}] {subscribeTopic}");
                                Console.WriteLine(received);
                                Console.Write("ddsclient(도움말)> ");
                            });
                            WriteSuccess($"수신 시작: {subscribeTopic} ({subscribeType.FullName})");
                            break;

                        case "unsubscribe":
                        case "unsub":
                            var target = tokens.ElementAtOrDefault(1);
                            if (string.IsNullOrWhiteSpace(target))
                            {
                                throw new ArgumentException("unsubscribe에는 topic 이름 또는 all이 필요합니다.");
                            }

                            if (target.Equals("all", StringComparison.OrdinalIgnoreCase))
                            {
                                foreach (var subscription in subscriptions.Values)
                                {
                                    subscription.Dispose();
                                }

                                subscriptions.Clear();
                                WriteSuccess("모든 topic 수신을 해제했습니다.");
                            }
                            else if (subscriptions.Remove(target, out var subscription))
                            {
                                subscription.Dispose();
                                WriteSuccess($"수신 해제: {target}");
                            }
                            else
                            {
                                WriteWarning($"수신 중인 topic이 아닙니다: {target}");
                            }

                            break;

                        default:
                            WriteWarning($"알 수 없는 shell 명령입니다: {tokens[0]}");
                            PrintShellHelp();
                            break;
                    }
                }
                catch (Exception ex)
                {
                    WriteError(ex.Message);
                }
            }
        }
        finally
        {
            foreach (var subscription in subscriptions.Values)
            {
                subscription.Dispose();
            }
        }

        return 0;
    }

    static async Task<string?> ReadShellLine(CancellationToken cancellationToken)
    {
        try
        {
            var line = await Console.In.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is not null)
            {
                return line;
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }

        await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        return null;
    }

    static void PrintShellWelcome(DdsClient client)
    {
        WriteLineColor("DDS 클라이언트 대화형 모드", ConsoleColor.Black, ConsoleColor.Cyan);
        WriteSuccess($"DDS participant가 초기화되었고 계속 유지됩니다. domain={client.Options.DomainId}");
        Console.WriteLine();
        Console.WriteLine("이 shell은 하나의 DdsClient/DomainParticipant를 계속 유지합니다.");
        Console.WriteLine("Discovery UI에 보이는 participant와 여기서 송수신하는 participant는 같습니다.");
        Console.WriteLine();
        WriteInfo("Kubernetes에서 다시 붙는 쉬운 명령:");
        Console.WriteLine("  kubectl -n dds-test attach -it deploy/ddsclient-cli");
        Console.WriteLine();
        WriteWarning("나갈 때 exit를 입력하면 participant가 종료되고 Pod가 재시작될 수 있습니다.");
        Console.WriteLine("participant를 유지하고 빠져나오려면 Ctrl+P 다음 Ctrl+Q를 누르세요.");
        Console.WriteLine();
        PrintShellHelp();
    }

    static void PrintShellHelp()
    {
        Console.WriteLine("이 shell은 하나의 DdsClient/DomainParticipant를 계속 유지합니다.");
        Console.WriteLine("Discovery UI에 보이는 participant와 여기서 송수신하는 participant는 같습니다.");
        Console.WriteLine();
        WriteInfo("Kubernetes에서 다시 붙는 쉬운 명령:");
        Console.WriteLine("  kubectl -n dds-test attach -it deploy/ddsclient-cli");
        Console.WriteLine();
        WriteWarning("나갈 때 exit를 입력하면 participant가 종료되고 Pod가 재시작될 수 있습니다.");
        Console.WriteLine("participant를 유지하고 빠져나오려면 Ctrl+P 다음 Ctrl+Q를 누르세요.");
        Console.WriteLine();
        WriteInfo("사용 가능한 명령:");
        Console.WriteLine("  list                                  topic 목록");
        Console.WriteLine("  status                                domain/subscription 상태");
        Console.WriteLine("  subscribe TimeTickInformation         메시지 수신 시작");
        Console.WriteLine("  publish TimeTickInformation           기본 메시지 송신");
        Console.WriteLine("  publish SetSimulation --json /tmp/a.json");
        Console.WriteLine("  unsubscribe TimeTickInformation       수신 해제");
        Console.WriteLine("  unsubscribe all                       모든 수신 해제");
        Console.WriteLine("  help                                  도움말 다시 보기");
        Console.WriteLine("  exit                                  shell 종료");
        Console.WriteLine();
    }

    static void WriteSuccess(string message)
    {
        WriteLineColor($"[성공] {message}", ConsoleColor.Green);
    }

    static void WriteInfo(string message)
    {
        WriteLineColor($"[정보] {message}", ConsoleColor.Cyan);
    }

    static void WriteWarning(string message)
    {
        WriteLineColor($"[주의] {message}", ConsoleColor.Yellow);
    }

    static void WriteError(string message)
    {
        WriteLineColor($"[오류] {message}", ConsoleColor.Red);
    }

    static void WriteLineColor(string message, ConsoleColor foreground, ConsoleColor? background = null)
    {
        var originalForeground = Console.ForegroundColor;
        var originalBackground = Console.BackgroundColor;

        Console.ForegroundColor = foreground;
        if (background.HasValue)
        {
            Console.BackgroundColor = background.Value;
        }

        Console.WriteLine(message);
        Console.ForegroundColor = originalForeground;
        Console.BackgroundColor = originalBackground;
    }

    static IReadOnlyList<string> SplitCommandLine(string line)
    {
        var tokens = new List<string>();
        var current = new System.Text.StringBuilder();
        var inQuotes = false;

        foreach (var c in line)
        {
            if (c == '"')
            {
                inQuotes = !inQuotes;
                continue;
            }

            if (char.IsWhiteSpace(c) && !inQuotes)
            {
                AddCurrentToken(tokens, current);
                continue;
            }

            current.Append(c);
        }

        AddCurrentToken(tokens, current);
        return tokens;
    }

    static void AddCurrentToken(ICollection<string> tokens, System.Text.StringBuilder current)
    {
        if (current.Length == 0)
        {
            return;
        }

        tokens.Add(current.ToString());
        current.Clear();
    }
}
