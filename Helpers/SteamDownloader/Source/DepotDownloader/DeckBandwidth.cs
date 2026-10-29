// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.
using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
namespace DepotDownloader {
    internal sealed class DeckBandwidthLimiter {
        private readonly double bytesPerMillisecond;
        private double next;
        private readonly object gate = new();
        internal DeckBandwidthLimiter(int kibibytesPerSecond) { bytesPerMillisecond = Math.Clamp(kibibytesPerSecond, 1, 1048576) * 1024.0 / 1000; }
        internal double Reserve(uint bytes, double now) {
            lock (gate) { next = Math.Max(now, next) + bytes / bytesPerMillisecond; return next - now; }
        }
        internal Task WaitAsync(uint bytes, CancellationToken cancellation) {
            var delay = Reserve(bytes, Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency);
            return Task.Delay(TimeSpan.FromMilliseconds(delay), cancellation);
        }
    }
    internal static class DeckBandwidth {
        private static readonly DeckBandwidthLimiter Limiter = int.TryParse(Environment.GetEnvironmentVariable("MACGAMEDECK_BANDWIDTH_KBPS"), out var limit) && limit > 0 ? new(limit) : null;
        internal static Task WaitAsync(uint bytes, CancellationToken cancellation) => Limiter?.WaitAsync(bytes, cancellation) ?? Task.CompletedTask;
    }
}
