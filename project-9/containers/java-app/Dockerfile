FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /src
COPY Server.java .
RUN javac Server.java

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /src/Server.class .

ENV PORT=8081
EXPOSE 8081

CMD ["java", "Server"]
