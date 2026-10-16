// Generates and pushes back-dated metric history for the backfill command, and live points for the feed.
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

        // True when an object has no workload to follow: no VMs, or only powered-off ones. A powered-off VM's
        // own curve (its one component, with its own seed) is not counted, so the VM itself stays flat.
        public static bool HasNoActiveComponent(ObjectSpec o)
        {
            if (o.Components == null || o.Components.Length == 0) return true;
            bool others = false;
            foreach (var c in o.Components)
            {
                if (!string.Equals(c.Profile, "off", StringComparison.OrdinalIgnoreCase)) return false;
                if (c.Seed != o.Seed) others = true;
            }
            return others;
        }

        // An object's shape: its components' curves summed by weight; a gently noisy flat curve when it has
        // none, or only powered-off ones, so a host whose VMs are all off can still meet its LiveOptics peak.
        public static double[] Shape(ObjectSpec o, double[] how, int stepMs)
        {
            int n = how.Length;
            var shape = new double[n];
            if (HasNoActiveComponent(o))
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

        // Generates and posts each object's history, several objects at a time. 429 and 5xx are retried;
        // any other failure stops that object and is reported, so the caller can sign in again or retry.
        public static PushResult[] Run(string baseUri, string token, bool skipCertificateCheck, ObjectSpec[] objects,
            long startMs, int stepMs, int points, string timeZoneId, int concurrency, int maxSamples, int timeoutSeconds)
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
                                        if (!retry || attempt >= 4)
                                        {
                                            if (resp != null && detail == null) { try { detail = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { } }
                                            resp?.Dispose();
                                            r.Status = status;
                                            r.Error = detail == null ? "HTTP " + status : ("HTTP " + status + ": " + (detail.Length > 300 ? detail.Substring(0, 300) : detail));
                                            goto done;
                                        }
                                        resp?.Dispose();
                                        attempt++;
                                        await Task.Delay(Math.Min(60000, 2000 * (1 << (attempt - 1)))).ConfigureAwait(false);
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

    // A scenario's change to one object's series while it runs: keys matching Pattern get Op with Value,
    // reached gradually over RampMs from StartMs. Drop stops pushing the matching keys altogether.
    public enum OverlayOp { Set = 0, Multiply = 1, Add = 2, Floor = 3, Drop = 4 }

    public sealed class Overlay
    {
        public string Scenario;
        public string Pattern;
        public OverlayOp Op;
        public double Value;
        public long StartMs;
        public long RampMs;
        [NonSerialized] public System.Text.RegularExpressions.Regex Rx;
    }

    // One object as the feed sees it: its backfill spec, each series' scaling worked out once over the
    // reference window, the text stats pushed unchanged every cycle, and any scenario overlays.
    public sealed class FeedObject
    {
        public ObjectSpec Spec;
        public double[] Scale;
        public double[] Power;
        public string[] TextKeys = new string[0];
        public string[] TextValues = new string[0];
        public Overlay[] Overlays = new Overlay[0];
        public long RefEndMs;
    }

    public static class Feed
    {
        static ulong Mix(ulong h)
        {
            h ^= h >> 33; h *= 0xff51afd7ed558ccdUL; h ^= h >> 33; h *= 0xc4ceb9fe1a85ec53UL; h ^= h >> 33;
            return h;
        }

        static ulong Hash(string text)
        {
            ulong h = 14695981039346656037UL;
            foreach (char c in text) { h ^= c; h *= 1099511628211UL; }
            return h == 0 ? 1 : h;
        }

        // A uniform number in [0, 1) for a seed, a slot and a salt: the same inputs always give the same number.
        static double U(ulong seed, long slot, ulong salt) { return (Mix(seed ^ Mix((ulong)slot * 0x9E3779B97F4A7C15UL ^ salt)) >> 11) * (1.0 / 9007199254740992.0); }

        static double Gauss(ulong seed, long slot)
        {
            double u = Math.Max(U(seed, slot, 1), 1e-12), v = U(seed, slot, 2);
            return Math.Sqrt(-2 * Math.Log(u)) * Math.Cos(2 * Math.PI * v);
        }

        public static double HourOfWeekAt(long ms, TimeZoneInfo tz)
        {
            var local = TimeZoneInfo.ConvertTimeFromUtc(DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime, tz);
            int day = ((int)local.DayOfWeek + 6) % 7;
            return day * 24 + local.Hour + local.Minute / 60.0;
        }

        // One workload's level at a moment, with the same make-up as the backfill's curves (profile, noise,
        // bursts about ten a week, an incident or so a month), drawn from the time itself so no state is kept.
        public static double ComponentAt(ShapeComponent c, long ms, int stepMs, double how)
        {
            string profile = (c.Profile ?? "steady").ToLowerInvariant();
            ulong seed = Hash("feed|" + c.Seed);
            long slot = ms / Math.Max(1, stepMs);
            double v = Backfill.ProfileLevel(profile, how) * Math.Exp(0.12 * Gauss(seed, slot) - 0.0072);
            if (profile == "off") return 0;
            if (profile == "bursty")
            {
                long hour = ms / 3600000;
                if (U(seed, hour, 3) < 10.0 / 168)
                {
                    long start = hour * 3600000 + (long)(U(seed, hour, 4) * 3600000);
                    long length = 900000 + (long)(U(seed, hour, 5) * 1800000);
                    if (ms >= start && ms < start + length) v = Math.Max(v, 0.85 + 0.15 * U(seed, slot, 6));
                }
            }
            long twoHours = ms / 7200000;
            if (U(seed, twoHours, 7) < 1.0 / 360)
            {
                long start = twoHours * 7200000 + (long)(U(seed, twoHours, 8) * 3600000);
                long length = 1800000 + (long)(U(seed, twoHours, 9) * 5400000);
                if (ms >= start && ms < start + length) v = Math.Max(v, 1.0) * 1.6;
            }
            return v;
        }

        public static double ShapeAt(ObjectSpec o, long ms, int stepMs, double how)
        {
            if (Backfill.HasNoActiveComponent(o))
                return Math.Exp(0.05 * Gauss(Hash("feedflat|" + o.Seed), ms / Math.Max(1, stepMs)));
            double sum = 0;
            foreach (var c in o.Components) sum += c.Weight * ComponentAt(c, ms, stepMs, how);
            return sum;
        }

        static double PeakRatio(double[] shape, double g)
        {
            double sum = 0, max = 0;
            for (int i = 0; i < shape.Length; i++) { double x = Math.Pow(shape[i], g); sum += x; if (x > max) max = x; }
            return sum > 0 ? max * shape.Length / sum : 1;
        }

        // Works out each series' scale (and power, for calibrated series) over the reference window, which is
        // the backfill's range, so the live points carry on at the same levels as the history before them.
        public static FeedObject Prepare(ObjectSpec o, long refStartMs, int stepMs, int refPoints, string timeZoneId)
        {
            var how = Backfill.HourOfWeek(refStartMs, stepMs, refPoints, timeZoneId);
            var shape = Backfill.Shape(o, how, stepMs);
            int n = shape.Length;
            double mean = 0, max = double.MinValue;
            for (int i = 0; i < n; i++) { mean += shape[i]; if (shape[i] > max) max = shape[i]; }
            mean /= Math.Max(1, n);
            var f = new FeedObject { Spec = o, Scale = new double[o.Series.Length], Power = new double[o.Series.Length], RefEndMs = refStartMs + (long)(refPoints - 1) * stepMs };
            for (int j = 0; j < o.Series.Length; j++)
            {
                var s = o.Series[j];
                f.Power[j] = 1;
                if (s.Mode == SeriesMode.Constant || s.Mode == SeriesMode.Ramp) continue;
                if (s.Mode == SeriesMode.Calibrated && (s.A <= 0 || s.B <= s.A)) continue;
                if (s.Mode == SeriesMode.Activity || max <= mean || mean <= 0) { f.Scale[j] = mean > 0 ? s.A / mean : 0; continue; }
                double target = s.B / s.A, lo = 0, hi = 1;
                while (PeakRatio(shape, hi) < target && hi < 64) hi *= 2;
                for (int it = 0; it < 60; it++) { double mid = (lo + hi) / 2; if (PeakRatio(shape, mid) < target) lo = mid; else hi = mid; }
                double g = (lo + hi) / 2, sum = 0;
                for (int i = 0; i < n; i++) sum += Math.Pow(shape[i], g);
                f.Power[j] = g;
                f.Scale[j] = sum > 0 ? s.A * n / sum : 0;
            }
            return f;
        }

        public static FeedObject[] PrepareAll(ObjectSpec[] objects, long refStartMs, int stepMs, int refPoints, string timeZoneId, int concurrency)
        {
            var result = new FeedObject[objects.Length];
            Parallel.For(0, objects.Length, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, concurrency) },
                i => { result[i] = Prepare(objects[i], refStartMs, stepMs, refPoints, timeZoneId); });
            return result;
        }

        // The overlay's effect at a moment: 0 before it starts, rising to 1 over its ramp.
        static double Progress(Overlay ov, long ms)
        {
            if (ms < ov.StartMs) return 0;
            if (ov.RampMs <= 0) return 1;
            return Math.Min(1.0, (double)(ms - ov.StartMs) / ov.RampMs);
        }

        static bool Matches(Overlay ov, string key)
        {
            if (ov.Rx == null) ov.Rx = new System.Text.RegularExpressions.Regex(ov.Pattern, System.Text.RegularExpressions.RegexOptions.CultureInvariant);
            return ov.Rx.IsMatch(key);
        }

        // One series' value at a moment, before overlays; NaN means the key is not pushed.
        public static double BaseValue(FeedObject f, int j, double shapeNow, long ms, int stepMs)
        {
            var s = f.Spec.Series[j];
            double v;
            switch (s.Mode)
            {
                case SeriesMode.Constant: v = s.A; break;
                case SeriesMode.Ramp:
                    {
                        double weeks = Math.Max(0, (double)(ms - f.RefEndMs) / (7 * 86400000.0));
                        v = s.A * (1 + s.B * weeks);
                        break;
                    }
                case SeriesMode.Calibrated when s.A <= 0: v = 0; break;
                case SeriesMode.Calibrated when s.B <= s.A: v = s.A; break;
                default: v = f.Scale[j] * (f.Power[j] == 1 ? shapeNow : Math.Pow(shapeNow, f.Power[j])); break;
            }
            return v;
        }

        public static double ValueAt(FeedObject f, int j, double shapeNow, long ms, int stepMs)
        {
            var s = f.Spec.Series[j];
            double v = BaseValue(f, j, shapeNow, ms, stepMs);
            foreach (var ov in f.Overlays)
            {
                if (!Matches(ov, s.Key)) continue;
                double p = Progress(ov, ms);
                if (p <= 0) continue;
                switch (ov.Op)
                {
                    case OverlayOp.Drop: return double.NaN;
                    case OverlayOp.Set: v = v + (ov.Value - v) * p; break;
                    case OverlayOp.Multiply: v = v * (1 + (ov.Value - 1) * p); break;
                    case OverlayOp.Add: v = v + ov.Value * p; break;
                    case OverlayOp.Floor: { double target = Math.Max(v, ov.Value); v = v + (target - v) * p; break; }
                }
            }
            if (v < 0) v = 0;
            // A scenario may go past the cap on purpose (a host at 105 % demand), so only base values are capped.
            if (!double.IsNaN(s.Cap) && v > s.Cap && !f.Overlays.Any(o => Matches(o, s.Key) && Progress(o, ms) > 0)) v = s.Cap;
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

        // The stat-content body for one object over the given timestamps, and the number of samples in it.
        public static string Body(FeedObject f, long[] times, int stepMs, TimeZoneInfo tz, bool withText, out long samples)
        {
            samples = 0;
            var shapes = new double[times.Length];
            for (int i = 0; i < times.Length; i++) shapes[i] = ShapeAt(f.Spec, times[i], stepMs, HourOfWeekAt(times[i], tz));
            var sb = new StringBuilder();
            sb.Append("{\"stat-content\":[");
            bool first = true;
            var values = new double[times.Length];
            for (int j = 0; j < f.Spec.Series.Length; j++)
            {
                var ts = new List<long>(times.Length);
                var vs = new List<double>(times.Length);
                for (int i = 0; i < times.Length; i++)
                {
                    double v = ValueAt(f, j, shapes[i], times[i], stepMs);
                    if (double.IsNaN(v)) continue;
                    ts.Add(times[i]); vs.Add(v);
                }
                if (ts.Count == 0) continue;
                if (!first) sb.Append(',');
                first = false;
                sb.Append("{\"statKey\":\"").Append(Escape(f.Spec.Series[j].Key)).Append("\",\"timestamps\":[");
                for (int i = 0; i < ts.Count; i++) { if (i > 0) sb.Append(','); sb.Append(ts[i].ToString(CultureInfo.InvariantCulture)); }
                sb.Append("],\"data\":[");
                for (int i = 0; i < vs.Count; i++) { if (i > 0) sb.Append(','); AppendNumber(sb, vs[i]); }
                sb.Append("]}");
                samples += ts.Count;
            }
            if (withText)
            {
                long last = times[times.Length - 1];
                for (int k = 0; k < f.TextKeys.Length; k++)
                {
                    bool dropped = false;
                    foreach (var ov in f.Overlays) if (ov.Op == OverlayOp.Drop && Progress(ov, last) > 0 && Matches(ov, f.TextKeys[k])) dropped = true;
                    if (dropped) continue;
                    if (!first) sb.Append(',');
                    first = false;
                    sb.Append("{\"statKey\":\"").Append(Escape(f.TextKeys[k])).Append("\",\"timestamps\":[").Append(last.ToString(CultureInfo.InvariantCulture))
                      .Append("],\"values\":[\"").Append(Escape(f.TextValues[k] ?? "")).Append("\"]}");
                    samples++;
                }
            }
            sb.Append("]}");
            return sb.ToString();
        }

        // Posts the given timestamps for every object, several at a time. History (catch-up) goes with analytics
        // off; the live point with analytics on, so Operations evaluates symptoms and capacity on it.
        public static PushResult[] Run(string baseUri, string token, bool skipCertificateCheck, FeedObject[] objects,
            long[] times, int stepMs, string timeZoneId, bool analytics, int concurrency, int timeoutSeconds)
        {
            var tz = TimeZoneInfo.FindSystemTimeZoneById(timeZoneId);
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
                        var f = objects[k];
                        var r = new PushResult { Key = f.Spec.Key };
                        try
                        {
                            long samples;
                            string body = Body(f, times, stepMs, tz, analytics, out samples);
                            string uri = baseUri.TrimEnd('/') + "/api/resources/" + f.Spec.ResourceId + "/stats" + (analytics ? "" : "?disableAnalyticsProcessing=true");
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
                                    if (status >= 200 && status < 300) { r.Calls++; r.Samples = samples; resp?.Dispose(); break; }
                                    bool retry = status == 429 || status >= 500;
                                    if (!retry || attempt >= 3)
                                    {
                                        if (resp != null && detail == null) { try { detail = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { } }
                                        resp?.Dispose();
                                        r.Status = status;
                                        r.Error = detail == null ? "HTTP " + status : ("HTTP " + status + ": " + (detail.Length > 300 ? detail.Substring(0, 300) : detail));
                                        break;
                                    }
                                    resp?.Dispose();
                                    attempt++;
                                    await Task.Delay(Math.Min(30000, 2000 * (1 << (attempt - 1)))).ConfigureAwait(false);
                                }
                            }
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
