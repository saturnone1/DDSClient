using System.Collections.Concurrent;
using System.Security.Cryptography;
using DdsAmbassador.DDSClient;
using DdsAmbassador.Messages;
using DdsModules_AddedAfterFreeze.CompatibilityProbe;

if (args.Length != 4) throw new ArgumentException("Expected QoS path, domain, unique topic and frozen Core SHA-256.");
var loadedCore = typeof(DdsClient).Assembly.Location;
using (var stream = File.OpenRead(loadedCore))
    if (!Convert.ToHexString(SHA256.HashData(stream)).Equals(args[3], StringComparison.OrdinalIgnoreCase))
        throw new Exception("The loaded Core assembly differs from the frozen binary.");

var options = new DdsClientOptions {
    DomainId = int.Parse(args[1]), QosProfilesXmlPath = args[0],
    MessageModules = [AddedAfterFreezeMessages.Module],
    Topics = [Topic.Named<ProbeSample>(args[2])]
};
var values = new ConcurrentQueue<(ulong Counter, bool Healthy)>();
using (var receiver = DdsClient.Connect(options))
using (var subscription = receiver.Subscribe<ProbeSample>(sample => values.Enqueue((sample.Counter, sample.Healthy))))
using (var sender = DdsClient.Connect(options))
{
    var publisher = sender.CreatePublisher<ProbeSample>();
    publisher.WaitForSubscribers(1, TimeSpan.FromSeconds(15));
    for (ulong i = 1; i <= 4; ++i) publisher.Publish(new ProbeSample { Counter = i, Healthy = true });
    publisher.WaitForAcknowledgments(TimeSpan.FromSeconds(10));
    if (!SpinWait.SpinUntil(() => values.Count >= 4, TimeSpan.FromSeconds(10)))
        throw new Exception("New-module RTI delivery timed out.");
}
if (!values.SequenceEqual(new[] { (1UL, true), (2UL, true), (3UL, true), (4UL, true) }))
    throw new Exception("Expected exactly four ordered new-module RTI samples with intact payloads.");
Console.WriteLine($"Frozen Core loaded: {loadedCore}");
Console.WriteLine("MODULE_ADDITION_PASS csharp 4");
