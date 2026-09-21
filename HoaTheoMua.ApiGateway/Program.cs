using HoaTheoMua.ApiGateway.DependencyInjection.Extensions;

var builder = WebApplication.CreateBuilder(args);

builder.Configuration
    .AddEnvironmentVariables();

// Add services to the container.
builder.Services.AddReverseProxyApiGateway(builder.Configuration);
builder.Services.AddRequestTimeouts();

var app = builder.Build();

// Configure the HTTP request pipeline.
// Gateway is a pure pass-through proxy: it does NOT authenticate or authorize.
// Each downstream service owns its own authn/authz (validates the forwarded token itself).
app.UseRouting();
app.UseRequestTimeouts();
app.MapReverseProxy();

app.Run();