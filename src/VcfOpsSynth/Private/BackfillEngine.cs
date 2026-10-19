// Generates and pushes back-dated metric history for the backfill command.
// Loaded by BackfillHelpers.ps1 with Add-Type; PowerShell builds the specs and drives it in batches.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace VcfOpsSynth
{
    // How one stat key's history is made.
    public enum SeriesMode
    {
        Constant = 0,   // A for every point.
        Calibrated = 1, // The object's shape, scaled so the mean is A and the highest point is B.
        Activity = 2,   // The object's shape, scaled so the mean is A.
        Ramp = 3        // Grows linearly to A at the last point, by B (a fraction) per week.
    }

    public sealed class SeriesSpec
    {
        public string Key;
        public SeriesMode Mode;
        public double A;
        public double B;
        public double Cap = double.NaN; // Upper bound, for percentages.
    }

    // One workload whose curve feeds an object's shape: a VM's profile, its seed and its weight.
    public sealed class ShapeComponent
    {
        public string Profile;
        public string Seed;
        public double Weight = 1;
    }

    public sealed class ObjectSpec
    {
        public string Key;
        public string ResourceId;
        public string Seed;
        public ShapeComponent[] Components = new ShapeComponent[0];
        public SeriesSpec[] Series = new SeriesSpec[0];
    }

    public sealed class PushResult
    {
        public string Key;
        public int Calls;
        public long Samples;
        public int Status;      // 0 = all calls succeeded; otherwise the HTTP status of the first failure.
        public string Error;
    }

    public static class Backfill
    {
        // Hour of the week (0 = Monday 00:00 local) for each point, so every profile reads local business hours.
        public static double[] HourOfWeek(long startMs, int stepMs, int points, string timeZoneId)
        {
            var tz = TimeZoneInfo.FindSystemTimeZoneById(timeZoneId);
            var result = new double[points];
            for (int i = 0; i < points; i++)
            {
                var utc = DateTimeOffset.FromUnixTimeMilliseconds(startMs + (long)i * stepMs).UtcDateTime;
                var local = TimeZoneInfo.ConvertTimeFromUtc(utc, tz);
                int day = ((int)local.DayOfWeek + 6) % 7;
                result[i] = day * 24 + local.Hour + local.Minute / 60.0;
            }
            return result;
        }

        static ulong Hash(string text)
        {
            // FNV-1a, so the same object and key always give the same noise.
            ulong h = 14695981039346656037UL;
            foreach (char c in text) { h ^= c; h *= 1099511628211UL; }
            return h == 0 ? 1 : h;
        }

        sealed class Rng
        {
            ulong s;
            public Rng(string seed) { s = Hash(seed); }
            public double Next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (s >> 11) * (1.0 / 9007199254740992.0); }
            public double Gauss() { double u = Math.Max(Next(), 1e-12), v = Next(); return Math.Sqrt(-2 * Math.Log(u)) * Math.Cos(2 * Math.PI * v); }
        }

        // A profile's level at an hour of the week, before noise: 0 (nothing) to about 1 (busy).
        public static double ProfileLevel(string profile, double how)
        {
            double h = how % 24;
            bool weekend = how >= 120;
            switch ((profile ?? "steady").ToLowerInvariant())
            {
                case "off": return 0;
                case "idle": return 0.05;
                case "batch": return (h >= 1 && h < 5) ? 1.0 : 0.12;
                case "saturated": return 0.9 + 0.05 * Math.Sin(2 * Math.PI * (h - 6) / 24);
                case "bursty": return 0.15;
                case "business-hours":
                    {
                        double day;
                        if (h >= 9 && h < 18) day = 1.0;
                        else if (h >= 7 && h < 9) day = 0.25 + 0.75 * (h - 7) / 2;
                        else if (h >= 18 && h < 20) day = 1.0 - 0.75 * (h - 18) / 2;
                        else day = 0.2;
                        return weekend ? Math.Min(day, 0.3) : day;
                    }
                default: return 0.6 + 0.1 * Math.Sin(2 * Math.PI * (h - 6) / 24);
            }
        }

        // One workload's curve: its profile, multiplicative noise and up to two incident windows.
        public static double[] ComponentCurve(ShapeComponent c, double[] how, int stepMs)
        {
            int n = how.Length;
            var rng = new Rng("curve|" + c.Seed);
            var curve = new double[n];
            for (int i = 0; i < n; i++)
            {
                double level = ProfileLevel(c.Profile, how[i]);
                double noise = Math.Exp(0.12 * rng.Gauss() - 0.0072);
                curve[i] = level * noise;
            }
            if ((c.Profile ?? "").ToLowerInvariant() == "bursty")
            {
                // Short busy spells, about ten a week, of 15 to 45 minutes.
                int perHour = Math.Max(1, 3600000 / stepMs);
                double weeks = (double)n * stepMs / (7 * 86400000.0);
                int bursts = (int)Math.Round(weeks * (8 + rng.Next() * 4));
                for (int k = 0; k < bursts; k++)
                {
                    int start = (int)(rng.Next() * n);
                    int length = Math.Max(1, perHour / 4 + (int)(rng.Next() * perHour / 2));
                    for (int i = start; i < Math.Min(n, start + length); i++) curve[i] = Math.Max(curve[i], 0.85 + 0.15 * rng.Next());
                }
            }
            if ((c.Profile ?? "").ToLowerInvariant() != "off")
            {
                int incidents = (int)(rng.Next() * 3); // 0, 1 or 2 in the window.
                int perHour = Math.Max(1, 3600000 / stepMs);
                for (int k = 0; k < incidents; k++)
                {
                    int start = (int)(rng.Next() * n);
                    int length = perHour / 2 + (int)(rng.Next() * perHour * 1.5);
                    for (int i = start; i < Math.Min(n, start + length); i++) curve[i] = Math.Max(curve[i], 1.0) * 1.6;
                }
            }
            return curve;
        }

        // An object's shape: its components' curves summed by weight; a flat curve when it has none.
        public static double[] Shape(ObjectSpec o, double[] how, int stepMs)
        {
            int n = how.Length;
            var shape = new double[n];
            if (o.Components == null || o.Components.Length == 0)
            {
                var rng = new Rng("flat|" + o.Seed);
                for (int i = 0; i < n; i++) shape[i] = Math.Exp(0.05 * rng.Gauss());
                return shape;
            }
            foreach (var c in o.Components)
            {
                var curve = ComponentCurve(c, how, stepMs);
                for (int i = 0; i < n; i++) shape[i] += c.Weight * curve[i];
            }
            return shape;
        }

        // Highest point over the mean of the shape raised to the power g.
        static double PeakRatio(double[] shape, double g)
        {
            double sum = 0, max = 0;
            for (int i = 0; i < shape.Length; i++) { double x = Math.Pow(shape[i], g); sum += x; if (x > max) max = x; }
            return sum > 0 ? max * shape.Length / sum : 1;
        }

        public static double[] Values(SeriesSpec s, double[] shape, int stepMs)
        {
            int n = shape.Length;
            var v = new double[n];
            switch (s.Mode)
            {
                case SeriesMode.Constant:
                    for (int i = 0; i < n; i++) v[i] = s.A;
                    break;
                case SeriesMode.Ramp:
                    {
                        double weeks = (double)(n - 1) * stepMs / (7 * 86400000.0);
                        double first = s.A / (1 + s.B * weeks);
                        for (int i = 0; i < n; i++) v[i] = n == 1 ? s.A : first + (s.A - first) * i / (n - 1);
                        break;
                    }
                default:
                    {
                        double mean = 0, max = double.MinValue;
                        for (int i = 0; i < n; i++) { mean += shape[i]; if (shape[i] > max) max = shape[i]; }
                        mean /= n;
                        if (s.Mode == SeriesMode.Calibrated && s.A <= 0)
                        {
                            // LiveOptics says 0 on average yet peaked at B: one spike at the busiest point, zero elsewhere.
                            // The mean is B/n, which still rounds to the reported 0.
                            int top = 0;
                            for (int i = 1; i < n; i++) if (shape[i] > shape[top]) top = i;
                            if (s.B > 0) v[top] = s.B;
                        }
                        else if (s.Mode == SeriesMode.Calibrated && s.B <= s.A)
                        {
                            // The peak is the average: a flat line, not the curve's own peaks.
                            for (int i = 0; i < n; i++) v[i] = s.A;
                        }
                        else if (s.Mode == SeriesMode.Activity || max <= mean || mean <= 0)
                        {
                            // Mean matches A; the curve keeps its own peaks.
                            double scale = mean > 0 ? s.A / mean : 0;
                            for (int i = 0; i < n; i++) v[i] = mean > 0 ? shape[i] * scale : s.A;
                        }
                        else
                        {
                            // Mean A and highest point B: raise the shape to the power whose peak-to-mean ratio is B/A,
                            // then scale. A power keeps every point at or above zero, which a linear stretch would not.
                            double target = s.B / s.A;
                            double lo = 0, hi = 1;
                            while (PeakRatio(shape, hi) < target && hi < 64) hi *= 2;
                            for (int it = 0; it < 60; it++)
                            {
                                double mid = (lo + hi) / 2;
                                if (PeakRatio(shape, mid) < target) lo = mid; else hi = mid;
                            }
                            double g = (lo + hi) / 2, sum = 0;
                            for (int i = 0; i < n; i++) { v[i] = Math.Pow(shape[i], g); sum += v[i]; }
                            double scale = sum > 0 ? s.A * n / sum : 0;
                            for (int i = 0; i < n; i++) v[i] *= scale;
                        }
                        break;
                    }
            }
            for (int i = 0; i < n; i++)
            {
                if (v[i] < 0) v[i] = 0;
                if (!double.IsNaN(s.Cap) && v[i] > s.Cap) v[i] = s.Cap;
            }
            return v;
        }

        static void AppendNumber(StringBuilder sb, double x)
        {
            double r = Math.Round(x, 3);
            if (r == Math.Floor(r) && Math.Abs(r) < 1e15) sb.Append(((long)r).ToString(CultureInfo.InvariantCulture));
            else sb.Append(r.ToString("0.###", CultureInfo.InvariantCulture));
        }

        static string Escape(string s)
        {
            var sb = new StringBuilder(s.Length + 2);
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                else sb.Append(c);
            }
            return sb.ToString();
        }

        // The stat-content bodies for one object, each holding at most maxSamples samples.
        public static List<string> Bodies(ObjectSpec o, long startMs, int stepMs, double[] how, int maxSamples, out long samples)
        {
            samples = (long)o.Series.Length * how.Length;
            return BodyStream(o, startMs, stepMs, how, maxSamples).ToList();
        }

        // The same bodies made one at a time, so only the body being posted is held in memory.
        public static IEnumerable<string> BodyStream(ObjectSpec o, long startMs, int stepMs, double[] how, int maxSamples)
        {
            int n = how.Length;
            var tsb = new StringBuilder(n * 15);
            for (int i = 0; i < n; i++) { if (i > 0) tsb.Append(','); tsb.Append((startMs + (long)i * stepMs).ToString(CultureInfo.InvariantCulture)); }
            string timestamps = tsb.ToString();
            var shape = Shape(o, how, stepMs);
            int perBody = Math.Max(1, maxSamples / Math.Max(1, n));
            for (int start = 0; start < o.Series.Length; start += perBody)
            {
                var sb = new StringBuilder();
                sb.Append("{\"stat-content\":[");
                int end = Math.Min(o.Series.Length, start + perBody);
                for (int j = start; j < end; j++)
                {
                    var s = o.Series[j];
                    var v = Values(s, shape, stepMs);
                    if (j > start) sb.Append(',');
                    sb.Append("{\"statKey\":\"").Append(Escape(s.Key)).Append("\",\"timestamps\":[").Append(timestamps).Append("],\"data\":[");
                    for (int i = 0; i < n; i++) { if (i > 0) sb.Append(','); AppendNumber(sb, v[i]); }
                    sb.Append("]}");
                }
                sb.Append("]}");
                yield return sb.ToString();
            }
        }

        // Seconds to wait before retry number attempt (1 = the first): Retry-After when the server gives it,
        // else 2, 4, 8, 16 and so on, capped at maxDelaySeconds.
        public static int RetryDelaySeconds(int attempt, int maxDelaySeconds, TimeSpan? retryAfter)
        {
            int cap = Math.Max(1, maxDelaySeconds);
            if (retryAfter.HasValue && retryAfter.Value > TimeSpan.Zero) return (int)Math.Min(cap, Math.Ceiling(retryAfter.Value.TotalSeconds));
            return (int)Math.Min(cap, 2L << Math.Min(30, Math.Max(0, attempt - 1)));
        }

        // Generates and posts each object's history, several objects at a time. 429 and 5xx are retried up to
        // maxRetries times per body, so a busy Operations that refuses writes for a few minutes is waited out;
        // any other failure stops that object and is reported, so the caller can sign in again or retry.
        public static PushResult[] Run(string baseUri, string token, bool skipCertificateCheck, ObjectSpec[] objects,
            long startMs, int stepMs, int points, string timeZoneId, int concurrency, int maxSamples, int timeoutSeconds,
            int maxRetries, int maxDelaySeconds)
        {
            var how = HourOfWeek(startMs, stepMs, points, timeZoneId);
            var handler = new HttpClientHandler();
            if (skipCertificateCheck) handler.ServerCertificateCustomValidationCallback = (m, c, ch, e) => true;
            using (var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(timeoutSeconds) })
            {
                var results = new PushResult[objects.Length];
                var gate = new SemaphoreSlim(Math.Max(1, concurrency));
                var tasks = new List<Task>();
                for (int idx = 0; idx < objects.Length; idx++)
                {
                    int k = idx;
                    gate.Wait();
                    tasks.Add(Task.Run(async () =>
                    {
                        var o = objects[k];
                        var r = new PushResult { Key = o.Key };
                        try
                        {
                            long samples = (long)o.Series.Length * how.Length;
                            // One body at a time: a large VM is millions of samples, too many to hold for several objects at once.
                            var bodies = BodyStream(o, startMs, stepMs, how, maxSamples);
                            string uri = baseUri.TrimEnd('/') + "/api/resources/" + o.ResourceId + "/stats?disableAnalyticsProcessing=true";
                            foreach (var body in bodies)
                            {
                                int attempt = 0;
                                while (true)
                                {
                                    using (var req = new HttpRequestMessage(HttpMethod.Post, uri))
                                    {
                                        req.Headers.TryAddWithoutValidation("Authorization", "OpsToken " + token);
                                        req.Headers.TryAddWithoutValidation("Accept", "application/json");
                                        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
                                        HttpResponseMessage resp = null;
                                        int status;
                                        string detail = null;
                                        try { resp = await client.SendAsync(req).ConfigureAwait(false); status = (int)resp.StatusCode; }
                                        catch (Exception e) { status = 599; detail = e.Message; }
                                        if (status >= 200 && status < 300) { r.Calls++; resp?.Dispose(); break; }
                                        bool retry = status == 429 || status >= 500;
                                        if (!retry || attempt >= maxRetries)
                                        {
                                            if (resp != null && detail == null) { try { detail = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { } }
                                            resp?.Dispose();
                                            r.Status = status;
                                            r.Error = detail == null ? "HTTP " + status : ("HTTP " + status + ": " + (detail.Length > 300 ? detail.Substring(0, 300) : detail));
                                            goto done;
                                        }
                                        TimeSpan? retryAfter = resp?.Headers.RetryAfter?.Delta;
                                        resp?.Dispose();
                                        attempt++;
                                        await Task.Delay(1000 * RetryDelaySeconds(attempt, maxDelaySeconds, retryAfter)).ConfigureAwait(false);
                                    }
                                }
                            }
                            r.Samples = samples;
                        done:;
                        }
                        catch (Exception e) { r.Status = 598; r.Error = e.Message; }
                        finally { results[k] = r; gate.Release(); }
                    }));
                }
                Task.WaitAll(tasks.ToArray());
                return results;
            }
        }
    }
}
