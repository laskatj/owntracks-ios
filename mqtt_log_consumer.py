#!/usr/bin/env python3
"""
MQTT log consumer for OwnTracks iOS app.
Subscribes to <base_topic>/logs and appends received messages to inbound.log.
"""

import paho.mqtt.client as mqtt

# --- Configuration (stub — replace before use) ---
BROKER_HOST = "mediahub"
BROKER_PORT = 1883
BROKER_USERNAME = "laskatj"
BROKER_PASSWORD = "abelard9"
USE_TLS = False

BASE_TOPIC = "owntracks/Laska Tom/Toms iPhone OT"
LOG_TOPIC = f"{BASE_TOPIC}/logs"

LOG_FILE = "inbound.log"
# -------------------------------------------------


def on_connect(client, userdata, flags, reason_code, properties):
    print(f"on_connect fired: reason_code={reason_code!r} (type={type(reason_code).__name__})")
    if not reason_code.is_failure:
        print(f"Connected. Subscribing to: {LOG_TOPIC!r}")
        result, mid = client.subscribe(LOG_TOPIC)
        print(f"subscribe() returned result={result} mid={mid}")
    else:
        print(f"Connection failed: {reason_code}")


def on_subscribe(client, userdata, mid, reason_code_list, properties):
    print(f"Subscription confirmed mid={mid}: {[str(rc) for rc in reason_code_list]}")


def on_message(client, userdata, msg):
    print(f"Message received on {msg.topic!r}: {msg.payload!r}")
    payload = msg.payload.decode("utf-8", errors="replace")
    with open(LOG_FILE, "a") as f:
        f.write(payload + "\n")


def on_disconnect(client, userdata, flags, reason_code, properties):
    print(f"Disconnected: reason_code={reason_code!r}")


def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.username_pw_set(BROKER_USERNAME, BROKER_PASSWORD)

    if USE_TLS:
        client.tls_set()

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message
    client.on_disconnect = on_disconnect

    print(f"Connecting to {BROKER_HOST}:{BROKER_PORT} ...")
    print(f"Will subscribe to: {LOG_TOPIC!r}")
    client.connect(BROKER_HOST, BROKER_PORT, keepalive=60)
    client.loop_forever()


if __name__ == "__main__":
    main()
