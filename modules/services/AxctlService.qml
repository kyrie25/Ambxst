pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var focusedMonitor: null
    property var focusedWorkspace: null
    property var focusedClient: null

    property int focusHistoryCounter: 0

    property QtObject clients: QtObject {
        property var values: []
    }

    property QtObject monitors: QtObject {
        property var values: []
    }

    property QtObject workspaces: QtObject {
        property var values: []
    }

    signal rawEvent(var event)

    function dispatch(command) {
        if (!command) return;

        let spaceIdx = command.indexOf(' ');
        let action = spaceIdx !== -1 ? command.substring(0, spaceIdx).trim() : command.trim();
        let rawArgs = spaceIdx !== -1 ? command.substring(spaceIdx + 1).trim() : "";

        let getAddr = (str) => {
            let m = str.match(/address:([^\s,]+)/);
            return m ? m[1] : str.trim();
        };

        let cmdArgs = [];

        if (action === "workspace") {
            cmdArgs = ["workspace", "switch", rawArgs];
        } else if (action === "closewindow") {
            cmdArgs = ["window", "close", getAddr(rawArgs)];
        } else if (action === "focuswindow") {
            cmdArgs = ["window", "focus", getAddr(rawArgs)];
        } else if (action === "movetoworkspacesilent") {
            let subParts = rawArgs.split(',');
            cmdArgs = ["window", "move-to-workspace-silent", subParts[0].trim()];
            if (subParts.length > 1) {
                cmdArgs.push(getAddr(subParts[1]));
            }
        } else if (action === "togglespecialworkspace") {
            cmdArgs = ["workspace", "toggle-special"];
            if (rawArgs) cmdArgs.push(rawArgs);
        } else {
            cmdArgs = ["system", "execute", "hyprctl dispatch " + command];
        }

        let finalCommand = ["axctl"].concat(cmdArgs.filter(x => x !== "" && x !== undefined));
        
        let proc = Qt.createQmlObject('import Quickshell.Io; Process {}', root);
        proc.command = finalCommand;
        proc.onExited.connect(() => proc.destroy());
        proc.running = true;
    }

    function monitorFor(screen) {
        if (!screen) return null;
        let screenName = screen.name || screen;
        let values = root.monitors.values || [];
        for (let i = 0; i < values.length; i++) {
            if (values[i].name === screenName) return values[i];
        }
        return null;
    }

    property Process axctlProcess: Process {
        command: ["axctl", "daemon"]
        running: true
        stdout: SplitParser {
            onRead: (data) => {
                // Daemon logs can be printed here if needed
            }
        }
        onExited: (code) => {
            console.warn("axctl daemon exited with code:", code)
        }
    }

    property Process getWindowsProcess: Process {
        command: ["bash", "-c", "axctl window list | jq -c"]
        stdout: SplitParser {
            onRead: (data) => {
                if (!data) return;
                try {
                    let winData = JSON.parse(data);
                    let existingClients = root.clients.values || [];
                    let mappedClients = winData.map(win => {
                        let existing = existingClients.find(c => c.address === win.id);
                        let prevFocus = existing && existing.focusHistoryID !== undefined ? existing.focusHistoryID : 999999;
                        let newFocus = win.is_focused ? (existing && existing.is_focused ? prevFocus : --root.focusHistoryCounter) : prevFocus;
                        return {
                            address: win.id,
                            class: win.app_id,
                            title: win.title,
                            workspace: { id: parseInt(win.workspace_id) || 0, name: win.workspace_id },
                            monitor: parseInt(win.metadata ? win.metadata.monitor_id : 0) || 0,
                            floating: win.is_floating,
                            fullscreen: win.is_fullscreen,
                            hidden: win.is_hidden,
                            mapped: true,
                            at: [win.metadata ? (win.metadata.x || 0) : 0, win.metadata ? (win.metadata.y || 0) : 0],
                            size: [win.metadata ? (win.metadata.width || 100) : 100, win.metadata ? (win.metadata.height || 100) : 100],
                            xwayland: (win.metadata ? win.metadata.xwayland : false) || false,
                            is_focused: win.is_focused || false,
                            focusHistoryID: newFocus
                        };
                    });
                    root.clients.values = mappedClients;
                    let focused = mappedClients.find(w => w.address === (root.focusedClient ? root.focusedClient.address : undefined)) || mappedClients.find(w => w.is_focused) || null;
                    if (focused !== root.focusedClient) {
                        root.focusedClient = focused;
                    }
                } catch(e) {
                    console.error("AxctlService getWindows error:", e);
                }
            }
        }
    }

    property Process getWorkspacesProcess: Process {
        command: ["bash", "-c", "axctl workspace list | jq -c"]
        stdout: SplitParser {
            onRead: (data) => {
                if (!data) return;
                try {
                    let wsData = JSON.parse(data);
                    let mappedWorkspaces = wsData.map(ws => ({
                        id: parseInt(ws.id) || 0,
                        name: ws.name,
                        monitor: ws.monitor_id,
                        active: ws.is_active,
                        windows: 0
                    }));
                    root.workspaces.values = mappedWorkspaces;
                    let focused = mappedWorkspaces.find(ws => ws.active) || null;
                    if (focused !== root.focusedWorkspace) {
                        root.focusedWorkspace = focused;
                    }
                } catch(e) {
                    console.error("AxctlService getWorkspaces error:", e);
                }
            }
        }
    }

    property Process getMonitorsProcess: Process {
        command: ["bash", "-c", "axctl monitor list | jq -c"]
        stdout: SplitParser {
            onRead: (data) => {
                if (!data) return;
                try {
                    let monData = JSON.parse(data);
                    let mappedMonitors = monData.map(mon => ({
                        id: parseInt(mon.id) || 0,
                        name: mon.name,
                        focused: mon.is_focused,
                        width: mon.width,
                        height: mon.height,
                        refreshRate: mon.refresh_rate,
                        scale: mon.scale,
                        activeWorkspace: { id: parseInt(mon.metadata ? mon.metadata.active_workspace : 0) || 0, name: mon.metadata ? mon.metadata.active_workspace : "" }
                    }));
                    root.monitors.values = mappedMonitors;
                    let focused = mappedMonitors.find(m => m.focused) || null;
                    if (focused !== root.focusedMonitor) {
                        root.focusedMonitor = focused;
                    }
                } catch(e) {
                    console.error("AxctlService getMonitors error:", e);
                }
            }
        }
    }

    Timer {
        id: fetchDebouncer
        interval: 100
        onTriggered: {
            getWindowsProcess.running = true;
            getWorkspacesProcess.running = true;
            getMonitorsProcess.running = true;
        }
    }

    function fetchInitialState() {
        fetchDebouncer.restart();
    }

    property Process axctlSubscribe: Process {
        command: ["bash", "-c", "sleep 0.5 && axctl subscribe"]
        running: true
        stdout: SplitParser {
            onRead: (data) => {
                if (!data) return;
                try {
                    let parsedJson = JSON.parse(data);
                    parsedJson.name = parsedJson.method ? parsedJson.method.split('.').pop().toLowerCase() : "";
                    parsedJson.data = parsedJson.params;

                    if (parsedJson.name === "window_focus" || parsedJson.name === "windowfocused" || parsedJson.name === "activewindow") {
                        let clientsArray = root.clients.values || [];
                        let pClass = parsedJson.data && parsedJson.data.Class;
                        let pTitle = parsedJson.data && parsedJson.data.Title;
                        let pId = parsedJson.data && parsedJson.data.id;
                        let updated = false;

                        for (let i = 0; i < clientsArray.length; i++) {
                            let match = false;
                            if (pId && clientsArray[i].address === pId) {
                                match = true;
                            } else if (!pId && pClass && pTitle && clientsArray[i].class === pClass && clientsArray[i].title === pTitle) {
                                match = true;
                            } else if (typeof parsedJson.data === "string" && clientsArray[i].address === parsedJson.data) {
                                match = true;
                            }

                            if (match) {
                                clientsArray[i].focusHistoryID = --root.focusHistoryCounter;
                                clientsArray[i].is_focused = true;
                                updated = true;
                            } else if (clientsArray[i].is_focused) {
                                clientsArray[i].is_focused = false;
                                updated = true;
                            }
                        }
                        if (updated) root.clients.values = clientsArray;
                    }
                    root.rawEvent(parsedJson);
                    fetchInitialState();
                } catch (e) {
                    console.error("AxctlService subscribe JSON parse error:", e);
                }
            }
        }
        onExited: (code) => {
            console.warn("axctl subscribe exited:", code);
        }
    }
    
    Component.onCompleted: {
        fetchInitialState();
    }

    Component.onDestruction: {
        axctlProcess.running = false
        axctlSubscribe.running = false
    }
}
