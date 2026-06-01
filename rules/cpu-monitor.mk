# rules/cpu-monitor.mk

CPU_MONITOR_VERSION := 1.0.0
export CPU_MONITOR_VERSION

CPU_MONITOR = cpu-monitor_$(CPU_MONITOR_VERSION)_all.deb
$(CPU_MONITOR)_SRC_PATH = $(SRC_PATH)/cpu-monitor
$(CPU_MONITOR)_BLD_ENV := python

SONIC_DPKG_DEBS += $(CPU_MONITOR)

-include $(RULES_PATH)/cpu-monitor.dep
