#!/usr/bin/env python3
"""Polls configured services and posts a Telegram message on every up/down transition."""

import logging
import os
import time

import requests
import yaml
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("status-notifier")

TELEGRAM_BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
TELEGRAM_CHAT_ID = os.environ["TELEGRAM_CHAT_ID"]
SERVICES_CONFIG = os.environ.get("SERVICES_CONFIG", "config/services.yml")


def load_config(path):
    with open(path) as f:
        return yaml.safe_load(f)


def send_telegram(message):
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    try:
        resp = requests.post(url, data={"chat_id": TELEGRAM_CHAT_ID, "text": message}, timeout=10)
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error("failed to send telegram message: %s", exc)


def check_http(service, timeout):
    try:
        resp = requests.get(service["url"], timeout=timeout)
        return resp.status_code < 400
    except requests.RequestException:
        return False


def check_ecs(service, timeout):
    import boto3  # imported lazily so http-only setups don't need boto3/AWS creds

    client = boto3.client("ecs", region_name=service["region"])
    resp = client.describe_services(cluster=service["cluster"], services=[service["service"]])
    services = resp.get("services", [])
    if not services:
        return False
    svc = services[0]
    return svc["desiredCount"] > 0 and svc["runningCount"] >= svc["desiredCount"]


CHECKERS = {
    "http": check_http,
    "ecs": check_ecs,
}


def main():
    config = load_config(SERVICES_CONFIG)
    poll_interval = config.get("poll_interval_seconds", 30)
    timeout = config.get("request_timeout_seconds", 5)
    services = config["services"]

    state = {svc["name"]: None for svc in services}

    log.info("watching %d service(s), polling every %ss", len(services), poll_interval)

    while True:
        for service in services:
            name = service["name"]
            checker = CHECKERS[service["type"]]

            try:
                is_up = checker(service, timeout)
            except Exception as exc:
                log.error("check for %s raised %s", name, exc)
                is_up = False

            previous = state[name]
            status = "UP" if is_up else "DOWN"

            if previous is None:
                log.info("%s initial status: %s", name, status)
            elif previous != is_up:
                emoji = "✅" if is_up else "\U0001F534"
                message = f"{emoji} {name} is {status}"
                log.warning(message)
                send_telegram(message)

            state[name] = is_up

        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
