using DdsAmbassador.DDSClient;

internal sealed class CliOptions
{
    public DdsClientOptions Connection { get; private init; } = new();

    public string? Topic { get; private init; }

    public string? JsonPath { get; private init; }

    public bool ReadStdin { get; private init; }

    public int Count { get; private init; }

    public int TimeoutMs { get; private init; }

    public int Repeat { get; private init; } = 1;

    public int IntervalMs { get; private init; }
    // 기본 발행은 발견 상태와 무관하다. 양수 값은 사용자가 명시적으로 요청한 진단용 대기다.
    public int WaitForSubscribers { get; private init; }
    public int WaitTimeoutMs { get; private init; } = 10000;
    public bool WaitForAcks { get; private init; }

    public static CliOptions Parse(string[] args)
    {
        var defaults = CliEnvironment.FromEnvironment();
        var domain = defaults.DomainId;
        var participant = defaults.ParticipantName;
        var qos = defaults.QosProfilesXmlPath;
        string? topic = null;
        string? jsonPath = null;
        var readStdin = false;
        var count = 0;
        var timeoutMs = 0;
        var repeat = 1;
        var intervalMs = 0;
        var waitForSubscribers = 0;
        var waitTimeoutMs = 10000;
        var waitForAcks = false;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--domain":
                    domain = ReadNonNegativeInt(args, ref i);
                    break;
                case "--participant":
                    participant = ReadValue(args, ref i);
                    break;
                case "--qos":
                    qos = ReadValue(args, ref i);
                    break;
                case "--json":
                case "-j":
                    jsonPath = ReadValue(args, ref i);
                    break;
                case "--stdin":
                    readStdin = true;
                    break;
                case "--count":
                    count = ReadNonNegativeInt(args, ref i);
                    break;
                case "--timeout-ms":
                    timeoutMs = ReadNonNegativeInt(args, ref i);
                    break;
                case "--wait-for-subscribers":
                    waitForSubscribers = ReadNonNegativeInt(args, ref i);
                    break;
                case "--wait-timeout-ms":
                    waitTimeoutMs = ReadPositiveInt(args, ref i);
                    break;
                case "--wait-for-acks":
                    waitForAcks = true;
                    break;
                case "--repeat":
                    repeat = ReadPositiveInt(args, ref i);
                    break;
                case "--interval-ms":
                    intervalMs = ReadNonNegativeInt(args, ref i);
                    break;
                default:
                    if (args[i].StartsWith("-", StringComparison.Ordinal))
                    {
                        throw new ArgumentException($"알 수 없는 옵션입니다: {args[i]}");
                    }
                    if (topic is not null)
                    {
                        throw new ArgumentException($"예상하지 않은 추가 인수입니다: {args[i]}");
                    }
                    topic = args[i];
                    break;
            }
        }

        if (jsonPath is not null && readStdin)
        {
            throw new ArgumentException("--json과 --stdin은 동시에 사용할 수 없습니다.");
        }

        return new CliOptions
        {
            Connection = new DdsClientOptions
            {
                MessageModules = defaults.MessageModules,
                MulticastReceiveAddress = defaults.MulticastReceiveAddress,
                ShutdownTimeout = defaults.ShutdownTimeout,
                DomainId = domain, ParticipantName = participant,
                QosProfilesXmlPath = qos,
                LogLevel = defaults.LogLevel
            },
            Topic = topic,
            JsonPath = jsonPath,
            ReadStdin = readStdin,
            Count = count,
            TimeoutMs = timeoutMs,
            Repeat = repeat,
            IntervalMs = intervalMs,
            WaitForSubscribers = waitForSubscribers,
            WaitTimeoutMs = waitTimeoutMs,
            WaitForAcks = waitForAcks
        };
    }

    private static string ReadValue(string[] args, ref int index)
    {
        if (index + 1 >= args.Length)
        {
            throw new ArgumentException($"{args[index]} 옵션에는 값이 필요합니다.");
        }

        index++;
        return args[index];
    }

    private static int ReadNonNegativeInt(string[] args, ref int index)
    {
        var option = args[index];
        var value = ReadValue(args, ref index);
        return int.TryParse(value, out var parsed) && parsed >= 0
            ? parsed
            : throw new ArgumentException($"{option} 옵션에는 0 이상의 정수가 필요합니다.");
    }

    private static int ReadPositiveInt(string[] args, ref int index)
    {
        var option = args[index];
        var value = ReadValue(args, ref index);
        return int.TryParse(value, out var parsed) && parsed > 0
            ? parsed
            : throw new ArgumentException($"{option} 옵션에는 1 이상의 정수가 필요합니다.");
    }
}
