FROM hexpm/elixir:1.19.5-erlang-28.5-debian-bookworm-20260421-slim AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

COPY services/elixir-phoenix/mix.exs services/elixir-phoenix/mix.lock ./
RUN mix deps.get --only prod --locked \
  && mix deps.compile

RUN elixir -e 'unless System.version() == "1.19.5", do: raise("bad elixir"); otp = :erlang.system_info(:otp_release) |> List.to_string(); path = Path.join([:code.root_dir() |> List.to_string(), "releases", otp, "OTP_VERSION"]); {:ok, version} = File.read(path); unless String.trim(version) == "28.5", do: raise("bad otp")'

COPY services/elixir-phoenix/config ./config
COPY services/elixir-phoenix/lib ./lib

RUN mix compile \
  && mix release stt_gateway \
  && OTP_MAJOR=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)])' -s init stop) \
  && ERTS_ROOT=$(erl -noshell -eval 'io:format("~s", [code:root_dir()])' -s init stop) \
  && mkdir -p _build/prod/rel/stt_gateway/releases/$OTP_MAJOR \
  && cp "$ERTS_ROOT/releases/$OTP_MAJOR/OTP_VERSION" "_build/prod/rel/stt_gateway/releases/$OTP_MAJOR/OTP_VERSION"

FROM debian:bookworm-20260421-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates locales libstdc++6 libncurses6 \
  && sed -i '/^# *en_US.UTF-8/s/^# *//' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=build /app/_build/prod/rel/stt_gateway ./

ENV PORT=4000
EXPOSE 4000
CMD ["bin/stt_gateway", "start"]
