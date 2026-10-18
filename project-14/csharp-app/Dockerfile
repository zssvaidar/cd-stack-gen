# syntax=docker/dockerfile:1
# ASP.NET Core for ECS/Fargate, App Runner, EKS or EC2.
# Build:  docker build -t csharp-app .
# Run:    docker run -p 8080:8080 csharp-app

# --- build -------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /src
COPY CsharpApp.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app --no-restore /p:UseAppHost=false

# --- runtime -----------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine
WORKDIR /app
COPY --from=build /app ./
# Built-in non-root "app" user of the official .NET images.
USER $APP_UID

ENV PORT=8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_gcServer=0
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/health" || exit 1

ENTRYPOINT ["dotnet", "CsharpApp.dll"]
