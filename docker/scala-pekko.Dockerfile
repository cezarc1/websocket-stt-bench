# Pinned Scala 3.3 LTS + sbt 1.12 on Temurin 25 — single tool image with the full toolchain.
# Pin to a sha256 digest in versions.lock.toml [containers.scala] when refreshing.
ARG SBT_IMAGE=sbtscala/scala-sbt:eclipse-temurin-25.0.1_8_1.12.11_3.3.7@sha256:6fe01cddabc2896069d3605b25a77343e93a11e2f45831bd9b54e0fb631ed96c
ARG JRE_IMAGE=eclipse-temurin:25-jre-noble@sha256:b27ca47660a8fa837e47a8533b9b1a3a430295cf29ca28d91af4fd121572dc29

FROM ${SBT_IMAGE} AS build

WORKDIR /app/services/scala-pekko

# Resolve deps first so source edits don't bust the Coursier cache.
COPY services/scala-pekko/build.sbt ./
COPY services/scala-pekko/project ./project
RUN --mount=type=cache,target=/root/.ivy2 \
    --mount=type=cache,target=/root/.cache/coursier \
    --mount=type=cache,target=/root/.sbt \
    sbt -batch update

COPY services/scala-pekko/src ./src
COPY services/scala-pekko/.scalafmt.conf ./
COPY services/scala-pekko/.scalafix.conf ./
RUN --mount=type=cache,target=/root/.ivy2 \
    --mount=type=cache,target=/root/.cache/coursier \
    --mount=type=cache,target=/root/.sbt \
    sbt -batch "stage"

FROM ${JRE_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/services/scala-pekko/target/universal/stage /opt/stt-scala-pekko
RUN chmod -R a+rX /opt/stt-scala-pekko

# `-Xms == -Xmx` keeps ZGC from growing committed memory during ramp; `+AlwaysPreTouch`
# pre-faults heap pages at startup, eliminating first-touch page-fault spikes at the cliff.
ENV JAVA_OPTS="-XX:+UseZGC -Xms1536m -Xmx1536m -XX:+AlwaysPreTouch" \
    PORT=2500

EXPOSE 2500
ENTRYPOINT ["sh", "-c", "exec /opt/stt-scala-pekko/bin/stt-scala-pekko $JAVA_OPTS"]
