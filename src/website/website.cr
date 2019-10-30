require "kemal"
require "kemal-csrf"
require "kemal-session"
require "oauth2"
require "kemal-session-redis"

require "raven/integrations/kemal"

require "tb"
require "tb-worker"

require "crometheus"

add_handler CSRF.new
add_handler AuthHandler.new

# Prometheus
metrics_handler = Crometheus.default_registry.get_handler
Crometheus.default_registry.path = "/metrics"

add_handler metrics_handler
add_handler Crometheus::Middleware::HttpCollector.new

# Raven
Raven.configure do |config|
  config.async = true
  config.current_environment = Kemal.config.env
end

Kemal.config.logger = Raven::Kemal::LogHandler.new(Kemal::LogHandler.new)

add_handler Raven::Kemal::ExceptionHandler.new

Kemal::Session.config do |config|
  config.secret = ENV["SECRET"]
  config.timeout = 10.minutes
  config.engine = Kemal::Session::RedisEngine.new(host: "redis", port: 6379)
end

macro default_render(file)
  render("src/website/views/#{{{file}}}", "src/website/layouts/default.ecr")
end

STDOUT.sync = true

class Website
  def self.run
    # Check for potential missed deposits during downtime
    queue_history_deposits_check

    redis = Redis.new(url: ENV["REDIS_URL"]?)

    redirect_uri = "#{ENV["HOST"]}/auth/callback/"

    discord_auth = DiscordOAuth2.new(ENV["DISCORD_CLIENT_ID"], ENV["DISCORD_CLIENT_SECRET"], redirect_uri + "discord")
    twitch_auth = TwitchOAuth2.new(ENV["TWITCH_CLIENT_ID"], ENV["TWITCH_CLIENT_SECRET"], redirect_uri + "twitch")

    get "/" do |env|
      default_render("index.ecr")
    end

    get "/terms" do |env|
      default_render("terms.ecr")
    end

    get "/balance" do |env|
      user = env.session.bigint?("user_id")
      halt env, status_code: 403 unless user.is_a?(Int64)
      default_render("balance.ecr")
    end

    get "/deposit" do |env|
      user = env.session.bigint?("user_id")
      halt env, status_code: 403 unless user.is_a?(Int64)
      default_render("deposit.ecr")
    end

    get "/statistics" do |env|
      default_render("statistics.ecr")
    end

    get "/link_accounts" do |env|
      user = env.session.bigint?("user_id")
      halt env, status_code: 403 unless user.is_a?(Int64)
      default_render("link_accounts.ecr")
    end

    get "/configuration" do |env|
      user = env.session.bigint?("user_id")
      halt env, status_code: 403 unless user.is_a?(Int64)
      default_render("configuration.ecr")
    end

    get "/admin" do |env|
      user = env.session.bigint?("user_id")
      halt env, status_code: 403 unless user.is_a?(Int64)

      # Admins only
      halt env, status_code: 500 unless user == 163607982473609216
      default_render("admin.cr")
    end

    # get "/redirect_auth" do |env|
    #   #       <<-HTML
    #   # <meta charset="UTF-8">
    #   # <meta http-equiv="refresh" content="1; url=http://127.0.0.1:3000/auth">

    #   # <script>
    #   # setTimeout(function(){
    #   #   window.location.href = "http://127.0.0.1:3000/auth"
    #   #   }, 5000);
    #   # </script>

    #   # <title>Page Redirection</title>

    #   # If you are not redirected automatically, follow the <a href='http://127.0.0.1:3000/auth'>link to example</a>
    #   # HTML
    # end

    get "/login" do |env|
      default_render("login.ecr")
    end

    get "/auth/:platform" do |env|
      case env.params.url["platform"]
      when "discord"
        scope = "identify"
        if env.params.query["scope"]? == "guilds"
          scope = "guilds"
          env.session.bool("store_admin_guilds", true)
        end
        env.redirect(discord_auth.authorize_uri(scope))
      when "twitch" then env.redirect(twitch_auth.authorize_uri(""))
      else               halt env, status_code: 400
      end
    end

    get "/auth/callback/:platform" do |env|
      case env.params.url["platform"]
      when "twitch"
        user = twitch_auth.get_user_id_with_authorization_code(env.params.query)
        env.session.bigint("twitch", user)
        user_id = TB::Data::Account.read(:twitch, user).id.to_i64
      when "discord"
        if env.session.bool?("store_admin_guilds")
          access_token = discord_auth.get_access_token(env.params.query, "guilds")
          guilds = discord_auth.get_user_admin_guilds(access_token)
        else
          access_token = discord_auth.get_access_token(env.params.query)
        end

        user = discord_auth.get_user_id(access_token)
        env.session.bigint("discord", user)

        user_id = TB::Data::Account.read(:discord, user).id.to_i64
      else
        halt env, status_code: 400
      end

      env.session.bigint("user_id", user_id)
      if guilds
        redis.set("admin_guilds-#{user_id}", guilds.to_json)
      end

      origin = env.session.string?("origin")
      env.session.string("origin", "/")

      env.redirect(origin || "/")
    end

    get "/logout" do |env|
      env.session.destroy
      env.redirect("/")
    end

    # walletnotify=curl --retry 10 -X POST http://website:3000/walletnotify?coin=0&tx=%s
    get "/walletnotify" do |env|
      coin = TB::Data::Coin.read(env.params.query["coin"].to_i32)
      tx = env.params.query["tx"]

      TB::Data::Deposit.create(tx, coin, :new)
    end

    # get "/docs" do |env|
    #   # env.redirect("/docs/index.html")
    #   env.redirect("https://github.com/greenbigfrog/discordtipbot/tree/master/docs")
    # end

    # post "/webhook/:coin" do |env|
    #   headers = env.request.headers
    #   json = env.params.json
    #   coin = env.params.url["coin"]

    #   halt env, status_code: 403 unless headers["Authorization"]? == data[coin].dbl_auth

    #   unless json["type"] == "upvote"
    #     puts "Received test webhook call"
    #     halt env, status_code: 204
    #   end
    #   query = json["query"]?
    #   params = HTTP::Params.parse(query.lchop('?')) if query.is_a?(String)
    #   server = params["server"]? if params

    #   user = json["user"]
    #   halt env, status_code: 503 unless user.is_a?(String)
    #   user = user.to_u64

    #   if server
    #     data[coin].extend_premium(Premium::Kind::Guild, server.to_u64, 30.minutes)
    #     msg = "Thanks for voting. Extended premium of #{server} by 15 **x2** minutes"
    #   else
    #     data[coin].extend_premium(Premium::Kind::User, user, 2.hour)
    #     msg = "Thanks for voting. Extended your own personal global premium by 1 **x2** hours"
    #   end

    #   if coin == "dogecoin"
    #     str = "1 DOGE"
    #     amount = 1
    #   else
    #     str = "5 ECA"
    #     amount = 5
    #   end
    #   data[coin].db.exec(SQL, user, amount)

    #   msg = "#{msg}\nAs a christmas present you've received twice as much premium time as well as #{str} courtesy of <@163607982473609216>"

    #   queue.push(Msg.new(coin, user, msg))
    # end

    get "/qr/:link" do |env|
      link = env.params.url["link"]
      env.redirect("https://chart.googleapis.com/chart?cht=qr&chs=300x300&chld=L%7C1&chl=#{link}")
    end

    post "/api/generate_deposit_address" do |env|
      user = env.session.bigint?("user_id")
      halt env, status_code: 403 unless user.is_a?(Int64)

      coin = TB::Data::Coin.read(env.params.query["coin"].to_i32)

      begin
        TB::Data::DepositAddress.read_or_create(coin, TB::Data::Account.read(user))
      rescue ex
        if ex.message == "Unable to connect to RPC"
          halt env, 503, "Please try again later. Unable to connect to RPC"
        else
          halt env, 500, "Something went wrong. Please visit #{TB::SUPPORT} for support"
        end
      end

      env.redirect("/deposit")
    end

    {"prefix", "mention", "soak", "rain", "min_soak",
     "min_soak_total", "min_rain", "min_rain_total",
     "min_tip", "min_lucky"}

    post "/api/guild_config" do |env|
      user = env.session.bigint?("user_id")
      halt env, status_code: 403 unless user.is_a?(Int64)

      params = env.params.body
      config_id = params["config_id"].to_i64

      guild = TB::Data::Discord::Guild.read_guild_id(config_id)

      guilds = Array(DiscordGuild).from_json(redis.get("admin_guilds-#{user}").not_nil!)
      halt env, status_code: 403 unless guilds.any? { |x| x.id == guild }

      prefix = params["prefix"]?
      prefix = nil if prefix == ""

      mention = params["mention"]? ? true : false
      soak = params["soak"]? ? true : false
      rain = params["rain"]? ? true : false

      min_soak = parse_bd(params["min_soak"]?)
      min_soak_total = parse_bd(params["min_soak_total"]?)
      min_rain = parse_bd(params["min_rain"]?)
      min_rain_total = parse_bd(params["min_rain_total"]?)
      min_tip = parse_bd(params["min_tip"]?)
      min_lucky = parse_bd(params["min_lucky"]?)

      TB::Data::Discord::Guild.update_config(config_id, prefix, mention, soak, rain,
        min_soak, min_soak_total, min_rain, min_rain_total,
        min_tip, min_lucky)

      env.session.bool("saved_guild_config", true)
      env.redirect("/configuration")
    end

    Kemal.run
  end

  private def self.queue_history_deposits_check
    TB::Worker::HistoryDeposits.new.enqueue
  end

  private def self.parse_bd(string : String?) : BigDecimal?
    return nil if string.nil?
    begin
      BigDecimal.new(string)
    rescue
      nil
    end
  end
end
