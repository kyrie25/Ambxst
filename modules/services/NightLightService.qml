pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool active: StateService.get("nightLight", false)
    property int temperature: StateService.get("nightLightTemperature", 4500)
    property int gamma: StateService.get("nightLightGamma", 100)

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

    function restartDaemon() {
        killProcess.command = ["pkill", "-x", "hyprsunset"]
        killProcess.running = true
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

    Connections {
        target: StateService
        function onStateLoaded() {
            root.active = StateService.get("nightLight", false)
            root.temperature = StateService.get("nightLightTemperature", 4500)
            root.gamma = StateService.get("nightLightGamma", 100)
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
                root.syncState()
            }
        }
    }
}
