using DdsAmbassador.Messages;
using DdsAmbassador.DDSClient;

internal static class CliEnvironment
{
    public static DdsClientOptions FromEnvironment()
    {
        return new DdsClientOptions
        {
            MessageModules = [DDSSimMessages.Module],
            MulticastReceiveAddress = Environment.GetEnvironmentVariable("DDS_MULTICAST_RECEIVE_ADDRESS") ?? Environment.GetEnvironmentVariable("DDS_MULTICAST_ADDRESS"),
            // 환경변수 해석은 CLI의 책임이다. 라이브러리는 명시적인 옵션 값만 사용한다.
            ShutdownTimeout = TimeSpan.FromMilliseconds(ReadIntEnvironment("DDS_SHUTDOWN_TIMEOUT_MS", 10000)),
            DomainId = ReadIntEnvironment("DDS_DOMAIN_ID", 0),
            LogLevel = ReadLogLevelEnvironment(DdsLogLevel.None),
            ParticipantName = Environment.GetEnvironmentVariable("DDS_PARTICIPANT_NAME"),
            QosProfilesXmlPath = Environment.GetEnvironmentVariable("DDS_QOS_PROFILES_XML_PATH")
        };
    }

    private static int ReadIntEnvironment(string name, int defaultValue)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            return defaultValue;
        }

        return int.TryParse(value, out var parsed)
            ? parsed
            : throw new DdsConfigurationException($"{name}은(는) 정수여야 합니다.");
    }

    private static DdsLogLevel ReadLogLevelEnvironment(DdsLogLevel defaultValue)
    {
        var value = Environment.GetEnvironmentVariable("DDS_LOG_LEVEL");
        return string.IsNullOrWhiteSpace(value)
            ? defaultValue
            : ParseLogLevel(value, "DDS_LOG_LEVEL");
    }

    private static DdsLogLevel ParseLogLevel(string value, string source)
    {
        return Enum.TryParse<DdsLogLevel>(value, ignoreCase: true, out var parsed) && Enum.IsDefined(parsed)
            ? parsed
            : throw new DdsConfigurationException($"{source}은(는) None, Error, Info 또는 Debug여야 합니다.");
    }

}
