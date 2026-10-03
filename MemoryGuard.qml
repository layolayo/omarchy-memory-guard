import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "matthew.memory-guard"

  property int memPct: 0

  function refresh() {
    if (!memProc.running) memProc.running = true
  }

  function manageMem() {
    if (root.bar) root.bar.run("uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal.omaram --title=OMARAM-GUARD -e bash -c 'source omarchy-restart-gum; $HOME/.config/omarchy/plugins/matthew.memory-guard/scripts/omaram-guard.sh'")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: memProc
    command: ["/bin/bash", "-c", "$HOME/.config/omarchy/plugins/matthew.memory-guard/scripts/check-mem-pct.sh"]
    onExited: function(exitCode) {
      root.memPct = exitCode
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "RAM " + root.memPct + "%"
    fontSize: Style.font.caption
    horizontalMargin: 8
    
    // Use the button's built-in active state for color changing
    active: root.memPct >= 75
    activeColor: root.memPct >= 90 ? "#ff4444" : "#ffaa00"
    
    tooltipText: root.memPct >= 75 ? "High memory usage! Click to manage." : "OMARAM Guard active. Click to manage."
    onPressed: function() { root.manageMem() }
  }
}
