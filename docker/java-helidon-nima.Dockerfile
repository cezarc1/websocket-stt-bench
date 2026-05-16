# Pinned Maven + Temurin JDK 25 build image (Maven 3.9.11 on Temurin 25 / Noble).
ARG MAVEN_IMAGE=maven:3.9.11-eclipse-temurin-25-noble@sha256:407c4423cec0cf2981055bc2c6c0dc211d9605b6669279b95997f2d1c7e91e2c
ARG JRE_IMAGE=eclipse-temurin:25-jre-noble@sha256:b27ca47660a8fa837e47a8533b9b1a3a430295cf29ca28d91af4fd121572dc29

FROM ${MAVEN_IMAGE} AS build

WORKDIR /app/services/java-helidon-nima

# Resolve dependencies first so source edits don't bust this cache layer.
COPY services/java-helidon-nima/pom.xml ./
COPY services/java-helidon-nima/.mvn ./.mvn
RUN --mount=type=cache,target=/root/.m2 \
  mvn -B -q -DskipTests dependency:go-offline

COPY services/java-helidon-nima/src ./src
RUN --mount=type=cache,target=/root/.m2 \
  mvn -B -q -DskipTests package \
  && cp target/stt-java-helidon-nima.jar /usr/local/lib/stt-java-helidon-nima.jar

FROM ${JRE_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/lib/stt-java-helidon-nima.jar /usr/local/lib/stt-java-helidon-nima.jar

# JEP 491 (delivered in JDK 24, inherited here) makes synchronized-vs-blocking
# pins structurally impossible, so we don't enable -Djdk.tracePinnedThreads=full
# by default — at high session counts even rare prints would flood stderr and
# stall a carrier. Opt back in via `JAVA_OPTS=... -Djdk.tracePinnedThreads=full`
# for dev/conformance diagnostics.
# `-Xms == -Xmx` keeps ZGC from growing committed memory during ramp; `+AlwaysPreTouch`
# pre-faults all heap pages at startup, eliminating first-touch page-fault spikes at the
# 2600-session edge. Costs ~1s of warmup time; pays back in p99 stability.
ENV JAVA_OPTS="-XX:+UseZGC -Xms1536m -Xmx1536m -XX:+AlwaysPreTouch" \
    PORT=5000

EXPOSE 5000
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /usr/local/lib/stt-java-helidon-nima.jar"]
