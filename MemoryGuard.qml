import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.layolayo.memory-guard"

  property int memPct: 0
  property int lastAlertLevel: 0    // 0: normal (<80), 1: warning (80-89), 2: critical (90+)
  property double lastAlertTime: 0  // Milliseconds epoch timestamp

  function refresh() {
    if (!memProc.running) memProc.running = true
  }

  function manageMem() {
    if (root.bar) {
      root.bar.run("$HOME/.config/omarchy/plugins/io.github.layolayo.memory-guard/scripts/launch-omaram.sh")
    }
  }

  function checkAlerts(pct) {
    var now = Date.now()
    var launcher = "$HOME/.config/omarchy/plugins/io.github.layolayo.memory-guard/scripts/launch-omaram.sh"

    if (pct >= 90) {
      // Critical Alert: trigger if escalating to level 2, or if 3 minutes have passed since last alert
      if (root.lastAlertLevel < 2 || (now - root.lastAlertTime > 180000)) {
        root.lastAlertLevel = 2
        root.lastAlertTime = now
        if (root.bar) {
          root.bar.run("omarchy-notification-send --app-name 'OMARAM Guard' -g '󰍛' -u critical 'Critical Memory: " + pct + "% Used' 'System memory is critically low! Click to open OMARAM Guard.' --exec " + launcher)
        }
      }
    } else if (pct >= 80) {
      // Warning Alert: trigger if escalating to level 1, or if 5 minutes have passed since last alert
      if (root.lastAlertLevel < 1 || (now - root.lastAlertTime > 300000)) {
        root.lastAlertLevel = 1
        root.lastAlertTime = now
        if (root.bar) {
          root.bar.run("omarchy-notification-send --app-name 'OMARAM Guard' -g '󰍛' -u normal 'High Memory Warning: " + pct + "% Used' 'Click to open OMARAM Guard and manage processes.' --exec " + launcher)
        }
      }
    } else if (pct < 75) {
      // Reset alert level when memory returns to safe thresholds
      root.lastAlertLevel = 0
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: memProc
    command: ["/bin/bash", "-c", "$HOME/.config/omarchy/plugins/io.github.layolayo.memory-guard/scripts/check-mem-pct.sh"]
    onExited: function(exitCode) {
      root.memPct = exitCode
      root.checkAlerts(exitCode)
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
