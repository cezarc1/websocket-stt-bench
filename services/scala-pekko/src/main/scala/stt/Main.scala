package stt

import org.apache.pekko.actor.typed.ActorSystem
import org.apache.pekko.actor.typed.scaladsl.Behaviors
import org.slf4j.LoggerFactory
import stt.inference.JdkHttpInferenceClient
import stt.server.Server

object Main:

  private val log = LoggerFactory.getLogger(getClass)

  def main(args: Array[String]): Unit =
    val config = Config.load()
    given system: ActorSystem[Nothing] = ActorSystem(Behaviors.empty, "stt")

    val inference = JdkHttpInferenceClient(
      baseUrl = config.inferenceUrl,
      timeout = config.inferenceTimeout,
      clientCount = config.inferenceHttpClients
    )

    log.info(
      "runtime_versions runtime={} scala={} pekko={} inference_url={} flush_interval_ms={} inference_http_clients={}",
      Config.RuntimeName,
      Config.RuntimeScalaVersion,
      org.apache.pekko.Version.current,
      config.inferenceUrl,
      config.flushInterval.toMillis,
      config.inferenceHttpClients
    )

    Server.start(config, inference)
    log.info("listening on port {}", config.port)
