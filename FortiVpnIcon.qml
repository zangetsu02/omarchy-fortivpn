import QtQuick
import qs.Commons

Item {
  id: root

  property real iconSize: 16
  property color color: Color.foreground
  // A filled shield reads as "protected" at a glance; the outline reads as
  // "available but not protecting you", which is exactly the down state.
  property bool filled: false
  property bool crossed: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: shield.requestPaint()
  onFilledChanged: shield.requestPaint()
  onIconSizeChanged: shield.requestPaint()

  Canvas {
    id: shield
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      var w = width
      var h = height
      ctx.reset()
      ctx.clearRect(0, 0, w, h)

      // Unit-square shield scaled to the slot, so it stays centred and crisp
      // whatever bar height the theme picks.
      var lw = Math.max(1, w * 0.11)
      var inset = lw / 2 + w * 0.04
      var left = inset
      var right = w - inset
      var top = inset
      var bottom = h - inset
      var midX = w / 2
      // Where the straight sides give way to the taper toward the point.
      var shoulder = top + (bottom - top) * 0.46

      ctx.beginPath()
      ctx.moveTo(midX, top)
      ctx.lineTo(right, top + (bottom - top) * 0.14)
      ctx.lineTo(right, shoulder)
      ctx.quadraticCurveTo(right, bottom - (bottom - top) * 0.16, midX, bottom)
      ctx.quadraticCurveTo(left, bottom - (bottom - top) * 0.16, left, shoulder)
      ctx.lineTo(left, top + (bottom - top) * 0.14)
      ctx.closePath()

      if (root.filled) {
        ctx.fillStyle = root.color
        ctx.fill()
      } else {
        ctx.strokeStyle = root.color
        ctx.lineWidth = lw
        ctx.lineJoin = "round"
        ctx.stroke()
      }
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.24
    height: Math.max(2, parent.height * 0.13)
    radius: height / 2
    color: root.color
    rotation: -45
  }
}
