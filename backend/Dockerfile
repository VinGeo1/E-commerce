# --- Stage 1: build the fat jar ---------------------------------------------
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -B clean package -DskipTests

# --- Stage 2: runtime --------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
# The container gets a 512 MiB hard limit in infrastructure/ecs.tf. The JVM's default
# heap cap is 25% of that (128 MiB), which is tight for Spring Boot 3 + Hibernate; 50%
# leaves room for metaspace/threads under the cgroup limit. ExitOnOutOfMemoryError
# turns a heap OOM into a container exit so ECS restarts the task instead of leaving
# a wedged process behind the ALB. Override per environment via JAVA_TOOL_OPTIONS in
# the task definition.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=50.0 -XX:+ExitOnOutOfMemoryError"
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
