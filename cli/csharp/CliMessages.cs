using DdsAmbassador.Messages;
using System.Text.Json;
using System.Text.Json.Serialization;
using DdsAmbassador.DDSClient;

internal partial class Program
{
    static Type ResolveMessageType(string topic)
    {
        return typeof(DDSSimMessages).Assembly.GetType($"DdsModules_DDSSim.MSG.{topic}", throwOnError: true)
            ?? throw new InvalidOperationException($"MSG.{topic} 타입을 찾을 수 없습니다.");
    }

    static async Task PublishBatch(DdsClient client, string topic, Type type, object sample, CliOptions options, CancellationToken cancellation)
    {
        if (options.WaitForSubscribers > 0)
            client.WaitForSubscribers(topic, type, options.WaitForSubscribers, TimeSpan.FromMilliseconds(options.WaitTimeoutMs));
        for (var index = 0; index < options.Repeat; index++)
        {
            cancellation.ThrowIfCancellationRequested();
            client.Publish(topic, sample);
            if (index + 1 < options.Repeat && options.IntervalMs > 0)
                await Task.Delay(options.IntervalMs, cancellation).ConfigureAwait(false);
        }
        if (options.WaitForAcks)
            client.WaitForAcknowledgments(topic, type, TimeSpan.FromMilliseconds(options.WaitTimeoutMs));
    }

    static async Task<object> CreateSample(Type sampleType, CliOptions options)
    {
        string? json = null;
        if (options.JsonPath is not null)
        {
            json = await File.ReadAllTextAsync(options.JsonPath).ConfigureAwait(false);
        }
        else if (options.ReadStdin)
        {
            json = await Console.In.ReadToEndAsync().ConfigureAwait(false);
        }

        object sample;
        if (!string.IsNullOrWhiteSpace(json))
        {
            sample = JsonSerializer.Deserialize(json, sampleType, CreateJsonOptions())
                ?? throw new InvalidOperationException($"JSON을 {sampleType.FullName} 타입으로 변환할 수 없습니다.");
        }
        else
        {
            sample = Activator.CreateInstance(sampleType)
                ?? throw new InvalidOperationException($"{sampleType.FullName} 인스턴스를 생성할 수 없습니다.");
        }

        ApplyCommonDefaults(sample, options.Topic, json);
        return sample;
    }

    static void ApplyCommonDefaults(object sample, string? topic, string? json)
    {
        var headerProperty = sample.GetType().GetProperty("Header");
        if (headerProperty?.CanRead != true || headerProperty.CanWrite != true)
        {
            return;
        }

        var header = headerProperty.GetValue(sample);
        if (header is null)
        {
            header = Activator.CreateInstance(headerProperty.PropertyType);
            headerProperty.SetValue(sample, header);
        }

        if (header is null)
        {
            return;
        }

        SetIfDefault(header, "TimeStamp", (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        SetEnumIfMissingOrDefault(header, "MsgID", topic, json);
        SetEnumIfMissingOrDefault(
            header, "SrcSimID", Environment.GetEnvironmentVariable("DDS_CLI_SRC_SIM_ID") ?? "TCC", json);
        SetEnumIfMissingOrDefault(
            header, "DstSimID", Environment.GetEnvironmentVariable("DDS_CLI_DST_SIM_ID") ?? "TDS", json);
    }

    static void SetIfDefault<T>(object target, string propertyName, T value)
    {
        var property = target.GetType().GetProperty(propertyName);
        if (property?.CanRead != true || property.CanWrite != true || property.PropertyType != typeof(T))
        {
            return;
        }

        if (EqualityComparer<T>.Default.Equals((T?)property.GetValue(target), default))
        {
            property.SetValue(target, value);
        }
    }

    static void SetEnumIfMissingOrDefault(object target, string propertyName, string? value, string? json)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        var property = target.GetType().GetProperty(propertyName);
        if (property?.CanRead != true || property.CanWrite != true || !property.PropertyType.IsEnum)
        {
            return;
        }

        var current = property.GetValue(target);
        if (ContainsJsonProperty(json, propertyName) &&
            !Equals(current, Activator.CreateInstance(property.PropertyType)))
        {
            return;
        }

        if (Enum.TryParse(property.PropertyType, value, ignoreCase: true, out var parsed))
        {
            property.SetValue(target, parsed);
            return;
        }

        throw new ArgumentException(
            $"'{value}'은(는) {property.PropertyType.Name}.{propertyName}에 사용할 수 없는 enum 값입니다.");
    }

    static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }

    static bool ContainsJsonProperty(string? json, string propertyName)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return false;
        }

        using var document = JsonDocument.Parse(json);
        return ContainsJsonPropertyElement(document.RootElement, propertyName);
    }

    static bool ContainsJsonPropertyElement(JsonElement element, string propertyName)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Name.Equals(propertyName, StringComparison.OrdinalIgnoreCase) ||
                    ContainsJsonPropertyElement(property.Value, propertyName))
                {
                    return true;
                }
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
            {
                if (ContainsJsonPropertyElement(item, propertyName))
                {
                    return true;
                }
            }
        }

        return false;
    }
}
