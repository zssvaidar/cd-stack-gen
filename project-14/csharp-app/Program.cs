using System.Text.Json;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Prometheus;

var builder = WebApplication.CreateBuilder(args);

// Same convention as the other apps: listen on $HOST:$PORT (default 0.0.0.0:8080).
var host = Environment.GetEnvironmentVariable("HOST") ?? "0.0.0.0";
var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
builder.WebHost.UseUrls($"http://{host}:{port}");

// Tag checks "ready" to have /health/ready include them (e.g. AddNpgSql, AddDbContextCheck).
builder.Services.AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy(), tags: ["ready"]);

// Behind an AWS ALB: honour X-Forwarded-For / X-Forwarded-Proto.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownIPNetworks.Clear();
    options.KnownProxies.Clear();
});

var app = builder.Build();

app.UseForwardedHeaders();

// Request count/duration per route (http_request_duration_seconds), plus .NET runtime metrics.
app.UseHttpMetrics();

app.MapGet("/", () => new { app = "csharp-app", message = "Hello from ASP.NET Core" });

// Liveness: process is up, runs no checks.
app.MapHealthChecks("/health", new HealthCheckOptions
{
    Predicate = _ => false,
    ResponseWriter = WriteJson,
});

// Readiness: runs every check tagged "ready".
app.MapHealthChecks("/health/ready", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready"),
    ResponseWriter = WriteJson,
});

// Prometheus metrics. Behind Caddy on the AMIs this path is blocked; Alloy scrapes it on loopback.
app.MapMetrics("/metrics");

app.Run();

static Task WriteJson(HttpContext context, HealthReport report)
{
    context.Response.ContentType = "application/json";
    var body = new
    {
        status = report.Status == HealthStatus.Healthy ? "UP" : "DOWN",
        checks = report.Entries.ToDictionary(e => e.Key, e => e.Value.Status == HealthStatus.Healthy ? "UP" : "DOWN"),
    };
    return context.Response.WriteAsync(JsonSerializer.Serialize(body));
}
