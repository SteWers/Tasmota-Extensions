###################################################################################
# zigbee_toggle.be - ESP32 Extension for Tasmota
#
# SPDX-FileCopyrightText: 2026 tasict
#
# SPDX-License-Identifier: GPL-3.0-only
###################################################################################
# Adds a Toggle button for every Zigbee OnOff endpoint in the main page device
# list, using the core `web_device_status` Berry hook. No extra page, no polling:
# the button calls the main page AJAX refresh (`la()`) with a `zbt`/`zbe`
# argument, which is handled in `web_sensor()` and sends `ZbSend ... Power toggle`.
#
# Multi-endpoint devices: the core only prints the On/Off state of the first
# OnOff endpoint, so the extra endpoints get their own line with state and
# button. Buttons are labelled with the endpoint names set by `ZbName`.
###################################################################################
# rm Zigbee_Toggle.tapp; zip -j -0 Zigbee_Toggle.tapp Zigbee_Toggle/*
###################################################################################

import webserver
import string
import json

class zigbee_toggle
  var sw       # shortaddr -> [ [endpoints in core data order], {ep(str): name} ]
  var by_ep    # Power key suffix rule: by endpoint number since #24948 (15.6+), by insertion order before

  def init()
    self.sw = {}
    self.by_ep = tasmota.version() >= 0x0F060000
    zigbee.add_handler(self)
    tasmota.add_driver(self)
  end

  def unload()
    zigbee.remove_handler(self)
    tasmota.remove_driver(self)
  end

  # `Config` and `Names` from info() are raw JSON strings (core setStrRaw), decode again
  static def j(v)
    return type(v) == 'string' ? json.load(v) : v
  end

  static def btn(sa, ep, label, overlay)
    # overlay: zero-height row + negative margin, puts the button on the On/Off line already printed by the core
    return format("<button style='float:right;position:relative;width:auto;line-height:1.4rem;font-size:0.9rem;padding:0 10px;margin-left:4px%s' onclick='la(\"&zbt=%d&zbe=%d\");'>%s</button>",
                  overlay ? ";margin-top:-1.3rem" : "", sa, ep, label)
  end

  # called by ZigbeeShow() after each device (zigbee.dispatch)
  def web_device_status(ev, frame, attrs, sa)
    var d = zigbee.find(sa)
    if d == nil return end
    var m
    var e = self.sw.find(sa)
    if e == nil
      m = json.load(str(d.info()))
      var eps = []
      for c: self.j(m.find('Config', '[]'))   # "O01" = OnOff cluster on endpoint 0x01, same order as core data
        if c[0] == 'O' eps.push(int('0x' + c[1..2])) end
      end
      # only cache devices with OnOff; others are re-checked so a newly paired switch shows up once it reports
      if size(eps) == 0 return end
      e = [eps, self.j(m.find('Names', '{}'))]
      self.sw[sa] = e
    end
    var eps = e[0]
    var names = e[1]
    var multi = size(eps) > 1

    # first OnOff endpoint: the core already printed the On/Off line, overlay the button
    webserver.content_send(format("<tr><td colspan='4' style='padding:0;line-height:0'>%s</td></tr>",
      self.btn(sa, eps[0], names.find(str(eps[0]), multi ? 'Toggle ' .. str(eps[0]) : 'Toggle'), true)))

    # other endpoints: not printed by the core, add a line with state + button
    if multi
      if m == nil m = json.load(str(d.info())) end
      for i: 1..size(eps)-1
        var ep = eps[i]
        var key = 'Power' .. str(self.by_ep ? ep : i + 1)
        var p = m.find(key)
        webserver.content_send(format("<tr class='htr'><td colspan='4'>&#9478; %s%s</td></tr>",
          p == nil ? '?' : (p ? 'On' : 'Off'), self.btn(sa, ep, names.find(str(ep), 'Toggle ' .. str(ep)), false)))
      end
    end
  end

  # main page AJAX refresh (la()) with zbt/zbe -> send toggle
  def web_sensor()
    if webserver.has_arg('zbt')
      var sa = int(webserver.arg('zbt'))
      var ep = int(webserver.arg('zbe'))
      var e = self.sw.find(sa)
      if e != nil && e[0].find(ep) != nil   # only devices/endpoints we rendered a button for
        tasmota.cmd(format('ZbSend {"device":"0x%04X","endpoint":%d,"send":{"Power":"toggle"}}', sa, ep), true)
      end
    end
  end
end

return zigbee_toggle()
