# status-notifier

Polls the services deployed by `../ec2-deploy` and `../ecs-deploy` and posts a Telegram message
every time one flips between up and down — the "service management, alert service down" TODO
from the root README.

Two check types:
- `http` — `GET` a health URL, up if status < 400 (matches `../containers/*`'s `/health`).
- `ecs` — `DescribeServices`, up if `runningCount >= desiredCount` and `desiredCount > 0`.

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather) → copy the token it gives you.
2. Message the bot once, then get your chat id (e.g. via `https://api.telegram.org/bot<token>/getUpdates`,
   or by messaging [@userinfobot](https://t.me/userinfobot)).
3. Copy the example config files and fill them in:

```bash
cp config/.env.example config/.env
cp config/services.yml.example config/services.yml
# edit config/.env with your bot token + chat id
# edit config/services.yml with the health URLs / ECS services to watch
```

4. Run it:

```bash
docker compose up -d --build
docker compose logs -f
```

It logs each service's initial status on startup, then only messages Telegram on a state
*change* — no repeated pings while something stays down.
