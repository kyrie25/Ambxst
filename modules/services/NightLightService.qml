pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool active: StateService.get("nightLight", false)
    property int temperature: StateService.get("nightLightTemperature", 4500)
    property int gamma: StateService.get("nightLightGamma", 100)
    property var schedules: StateService.get("nightLightSchedules", [])
    property bool schedulesEnabled: StateService.get("nightLightSchedulesEnabled", false)

    property string configPath: ((Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/hypr/hyprsunset.conf")

    property bool _hyprsunsetRunning: false
    property bool _pendingApply: false

    // Start hyprsunset daemon
    property Process startProcess: Process {
        command: ["hyprsunset"]
        running: false
        onStarted: {
            root._hyprsunsetRunning = true
            // Wait briefly for the daemon to initialize before sending IPC
            ipcDelayTimer.start()
        }
        onExited: (code) => {
            root._hyprsunsetRunning = false
        }
    }

    Timer {
        id: ipcDelayTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (root._pendingApply) {
                root._pendingApply = false
                root.applySettings()
            }
        }
    }

    // Check if hyprsunset is already running
    property Process checkProcess: Process {
        command: ["pgrep", "-x", "hyprsunset"]
        running: false
        onExited: (code) => {
            root._hyprsunsetRunning = (code === 0)
            if (root.active) {
                if (!root._hyprsunsetRunning) {
                    root._pendingApply = true
                    root.ensureRunning()
                } else {
                    root.applySettings()
                }
            }
        }
    }

    // Apply temperature via hyprctl IPC
    property Process setTemperatureProcess: Process {
        running: false
        stdout: SplitParser {}
    }

    // Apply gamma via hyprctl IPC
    property Process setGammaProcess: Process {
        running: false
        stdout: SplitParser {}
    }

    // Reset to identity (disable filter)
    property Process identityProcess: Process {
        running: false
        stdout: SplitParser {}
    }

    // Write config file
    property Process writeConfigProcess: Process {
        running: false
        stdout: SplitParser {}
    }

    // Kill hyprsunset daemon
    property Process killProcess: Process {
        running: false
        stdout: SplitParser {}
        onExited: {
            root._hyprsunsetRunning = false
            if (root.active) {
                root._pendingApply = true
                root.ensureRunning()
            }
        }
    }

    // Ensure config directory exists
    property Process mkdirProcess: Process {
        running: false
        stdout: SplitParser {}
    }

    function ensureRunning() {
        if (!root._hyprsunsetRunning) {
            startProcess.running = true
        }
    }

    function toggle() {
        root.active = !root.active
        if (root.active) {
            if (!root._hyprsunsetRunning) {
                root._pendingApply = true
                root.ensureRunning()
            } else {
                applySettings()
            }
        } else {
            identityProcess.command = ["hyprctl", "hyprsunset", "identity"]
            identityProcess.running = true
        }
    }

    function applySettings() {
        if (!root._hyprsunsetRunning) {
            root._pendingApply = true
            root.ensureRunning()
            return
        }

        setTemperatureProcess.command = ["hyprctl", "hyprsunset", "temperature", root.temperature.toString()]
        setTemperatureProcess.running = true

        if (root.gamma !== 100) {
            setGammaProcess.command = ["hyprctl", "hyprsunset", "gamma", root.gamma.toString()]
            setGammaProcess.running = true
        }
    }

    function setTemperature(temp) {
        root.temperature = temp
        if (root.active && root._hyprsunsetRunning) {
            setTemperatureProcess.command = ["hyprctl", "hyprsunset", "temperature", temp.toString()]
            setTemperatureProcess.running = true
        }
    }

    function setGamma(g) {
        root.gamma = g
        if (root.active && root._hyprsunsetRunning) {
            setGammaProcess.command = ["hyprctl", "hyprsunset", "gamma", g.toString()]
            setGammaProcess.running = true
        }
    }

    function resetToProfile() {
        if (root._hyprsunsetRunning) {
            identityProcess.command = ["hyprctl", "hyprsunset", "identity"]
            identityProcess.running = true
        }
    }

    function restartDaemon() {
        killProcess.command = ["pkill", "-x", "hyprsunset"]
        killProcess.running = true
    }

    // =====================
    // SCHEDULE MANAGEMENT
    // =====================

    function addSchedule(time, temp, gam) {
        var list = JSON.parse(JSON.stringify(root.schedules))
        list.push({ time: time, temperature: temp, gamma: gam, identity: false })
        root.schedules = list
        writeConfig()
    }

    function updateSchedule(index, time, temp, gam, identity) {
        var list = JSON.parse(JSON.stringify(root.schedules))
        if (index >= 0 && index < list.length) {
            list[index] = { time: time, temperature: temp, gamma: gam, identity: identity }
            root.schedules = list
            writeConfig()
        }
    }

    function removeSchedule(index) {
        var list = JSON.parse(JSON.stringify(root.schedules))
        list.splice(index, 1)
        root.schedules = list
        writeConfig()
    }

    function setSchedulesEnabled(enabled) {
        root.schedulesEnabled = enabled
        writeConfig()
    }

    function writeConfig() {
        var conf = ""

        if (root.schedulesEnabled && root.schedules.length > 0) {
            var sortedSchedules = JSON.parse(JSON.stringify(root.schedules))
            sortedSchedules.sort(function(a, b) {
                return a.time.localeCompare(b.time)
            })

            for (var i = 0; i < sortedSchedules.length; i++) {
                var s = sortedSchedules[i]
                conf += "profile {\n"
                conf += "    time = " + s.time + "\n"
                if (s.identity) {
                    conf += "    identity = true\n"
                } else {
                    conf += "    temperature = " + s.temperature + "\n"
                    if (s.gamma !== undefined && s.gamma !== 100) {
                        conf += "    gamma = " + (s.gamma / 100).toFixed(2) + "\n"
                    }
                }
                conf += "}\n\n"
            }
        }

        var configDir = root.configPath.substring(0, root.configPath.lastIndexOf("/"))
        mkdirProcess.command = ["mkdir", "-p", configDir]
        mkdirProcess.running = true

        // Use printf to write the config file
        var escaped = conf.replace(/'/g, "'\\''")
        writeConfigProcess.command = ["sh", "-c", "printf '%s' '" + escaped + "' > \"" + root.configPath + "\""]
        writeConfigProcess.running = true
    }

    function syncState() {
        checkProcess.running = true
    }

    onActiveChanged: {
        if (StateService.initialized) {
            StateService.set("nightLight", active)
        }
    }

    onTemperatureChanged: {
        if (StateService.initialized) {
            StateService.set("nightLightTemperature", temperature)
        }
    }

    onGammaChanged: {
        if (StateService.initialized) {
            StateService.set("nightLightGamma", gamma)
        }
    }

    onSchedulesChanged: {
        if (StateService.initialized) {
            StateService.set("nightLightSchedules", schedules)
        }
    }

    onSchedulesEnabledChanged: {
        if (StateService.initialized) {
            StateService.set("nightLightSchedulesEnabled", schedulesEnabled)
        }
    }

    Connections {
        target: StateService
        function onStateLoaded() {
            root.active = StateService.get("nightLight", false)
            root.temperature = StateService.get("nightLightTemperature", 4500)
            root.gamma = StateService.get("nightLightGamma", 100)
            root.schedules = StateService.get("nightLightSchedules", [])
            root.schedulesEnabled = StateService.get("nightLightSchedulesEnabled", false)
            root.syncState()
        }
    }

    Timer {
        interval: 100
        running: true
        repeat: false
        onTriggered: {
            if (StateService.initialized) {
                root.active = StateService.get("nightLight", false)
                root.temperature = StateService.get("nightLightTemperature", 4500)
                root.gamma = StateService.get("nightLightGamma", 100)
                root.schedules = StateService.get("nightLightSchedules", [])
                root.schedulesEnabled = StateService.get("nightLightSchedulesEnabled", false)
                root.syncState()
            }
        }
    }
}
