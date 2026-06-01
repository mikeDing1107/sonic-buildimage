#!/usr/bin/env python3
import json
import os
from sonic_py_common import daemon_base
from swsscommon import swsscommon

CONFIG_FILE = "/tmp/cpu_monitor_config.json"


class ConfigListener(daemon_base.DaemonBase):
    def __init__(self):
        super(ConfigListener, self).__init__("cpu_monitor_config_listener")
        self.config_db = swsscommon.DBConnector("CONFIG_DB", 0, False)
        self.subscriber = swsscommon.SubscriberStateTable(self.config_db, "CPU_MONITOR")

        self.current_config = {"enable": False, "interval": 10}
        self.save_config()

    def save_config(self):
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(self.current_config, f)
            self.log_info(f"Config saved to {CONFIG_FILE}: {self.current_config}")
        except Exception as e:
            self.log_error(f"Failed to save config: {e}")

    def load_initial_config(self):
        try:
            table = swsscommon.Table(self.config_db, "CPU_MONITOR")
            keys = table.getKeys()
            if "global" in keys:
                status, fvp = table.get("global")
                if status:
                    fvp_dict = dict(fvp)
                    enable_str = fvp_dict.get("enable", "false").lower()
                    interval_str = fvp_dict.get("interval", "10")

                    self.current_config["enable"] = enable_str in ["true", "1", "yes"]
                    try:
                        self.current_config["interval"] = max(1, int(interval_str))
                    except ValueError:
                        self.current_config["interval"] = 10
                    self.save_config()
        except Exception as e:
            self.log_error(f"Failed to load initial config: {e}")

    def handle_config_change(self, key, op, fvp):
        if op != "SET":
            return

        fvp_dict = dict(fvp)
        enable_str = fvp_dict.get("enable", "false").lower()
        interval_str = fvp_dict.get("interval", "10")

        self.current_config["enable"] = enable_str in ["true", "1", "yes"]
        try:
            self.current_config["interval"] = max(1, int(interval_str))
        except ValueError:
            self.current_config["interval"] = 10

        self.save_config()

    def run(self):
        self.log_info("Config Listener started...")
        self.load_initial_config()

        sel = swsscommon.Select()
        sel.addSelectable(self.subscriber)

        while True:
            state, selectable = sel.select(1000)
            if state == swsscommon.Select.OBJECT:
                key, op, fvp = self.subscriber.pop()
                self.handle_config_change(key, op, fvp)


def main():
    listener = ConfigListener()
    listener.run()


if __name__ == "__main__":
    main()
