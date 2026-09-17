import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// tun0 VPN: a shield in the bar and a panel behind it.
//
//   left = panel · right = connect / disconnect · middle = refresh
//
// The widget owns no state of its own. Everything it shows comes from `vpn json`, everything
// it does is a `vpn <verb>` (see Service.qml); the kill switch, the watchdog and the
// trusted-network logic keep working exactly the same with the panel closed, from a terminal,
// or with the widget not installed at all.
Panel {
  id: widget
  moduleName: "rogertobler.tun0-vpn"
  ipcTarget: "rogertobler.tun0-vpn"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool showName: setting("showName", true) === true
  readonly property bool highlightConnected: setting("highlightConnected", true) === true
  readonly property bool showRateInBar: setting("showRateInBar", false) === true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)

  // A list row without a switch. The panel has exactly one switch that matters - the one in the hero -
  // and two settings switches; everything else is a choice (profiles: one is active) or a mark (Wi-Fi:
  // trusted or not, kill switch: what it is doing). Rows carry a glyph or a word on the right instead,
  // the way Omarchy's own Wi-Fi list does, so the master switch is the first thing the eye lands on.
  component ListRow: BorderSurface {
    id: row
    property string label: ""
    property string description: ""
    property string trailing: ""
    property color trailingColor: widget.dim
    property bool current: false
    property bool hasCursor: false
    signal clicked()
    signal hovered(bool isHovered)

    implicitHeight: Math.max(46, rowContent.implicitHeight + Style.space(16))
    radius: Style.cornerRadius
    readonly property bool _hot: hasCursor || rowMouse.containsMouse
    borderSpec: Border.controlSpec(_hot ? "hover-cursor" : "normal", widget.foreground, widget.accent)
    // Quiet at rest: only the border. The fill is reserved for the active entry and the row under the cursor.
    color: current ? widget.selectedFill : (_hot ? widget.hoverFill : "transparent")
    Behavior on color { ColorAnimation { duration: 100 } }

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: row.borderLeft + Style.spacing.rowPaddingX
      anchors.rightMargin: row.borderRight + Style.spacing.rowPaddingX
      spacing: Style.spacing.rowPaddingX

      Column {
        width: parent.width - trailingText.width - parent.spacing
        spacing: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        Text {
          textFormat: Text.PlainText
          text: row.label
          color: widget.foreground
          font.family: widget.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          visible: row.description !== ""
          text: row.description
          color: widget.dim
          font.family: widget.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }
      Text {
        id: trailingText
        textFormat: Text.PlainText
        text: row.trailing
        color: row.trailingColor
        font.family: widget.fontFamily
        // Glyphs read better a size up from the body text.
        font.pixelSize: Style.font.heading
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: row.clicked()
    }
    HoverHandler { onHoveredChanged: row.hovered(hovered) }
  }

  // ---- the bar face ---------------------------------------------------------------------------
  // Red means the tunnel is down while it is wanted, or its state cannot be read. Connected gets the accent
  // (optional), everything else the plain foreground - dimmed while nothing is going on.
  readonly property string barGlyph: Model.glyphFor(vpn.vpnState)
  readonly property string barText: {
    var name = vpn.vpnState === "off" ? "" : (vpn.want || vpn.active)
    var t = barGlyph
    if (showName && name) t += " " + name + (vpn.vpnState === "connecting" ? "…" : "")
    if (showRateInBar && vpn.up) t += "  ↓" + Model.fmtRate(vpn.rxRate)
    return t
  }
  readonly property color barColor: (vpn.vpnState === "down" || vpn.vpnState === "stalled" || vpn.vpnState === "unknown") ? urgent
                                  : (vpn.up && highlightConnected ? accent : barForeground)
  readonly property bool pulsing: vpn.vpnState === "connecting" || vpn.vpnState === "down" || vpn.vpnState === "stalled"
  // The bar underlines an open module with a mark 55 % of the slot wide by default; with a glyph plus a
  // name that left the shield out. Same hint the clock widget gives: underline the painted label.
  readonly property real openPanelIndicatorWidth: button.labelWidth

  // ---- keyboard cursor over a flat list of rows -------------------------------------------------
  property bool cursorActive: false
  property int cursorIndex: 0
  // "/" turns the section header into a search box; esc leaves it, a second esc closes the panel.
  property bool filtering: false
  property string filterText: ""
  // At rest: the network you are on, every trusted one, the last three you used. "Show all" opens the whole
  // list right here (the panel scrolls); the TUI stays a CLI thing.
  property bool showAllWifi: false
  readonly property var wifiRows: Model.wifiRows(vpn.knownWifi, vpn.trustedList, vpn.ssid, filtering ? filterText : "", 3, showAllWifi)
  readonly property bool wifiHidden: !filtering && !showAllWifi && vpn.knownWifi.length > wifiRows.length
  // The search is a real TextField: while it has focus the key catcher is blocked, so backspace, delete, space
  // and letters like j/k/x reach the field instead of the panel. Esc hands focus back with the filter kept;
  // Esc again clears it; a third Esc closes the panel.
  function startFilter() { filtering = true; Qt.callLater(function() { if (searchField) searchField.forceActiveFocus() }) }
  function stopFilter() { filtering = false; filterText = ""; if (keyCatcher) keyCatcher.forceActiveFocus() }
  readonly property var rows: buildRows()
  readonly property string cursorRowId: cursorActive && rows.length > 0 ? rows[Math.min(cursorIndex, rows.length - 1)].id : ""

  function buildRows() {
    var out = [{ id: "hero", kind: "hero" }]
    for (var i = 0; i < vpn.profiles.length; i++) out.push({ id: "profile:" + vpn.profiles[i].name, kind: "profile", name: vpn.profiles[i].name, active: vpn.profiles[i].active === true })
    out.push({ id: "killswitch", kind: "killswitch" })
    out.push({ id: "autoconnect", kind: "autoconnect" })
    out.push({ id: "autodisconnect", kind: "autodisconnect" })
    for (var j = 0; j < wifiRows.length; j++) out.push({ id: "wifi:" + wifiRows[j], kind: "wifi", name: wifiRows[j], trusted: vpn.trustedList.indexOf(wifiRows[j]) !== -1 })
    if (wifiHidden || showAllWifi) out.push({ id: "manage", kind: "manage" })
    return out
  }

  function setCursor(rowId) {
    for (var i = 0; i < rows.length; i++) if (rows[i].id === rowId) { cursorIndex = i; cursorActive = true; return }
  }

  function moveCursor(dy) {
    if (rows.length === 0) return
    if (!cursorActive) { cursorActive = true; cursorIndex = Math.min(cursorIndex, rows.length - 1); return }
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + dy))
  }

  function activateCursor() {
    if (!cursorActive || rows.length === 0) return
    var row = rows[Math.min(cursorIndex, rows.length - 1)]
    switch (row.kind) {
      case "hero": vpn.toggleTunnel(); break
      case "profile": row.active ? vpn.disconnect() : vpn.connectTo(row.name); break
      case "manage": widget.showAllWifi = !widget.showAllWifi; break
      case "autoconnect": vpn.setAutoconnect(!vpn.autoconnect); break
      case "autodisconnect": vpn.setAutodisconnect(!vpn.autodisconnect); break
      case "killswitch": vpn.setKillswitch(vpn.killswitch === "disabled"); break
      case "wifi": vpn.setTrusted(row.name, !row.trusted); break
    }
  }

  // Keep the row under the cursor on screen; a no-op while it already is.
  function reveal(item) {
    if (!item || !panelFlick.visible) return
    var y = item.mapToItem(column, 0, 0).y, h = item.height, pad = Style.space(8)
    if (y < panelFlick.contentY) panelFlick.contentY = Math.max(0, y - pad)
    else if (y + h > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height, y + h - panelFlick.height + pad))
  }

  function cursorProfileName() {
    if (!cursorActive || rows.length === 0) return ""
    var row = rows[Math.min(cursorIndex, rows.length - 1)]
    return row.kind === "profile" ? row.name : ""
  }

  onOpenedChanged: {
    if (opened) {
      panelAnchor.freeze()
      cursorActive = false
      stopFilter()
      showAllWifi = false
      vpn.notice = ""
      vpn.refresh()
      vpn.refreshPublic()   // the route out can change while the panel is shut, with no tunnel involved
    }
  }

  Service {
    id: vpn
    settings: widget.settings
    opened: widget.opened
  }

  IpcHandler {
    target: "rogertobler.tun0-vpn"
    function open(): void { widget.open() }
    function close(): void { widget.close() }
    function toggle(): void { widget.toggle() }
    function refresh(): void { vpn.refresh() }
    function up(name: string): void { name ? vpn.connectTo(name) : vpn.toggleTunnel() }
    function down(): void { vpn.disconnect() }
    function status(): string { return vpn.vpnState + (vpn.active ? " " + vpn.active : "") }
  }

  // ---- bar face -------------------------------------------------------------------------------
  Item {
    id: face
    anchors.fill: parent

    WidgetButton {
      id: button
      anchors.fill: parent
      bar: widget.bar
      text: widget.barText
      foreground: widget.barColor
      useActiveColor: false
      keepSpace: true
      dimmed: vpn.vpnState === "off" && !widget.opened
      tooltipText: Model.barTooltip(vpn.view, { rx: vpn.rxRate, tx: vpn.txRate })
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) vpn.toggleTunnel()
        else if (buttonCode === Qt.MiddleButton) vpn.refresh()
        else widget.toggle()
      }
    }

    // The bar label changes width with the state (bare shield -> "shield proton-ch..." -> "shield proton-ch"),
    // and KeyboardPanel centres the card on its anchor. In a right-aligned bar the button grows to the
    // left, so the open panel slid sideways on every switch (freezing only the width made it worse - the
    // anchor's x still moved). The panel anchors to this proxy instead: while
    // the panel is open it holds the screen position the button had at the moment of opening, whatever
    // the button does meanwhile. It re-centres on the next open.
    Item {
      id: panelAnchor
      anchors.top: parent.top
      height: parent.height
      property real frozenWidth: 0
      property real frozenLeft: 0                 // bar-window coordinates
      readonly property bool frozen: widget.opened && frozenWidth > 0
      readonly property var win: face.QsWindow.window
      TransformWatcher { id: faceWatcher; a: panelAnchor.win ? panelAnchor.win.contentItem : null; b: face }
      width: frozen ? frozenWidth : button.width
      x: {
        if (!frozen || !win) return 0
        faceWatcher.transform                     // reactive dependency, mapToItem alone is one-shot
        return frozenLeft - face.mapToItem(win.contentItem, 0, 0).x
      }
      function freeze() {
        frozenWidth = button.width
        frozenLeft = win ? button.mapToItem(win.contentItem, 0, 0).x : 0
      }
    }

    // The one thing a command module could never do: breathe while something is in flight.
    SequentialAnimation on opacity {
      running: widget.pulsing
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 650; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
      onRunningChanged: if (!running) face.opacity = 1.0
    }
  }

  // ---- panel ----------------------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: panelAnchor
    owner: widget
    bar: widget.bar
    open: widget.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(920))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      blocked: searchField.activeFocus

      onMoveRequested: function(dx, dy) { if (dy !== 0 || !widget.cursorActive) widget.moveCursor(dy) }
      onActivateRequested: widget.activateCursor()
      onCloseRequested: widget.filtering ? widget.stopFilter() : widget.close()
      onDeleteRequested: { vpn.openWizard("remove"); widget.close() }   // the catcher turns x into this
      onTabRequested: function(direction) { widget.switchPanel(direction) }
      onTextKey: function(t) {
        switch (t.toLowerCase()) {
          case "/": widget.startFilter(); break
          case "w": widget.showAllWifi = !widget.showAllWifi; break
          case "t": vpn.toggleTunnel(); break
          case "r": vpn.refresh(); vpn.refreshPublic(); break
          case "s": vpn.setKillswitch(vpn.killswitch === "disabled"); break
          case "n": vpn.trustToggle(); break
          case "a": vpn.openWizard("add"); widget.close(); break
          case "i": vpn.openWizard("status"); widget.close(); break
          case "c": vpn.copyPublicIp(); break
          case "d": vpn.setDefault(widget.cursorProfileName()); break
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // -- hero: state, profile, where you come out, the master switch ----------------------
          Item {
            id: header
            width: parent.width
            height: hero.implicitHeight
            readonly property bool ringVisible: widget.cursorRowId === "hero"
            function focusHero() { widget.setCursor("hero") }

            PanelHero {
              id: hero
              width: parent.width
              title: Model.stateTitle(vpn.vpnState, vpn.busyLabel)
              meta: Model.heroMeta(vpn.view)
              foreground: widget.foreground
              fontFamily: widget.fontFamily
              iconOpacity: vpn.wanted ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: widget.barGlyph
                  color: (vpn.vpnState === "down" || vpn.stalled || vpn.vpnState === "unknown") ? widget.urgent : (vpn.up ? widget.accent : widget.foreground)
                  font.family: widget.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  visible: vpn.profiles.length > 0
                  checked: vpn.wanted
                  busy: vpn.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  accent: widget.accent
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: vpn.toggleTunnel()
                }
              }
            }
          }

          // Where the internet sees you - the only real proof the tunnel is doing anything.
          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: Model.publicLine(vpn.publicInfo, vpn.publicLoading)
            color: widget.dim
            font.family: widget.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: vpn.errorText !== "" || vpn.notice !== ""
            width: parent.width
            text: vpn.errorText !== "" ? vpn.errorText : vpn.notice
            color: vpn.errorText !== "" ? widget.urgent : widget.dim
            font.family: widget.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // -- throughput: the proof the tunnel is doing something -------------------------------
          Item {
            visible: vpn.up || vpn.stalled
            width: parent.width
            height: visible ? statsColumn.implicitHeight : 0

            Column {
              id: statsColumn
              width: parent.width
              spacing: Style.space(4)

              RowLayout {
                width: parent.width
                spacing: Style.space(10)
                Text { textFormat: Text.PlainText; text: "↓ " + Model.fmtRate(vpn.rxRate); color: widget.foreground; font.family: widget.fontFamily; font.pixelSize: Style.font.body }
                Text { textFormat: Text.PlainText; text: "↑ " + Model.fmtRate(vpn.txRate); color: widget.foreground; font.family: widget.fontFamily; font.pixelSize: Style.font.body }
                Item { Layout.fillWidth: true }
                Text { textFormat: Text.PlainText; text: "session " + Model.fmtBytes(vpn.sessionRx + vpn.sessionTx); color: widget.dim; font.family: widget.fontFamily; font.pixelSize: Style.font.caption }
              }

              // Sixty seconds of rates: download in the accent, upload laid over it in the dim tone.
              Item {
                id: spark
                width: parent.width
                height: Style.space(26)
                readonly property int slots: 60
                readonly property real step: width / slots
                readonly property var rxBars: Model.sparkHeights(vpn.rxHistory, height)
                readonly property var txBars: Model.sparkHeights(vpn.txHistory, height)
                readonly property int offset: slots - rxBars.length

                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: widget.dim; opacity: 0.4 }
                Repeater {
                  model: spark.rxBars.length
                  Rectangle {
                    required property int index
                    x: (spark.offset + index) * spark.step
                    width: Math.max(1, spark.step - 1)
                    height: spark.rxBars[index]
                    anchors.bottom: parent.bottom
                    color: widget.accent
                    opacity: 0.85
                  }
                }
                Repeater {
                  model: spark.txBars.length
                  Rectangle {
                    required property int index
                    x: (spark.offset + index) * spark.step
                    width: Math.max(1, spark.step - 1)
                    height: spark.txBars[index]
                    anchors.bottom: parent.bottom
                    color: widget.foreground
                    opacity: 0.35
                  }
                }
              }
            }
          }

          PanelSeparator { foreground: widget.foreground }

          // -- profiles --------------------------------------------------------------------------
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            PanelSectionHeader { Layout.fillWidth: true; text: "PROFILES"; foreground: widget.foreground; fontFamily: widget.fontFamily }
            PanelActionButton { iconText: "\u{F0415}"; tooltipText: "Add VPN… (a)"; foreground: widget.foreground; fontFamily: widget.fontFamily; Layout.alignment: Qt.AlignVCenter; onClicked: { vpn.openWizard("add"); widget.close() } }
            PanelActionButton { iconText: "\u{F01B4}"; tooltipText: "Remove a profile (x)"; foreground: widget.foreground; fontFamily: widget.fontFamily; enabled: vpn.profiles.length > 0; Layout.alignment: Qt.AlignVCenter; onClicked: { vpn.openWizard("remove"); widget.close() } }
            PanelActionButton { iconText: "\u{F02FC}"; tooltipText: "Full status in a terminal (i)"; foreground: widget.foreground; fontFamily: widget.fontFamily; Layout.alignment: Qt.AlignVCenter; onClicked: { vpn.openWizard("status"); widget.close() } }
            PanelActionButton { iconText: "\u{F0450}"; tooltipText: "Refresh (r)"; foreground: widget.foreground; fontFamily: widget.fontFamily; Layout.alignment: Qt.AlignVCenter; onClicked: { vpn.refresh(); vpn.refreshPublic() } }
          }

          Text {
            textFormat: Text.PlainText
            visible: vpn.profiles.length === 0
            width: parent.width
            text: vpn.loading ? "Checking…" : vpn.failed ? "Profiles unknown while the state cannot be read." : "No profile yet. Add one with the + above: a file, the clipboard, or a path."
            color: widget.dim
            font.family: widget.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            id: profileColumn
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: vpn.profiles
              ListRow {
                required property var modelData
                readonly property string rowId: "profile:" + modelData.name
                readonly property bool isActive: modelData.active === true
                readonly property bool isPending: vpn.vpnState === "connecting" && vpn.want === modelData.name
                width: profileColumn.width
                label: modelData.label
                description: Model.profileDescription(modelData)
                trailing: isActive ? "\u{F012C}" : (isPending ? "…" : "")
                trailingColor: isActive ? widget.accent : widget.foreground
                current: isActive
                hasCursor: widget.cursorRowId === rowId
                enabled: !vpn.busy && !vpn.failed
                onHovered: function(on) { if (on) widget.setCursor(rowId) }
                onHasCursorChanged: if (hasCursor) widget.reveal(this)
                onClicked: isActive ? vpn.disconnect() : vpn.connectTo(modelData.name)
              }
            }
          }

          PanelSeparator { foreground: widget.foreground }

          // -- kill switch -----------------------------------------------------------------------
          PanelSectionHeader { width: parent.width; text: "KILL SWITCH"; foreground: widget.foreground; fontFamily: widget.fontFamily }

          ListRow {
            width: parent.width
            label: "Block everything outside the tunnel"
            description: Model.killswitchDescription(vpn.view)
            // One wall glyph: green while the switch is enabled (ready, armed, on, holding), red once you disabled it.
            trailing: "\u{F0587}"
            trailingColor: vpn.killswitch === "disabled" || vpn.killswitch === "unloaded" || vpn.killswitch === "unknown" ? widget.urgent : widget.accent   // unloaded = setting on, no table: red, not a green promise
            // Filled while enabled, like every other row that is "on".
            current: vpn.killswitch !== "disabled" && vpn.killswitch !== "unknown"
            hasCursor: widget.cursorRowId === "killswitch"
            enabled: !vpn.busy && !vpn.failed
            onHovered: function(on) { if (on) widget.setCursor("killswitch") }
            onHasCursorChanged: if (hasCursor) widget.reveal(this)
            onClicked: vpn.setKillswitch(vpn.killswitch === "disabled")
          }

          PanelSeparator { foreground: widget.foreground }

          // -- trusted Wi-Fi: the two automation rows, then the networks. Rows with a glyph, not switches: the
          // master switch at the top is the only switch in the panel, every other on/off is a row that fills
          // and colours its glyph when on (glyphs: lightbulb-on/-outline, shield-home). -----------
          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            PanelSectionHeader { visible: !widget.filtering; Layout.fillWidth: true; text: "TRUSTED WI-FI"; foreground: widget.foreground; fontFamily: widget.fontFamily }
            TextField {
              id: searchField
              visible: widget.filtering
              Layout.fillWidth: true
              placeholderText: "Search networks"
              font.family: widget.fontFamily
              font.pixelSize: Style.font.body
              foreground: widget.foreground
              accent: widget.accent
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              text: widget.filterText
              onTextChanged: if (text !== widget.filterText) widget.filterText = text
              onAccepted: keyCatcher.forceActiveFocus()
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              onVisibleChanged: if (!visible) text = ""
            }
            PanelActionButton { iconText: "\u{F0349}"; tooltipText: "Search networks (/)"; foreground: widget.foreground; fontFamily: widget.fontFamily; Layout.alignment: Qt.AlignVCenter; onClicked: widget.startFilter() }
            PanelActionButton { visible: widget.wifiHidden || widget.showAllWifi; iconText: widget.showAllWifi ? "\u{F0143}" : "\u{F0140}"; tooltipText: widget.showAllWifi ? "Show fewer (w)" : "Show all networks (w)"; foreground: widget.foreground; fontFamily: widget.fontFamily; Layout.alignment: Qt.AlignVCenter; onClicked: widget.showAllWifi = !widget.showAllWifi }
          }

          Column {
            id: networkColumn
            width: parent.width
            spacing: Style.space(4)

            ListRow {
              width: networkColumn.width
              label: "Auto-connect on untrusted Wi-Fi"
              description: "a network you have not trusted is shut before its first packet, then the default profile comes up through it"
              // A light bulb, lit while on and an outline while off.
              trailing: vpn.autoconnect ? "\u{F06E8}" : "\u{F0336}"
              trailingColor: vpn.autoconnect ? widget.accent : widget.dim
              current: vpn.autoconnect
              hasCursor: widget.cursorRowId === "autoconnect"
              enabled: !vpn.busy && !vpn.failed
              onHovered: function(on) { if (on) widget.setCursor("autoconnect") }
              onHasCursorChanged: if (hasCursor) widget.reveal(this)
              onClicked: vpn.setAutoconnect(!vpn.autoconnect)
            }
            ListRow {
              width: networkColumn.width
              label: "Auto-disconnect on trusted Wi-Fi"
              description: "back on your own network the tunnel drops and the kill switch is released"
              trailing: "\u{F068A}"
              trailingColor: vpn.autodisconnect ? widget.accent : widget.dim
              current: vpn.autodisconnect
              hasCursor: widget.cursorRowId === "autodisconnect"
              enabled: !vpn.busy && !vpn.failed
              onHovered: function(on) { if (on) widget.setCursor("autodisconnect") }
              onHasCursorChanged: if (hasCursor) widget.reveal(this)
              onClicked: vpn.setAutodisconnect(!vpn.autodisconnect)
            }

            Repeater {
              model: widget.wifiRows
              ListRow {
                required property var modelData
                readonly property string ssid: String(modelData)
                readonly property string rowId: "wifi:" + ssid
                readonly property bool isTrusted: vpn.trustedList.indexOf(ssid) !== -1
                width: networkColumn.width
                label: "\u{F05A9} " + ssid
                description: (isTrusted ? "trusted" : "untrusted") + (ssid === vpn.ssid ? " · you are here" : "")
                trailing: "\u{F0498}"
                trailingColor: isTrusted ? widget.accent : widget.dim
                // Same rule as the kill switch row: a trusted network is "on", so its row is filled.
                current: isTrusted
                hasCursor: widget.cursorRowId === rowId
                enabled: !vpn.busy && !vpn.failed
                onHovered: function(on) { if (on) widget.setCursor(rowId) }
                onHasCursorChanged: if (hasCursor) widget.reveal(this)
                onClicked: vpn.setTrusted(ssid, !isTrusted)
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: vpn.knownWifi.length === 0 || (widget.filtering && widget.wifiRows.length === 0)
              width: parent.width
              text: vpn.failed ? "Networks unknown while the state cannot be read." : vpn.knownWifi.length === 0 ? "No saved Wi-Fi networks yet." : "Nothing matches \"" + widget.filterText + "\"."
              color: widget.dim
              font.family: widget.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              visible: widget.wifiHidden || widget.showAllWifi
              width: networkColumn.width
              text: widget.showAllWifi ? "Show fewer  (w)" : "Show all " + vpn.knownWifi.length + " networks  (w)"
              iconText: widget.showAllWifi ? "\u{F0143}" : "\u{F0140}"
              leftAlign: true
              hasCursor: widget.cursorRowId === "manage"
              foreground: widget.foreground
              accent: widget.accent
              fontFamily: widget.fontFamily
              onHovered: function(on) { if (on) widget.setCursor("manage") }
              onHasCursorChanged: if (hasCursor) widget.reveal(this)
              onClicked: widget.showAllWifi = !widget.showAllWifi
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            // The one place that lists the keys. The rows used to repeat their own ("s toggles", "d makes it the
            // default", "c copies the IP"); space or Enter flips whatever the cursor is on, so the per-row hints
            // only added noise.
            text: "j/k move · space/enter flips the row · t tunnel · s kill switch · d default · n trust this Wi-Fi · / search · w all networks · a add · x remove · i status · c copy IP · r refresh · esc"
            color: widget.dim
            font.family: widget.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
