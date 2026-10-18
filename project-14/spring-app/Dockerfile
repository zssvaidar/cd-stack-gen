# syntax=docker/dockerfile:1
# Spring Boot (actuator health) for ECS/Fargate, App Runner, EKS or EC2.
# Build:  docker build -t spring-app .
# Run:    docker run -p 8080:8080 spring-app

# --- build -------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml ./
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B -q package -DskipTests \
 && cp target/*.jar /app.jar \
 && java -Djarmode=tools -jar /app.jar extract --layers --launcher --destination /extracted

# --- runtime -----------------------------------------------------------------
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
# Dependency layers first so code-only changes reuse cached layers.
COPY --from=build /extracted/dependencies/ ./
COPY --from=build /extracted/spring-boot-loader/ ./
COPY --from=build /extracted/snapshot-dependencies/ ./
COPY --from=build /extracted/application/ ./
USER app

ENV PORT=8080 \
    JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/actuator/health" | grep -q '"UP"' || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
