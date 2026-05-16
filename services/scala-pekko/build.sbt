ThisBuild / scalaVersion := "3.3.7"
ThisBuild / organization := "stt"
ThisBuild / version := "0.1.0"

// Mirrors the repo's hard-pinning ethos: any version conflict during dependency
// resolution is an error, not a warning.
ThisBuild / evictionErrorLevel := Level.Error

lazy val pekkoVersion = "1.6.0"
lazy val pekkoHttpVersion = "1.3.0"
lazy val circeVersion = "0.14.15"
lazy val munitVersion = "1.1.0"
lazy val logbackVersion = "1.5.16"

lazy val root = (project in file("."))
  .enablePlugins(JavaAppPackaging)
  .settings(
    name := "stt-scala-pekko",
    Compile / mainClass := Some("stt.Main"),
    // Scala 3 already strict-by-default; -Werror promotes the remaining warnings.
    scalacOptions ++= Seq(
      "-encoding",
      "utf-8",
      "-feature",
      "-deprecation",
      "-Werror",
      "-Wunused:all",
      "-Wvalue-discard",
      "-Wnonunit-statement"
    ),
    // scalafix needs SemanticDB.
    semanticdbEnabled := true,
    libraryDependencies ++= Seq(
      "org.apache.pekko" %% "pekko-actor-typed" % pekkoVersion,
      "org.apache.pekko" %% "pekko-stream" % pekkoVersion,
      "org.apache.pekko" %% "pekko-http" % pekkoHttpVersion,
      "org.apache.pekko" %% "pekko-http-core" % pekkoHttpVersion,
      "ch.qos.logback" % "logback-classic" % logbackVersion,
      "io.circe" %% "circe-core" % circeVersion,
      "io.circe" %% "circe-generic" % circeVersion,
      "io.circe" %% "circe-parser" % circeVersion,
      "org.apache.pekko" %% "pekko-actor-testkit-typed" % pekkoVersion % Test,
      "org.apache.pekko" %% "pekko-stream-testkit" % pekkoVersion % Test,
      "org.scalameta" %% "munit" % munitVersion % Test
    ),
    testFrameworks += new TestFramework("munit.Framework"),
    // sbt-native-packager: produce a launcher script + lib/ directory for the
    // Docker runtime stage. The Dockerfile copies the staged output and runs
    // `bin/stt-scala-pekko`.
    Docker / packageName := "stt-scala-pekko"
  )
