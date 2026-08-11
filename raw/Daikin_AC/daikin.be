#-
  Daikin AC extension for Tasmota
  ================================
  Talks to Daikin's local WiFi adapter API (BRP069/BRP072-style units):
    - UDP broadcast discovery on port 30050 (adapter listens there,
      replies come back to whatever local port we bound)
    - HTTP GET on the adapter's own web server for status
      (aircon/get_model_info, get_sensor_info, get_control_info)
    - HTTP GET on aircon/set_control_info to change power/mode/
      setpoint/fan (Daikin's API expects the FULL control block to be
      resent on every write, not just the changed fields)

  Known limitations / assumptions (documented rather than hidden):
    - Broadcast discovery assumes a /24 LAN (guesses "<a>.<b>.<c>.255"
      from this device's own IP). Override by editing
      daikin_guess_broadcast_ip() if your network differs.
    - mode / fan-rate codes below are the commonly documented values
      for this API family; a few Daikin models deviate. Cross-check
      with `DaikinStatus` before relying on them for your unit.
    - HTTP calls are synchronous (blocking), matching how Tasmota's
      webclient is normally used in Berry drivers. Fine for a handful
      of devices polled once a minute; don't scale this to dozens
      of units without adding real async handling.
-#

def daikin_guess_broadcast_ip()
    import string
    var w = tasmota.wifi()
    if w == nil return "192.168.1.255" end
    var ip = w.find('ip', nil)
    if ip == nil || ip == "0.0.0.0"
        return "192.168.1.255"   # fallback, override if your LAN isn't a /24
    end
    var parts = string.split(ip, ".")
    if size(parts) != 4
        return "192.168.1.255"
    end
    return parts[0] + "." + parts[1] + "." + parts[2] + ".255"
end

class DAIKIN_PARSER
    # Decodes Daikin's "key1=val1,key2=val2,..." wire format used by
    # both the UDP discovery reply and every /aircon/get_* endpoint.

    static def urldecode(s)
        var out = bytes()
        var i = 0
        while i < size(s)
            var c = s[i]
            if c == "%" && i + 2 < size(s)
                out += bytes().fromhex(s[i+1..i+2])
                i += 3
            elif c == "+"
                out += bytes().fromstring(" ")
                i += 1
            else
                out += bytes().fromstring(c)
                i += 1
            end
        end
        return out.asstring()
    end

    static def to_list(buf)
        import string
        var result = {}
        var msg = buf
        if classof(buf) == bytes
            msg = buf.asstring()
        end
        msg = string.split(msg, ",")
        for e : msg
            var el = string.split(e, "=")
            if size(el) < 2 || el[1] == ""
                continue
            elif el[0] == "ssid1"          # ignore, not useful to us
                continue
            elif el[0] == "name"
                el[1] = DAIKIN_PARSER.urldecode(el[1])
            elif el[0] == "ret" && el[1] == "OK"
                continue
            elif el[0] == "ret" && el[1] != "OK"
                log(f"DAIKIN_PARSER: Error parsing message: {e}", 1)
                return nil
            end
            result[el[0]] = el[1]
        end
        return result
    end
end

class DAIKIN_DISCOVERY
    static broadcast_port = 30050
    static listen_port = 30000
    static scan_duration_ms = 5000   # how long we listen for replies after broadcasting

    var u, devices, completion, deadline, broadcast_ip

    def init(completion, broadcast_ip)
        self.completion = completion
        self.broadcast_ip = broadcast_ip != nil ? broadcast_ip : "192.168.1.255"
        self.u = udp()
        if !self.u.begin("", self.listen_port)
            log("DAIKIN_DISCOVERY: Failed to open UDP socket", 1)
            self.completion([])
            return
        end
        self.devices = []
        self.deadline = tasmota.millis() + self.scan_duration_ms
        log(f"DAIKIN_DISCOVERY: broadcasting to {self.broadcast_ip}:{self.broadcast_port}", 2)
        self.u.send(self.broadcast_ip, self.broadcast_port, bytes().fromstring("DAIKIN_UDP/common/basic_info"))
        tasmota.add_driver(self)
    end

    def parse(buf, ip, port)
        var device = DAIKIN_PARSER.to_list(buf)
        if device == nil
            return
        end
        device['ip'] = ip
        for d : self.devices
            if d['ip'] == ip
                return   # already have this device from this scan
            end
        end
        log(f"DAIKIN_DISCOVERY: Found device at {ip}:{port}", 2)
        log(f"DAIKIN_DISCOVERY: Parsed device info: {device}", 3)
        self.devices.push(device)
    end

    def every_50ms()
        var buf = self.u.read()
        if buf != nil
            log(f"DAIKIN_DISCOVERY: Received UDP packet: {buf}", 3)
            self.parse(buf, self.u.remote_ip, self.u.remote_port)
        end
        if tasmota.millis() > self.deadline
            self.stop()
        end
    end

    def stop()
        tasmota.remove_driver(self)
        self.u.close()
        log(f"DAIKIN_DISCOVERY: finished, devices found: {self.devices}", 4)
        self.completion(self.devices)
    end
end

class DAIKIN_CONFIG
    var devices, discovery, finished, cb, broadcast_ip, http_get

    # `http_get` is injected from DAIKIN.start() as a closure over its
    # instance `read()` method - this lets us do a liveness check here
    # without DAIKIN_CONFIG needing a back-reference to the DAIKIN class
    # (and without relying on forward-referencing a class that's defined
    # later in this same file).
    def init(cb, broadcast_ip, http_get)
        self.cb = cb
        self.broadcast_ip = broadcast_ip
        self.http_get = http_get
        self.load_or_discover()
    end

    def load_or_discover()
        import persist
        if persist.has("daikin_devices")
            var cached = self.load_from_persist()
            if cached != nil && size(cached) > 0
                log(f"DAIKIN_CONFIG: Loaded {size(cached)} device(s) from persist, checking reachability", 1)
                if self.verify_devices(cached)
                    log("DAIKIN_CONFIG: All persisted devices reachable, skipping discovery", 1)
                    self.devices = cached
                    self.finished = true
                    # Deferred: cb() calls DAIKIN.completion() which accesses
                    # self.cfg.devices - but self.cfg is only assigned AFTER
                    # this constructor returns (self.cfg = DAIKIN_CONFIG(...)).
                    # Calling cb() synchronously here means self.cfg is still
                    # nil → null-reference crash → constructor exception →
                    # assignment never happens → permanently stuck.
                    tasmota.set_timer(0, self.cb)
                    return
                end
                log("DAIKIN_CONFIG: One or more persisted devices unreachable, falling back to discovery", 1)
                # Keep the cached list as a merge base (see completion())
                # rather than discarding it - UDP broadcast can legitimately
                # miss a reply from a device that's actually fine, and with
                # more devices there are more chances for that to happen on
                # any given scan. We don't want one flaky device to also
                # cost us the last-known-good data for every other device.
                self.devices = cached
            end
        else
            log("DAIKIN_CONFIG: No persisted devices, starting discovery", 1)
        end
        self.rescan()
    end

    def load_from_persist()
        import persist
        import json
        var parsed = json.load(persist.daikin_devices)   # json.load() returns nil on bad input, doesn't raise
        if parsed == nil
            log("DAIKIN_CONFIG: Persisted device data was unreadable, discarding", 1)
        end
        return parsed
    end

    # Cheap identity/liveness probe against Daikin's lightweight
    # common/basic_info endpoint (same family as the UDP discovery
    # reply). We also cross-check the MAC so a DHCP lease that handed
    # our old IP to some other device doesn't get treated as a match.
    # Checks every device rather than stopping at the first failure, so
    # the log actually says which of several devices has a problem.
    def verify_devices(devices)
        var all_ok = true
        for d : devices
            tasmota.yield()
            var info = self.http_get(d["ip"], "common/basic_info")
            if info == nil
                log(f"DAIKIN_CONFIG: {d.find('name', '?')} at {d['ip']} did not respond", 2)
                all_ok = false
            elif d.find("mac") != nil && info.find("mac") != nil && info["mac"] != d["mac"]
                log(f"DAIKIN_CONFIG: {d.find('name', '?')} at {d['ip']} answered but MAC changed", 1)
                all_ok = false
            end
        end
        return all_ok
    end

    def rescan()
        self.finished = false
        self.discovery = DAIKIN_DISCOVERY(/devices -> self.completion(devices), self.broadcast_ip)
    end

    # Merges a freshly-discovered device list into whatever we already
    # know (matched by MAC), instead of wholesale-replacing it:
    #  - a known device gets its IP refreshed from the fresh scan, but
    #    otherwise keeps its entry (incl. any already-polled state)
    #  - a known device that simply didn't reply to THIS broadcast round
    #    is left in place rather than dropped - a single missed UDP
    #    reply shouldn't erase a perfectly good device, and that risk
    #    only grows with more devices on the network
    #  - a device with an unrecognized MAC is a genuinely new unit and
    #    gets appended
    # Deliberately never auto-removes a device: a truly dead/retired
    # unit just lingers (and its polls fail quietly) until dealt with
    # manually - trading a small amount of staleness for never silently
    # losing a device's saved data to a flaky scan.
    def merge_devices(existing, fresh)
        var fresh_by_mac = {}
        for f : fresh
            var mac = f.find("mac")
            if mac != nil
                fresh_by_mac[mac] = f
            end
        end
        var known_macs = {}
        var merged = []
        for d : existing
            var mac = d.find("mac")
            if mac != nil
                known_macs[mac] = true
                var match = fresh_by_mac.find(mac)
                if match != nil
                    d["ip"] = match["ip"]   # refresh in case it moved, keep the rest
                end
            end
            merged.push(d)
        end
        for f : fresh
            var mac = f.find("mac")
            if mac == nil || known_macs.find(mac) == nil
                merged.push(f)
            end
        end
        return merged
    end

    def completion(devices)
        if self.devices != nil && size(self.devices) > 0
            self.devices = self.merge_devices(self.devices, devices)
        else
            self.devices = devices
        end
        log(f"DAIKIN_CONFIG: Completed with {self.devices}", 3)
        self.discovery = nil
        if size(self.devices) == 0
            log("DAIKIN_CONFIG: No devices found, discovery failed", 1)
            self.finished = true   # must be set even on empty result so commands report "no devices" instead of "not ready"
            self.cb()
            return
        end
        self.save_to_persist(self.devices)
        self.finished = true
        self.cb()
    end

    def save_to_persist(devices)
        import persist
        import json
        persist.daikin_devices = json.dump(devices)
        persist.save()
        log("DAIKIN_CONFIG: Saved devices to persist", 1)
    end
end

class DAIKIN
    var cfg, poll_tick, matter_mgr

    static POLL_SENSOR_EVERY = 60    # seconds => refresh sensors ~every 60s
    static POLL_CONTROL_EVERY = 120  # refresh control_info ~every 120s, on the offset tick

    # Wire-code lookup tables. These are the commonly documented codes
    # for this API family - verify against `DaikinStatus` for your unit.
    static MODE_TO_CODE = {"auto": "0", "dehumidify": "2", "cool": "3", "heat": "4", "fan": "6"}
    static CODE_TO_MODE = {"0": "auto", "2": "dehumidify", "3": "cool", "4": "heat", "6": "fan"}
    static FAN_TO_CODE = {"auto": "A", "quiet": "B", "1": "3", "2": "4", "3": "5", "4": "6", "5": "7"}

    def init()
        log("DAIKIN: Initializing Daikin driver", 1)
        self.poll_tick = 0
        self.matter_mgr = nil
        tasmota.add_driver(self)
        self.add_commands()
        tasmota.when_network_up(/-> self.start())
    end

    def start()
        if self.cfg != nil
            return   # already started
        end
        log("DAIKIN: Network up, loading configuration", 2)
        self.cfg = DAIKIN_CONFIG(/-> self.completion(), daikin_guess_broadcast_ip(), /ip, path -> self.read(ip, path))
    end

    def setup_matter()
        if self.matter_mgr != nil
            return true
        end
        try
            import matter
        except .. as e, m
            log(f"DAIKIN: Matter not present: {e} {m}", 2)
            return false
        end
        import global
        if global.matter_device == nil
            log("DAIKIN: Matter bridge not initialized yet", 2)
            return false
        end
        import introspect
        try
            var res = introspect.module('.extensions/daikin_ac.tapp#daikin_matter', true)
            if res == nil || res.find("DAIKIN_MATTER", nil) == nil
                log("DAIKIN: Matter Thermostat module failed to load (check daikin_matter.be)", 1)
                return false
            end
            var DAIKIN_MATTER = res["DAIKIN_MATTER"]
            self.matter_mgr = DAIKIN_MATTER(self)
            log("DAIKIN: Matter Thermostat integration loaded", 2)
            return true
        except .. as e, m
            log(f"DAIKIN: Matter Thermostat integration failed to load: {e} {m}", 1)
            return false
        end
    end

    def unload()
        if self.cfg != nil && self.cfg.discovery != nil
            self.cfg.discovery.stop()
        end
        if self.matter_mgr != nil
            self.matter_mgr.unload()
            self.matter_mgr = nil
        end
        tasmota.remove_cmd('DaikinPower')
        tasmota.remove_cmd('DaikinMode')
        tasmota.remove_cmd('DaikinSetTemp')
        tasmota.remove_cmd('DaikinFan')
        tasmota.remove_cmd('DaikinRescan')
        tasmota.remove_cmd('DaikinStatus')
        tasmota.remove_cmd('DaikinMatter')
        tasmota.remove_driver(self)
        log("DAIKIN: Unloaded", 1)
    end

    def completion()
        self.get_model_info()
        log(f"DAIKIN: Configuration finished, devices found: {size(self.cfg.devices)}", 2)
        for d : self.cfg.devices
            log(f"DAIKIN: Device {d.find('name','?')} at {d['ip']}, Fw: {d.find('ver','?')}, MAC: {d.find('mac','?')}, Matter: {d.find('matter', 0)}", 2)
        end
        if self.setup_matter()
            self.matter_mgr.sync(self.cfg.devices)
        end
    end

    def read(ip, get_msg, timeout_ms)
        var cl = webclient()
        var timeout = timeout_ms != nil ? timeout_ms : 1500
        cl.set_timeouts(timeout)   # 1.5s is plenty on LAN; prevents watchdog resets if unit is offline
        cl.begin(f"http://{ip}/{get_msg}")
        var r = cl.GET()
        var s = nil
        if r == 200
            s = DAIKIN_PARSER.to_list(cl.get_string())
        else
            log(f"DAIKIN: HTTP {r} from {ip}/{get_msg}", 2)
        end
        cl.close()
        return s
    end

    # Periodic refresh - maybe we use TELEPERIOD in the future
    def every_second()
        if self.cfg == nil || !self.cfg.finished
            return
        end
        self.poll_tick += 1
        if self.poll_tick % self.POLL_SENSOR_EVERY == 0
            self.get_sensor_info()
        end
        if self.poll_tick % self.POLL_CONTROL_EVERY == self.POLL_CONTROL_EVERY / 2
            self.get_control_info()
        end
    end

    def get_model_info()
        for d : self.cfg.devices
            var info = self.read(d["ip"], "aircon/get_model_info")
            if info != nil
                for k : info.keys() d[k] = info[k] end
            end
        end
    end

    def get_control_info()
        for d : self.cfg.devices
            tasmota.yield()
            var info = self.read(d["ip"], "aircon/get_control_info")
            if info != nil
                for k : info.keys() d[k] = info[k] end
                d["__control_ready"] = true
                self.poll_succeeded(d)
                log(f"DAIKIN: Control info for {d.find('name','?')}: {info}", 3)
            else
                self.poll_failed(d)
            end
        end
    end

    def get_sensor_info()
        for d : self.cfg.devices
            tasmota.yield()
            var info = self.read(d["ip"], "aircon/get_sensor_info")
            if info != nil
                for k : info.keys() d[k] = info[k] end
                d["__sensor_ready"] = true
                self.poll_succeeded(d)
                log(f"DAIKIN: Sensor info for {d.find('name','?')}: {info}", 3)
            else
                self.poll_failed(d)
            end
        end
    end

    def poll_succeeded(d)
        var was_reachable = d.find("__reachable", true)
        d["__poll_failures"] = 0
        d["__last_success"] = tasmota.millis()
        d["__reachable"] = true
        if !was_reachable
            log(f"DAIKIN: {d.find('name','?')} is reachable again", 2)
        end
    end

    def poll_failed(d)
        var failures = d.find("__poll_failures", 0) + 1
        d["__poll_failures"] = failures
        if failures >= 3 && d.find("__reachable", true)
            d["__reachable"] = false
            log(f"DAIKIN: {d.find('name','?')} is unreachable after {failures} failed polls", 1)
        end
    end

    def find_device(name_ip_or_mac)
        if self.cfg == nil
            return nil
        end
        for d : self.cfg.devices
            if d.find("name") == name_ip_or_mac || d["ip"] == name_ip_or_mac || d.find("mac") == name_ip_or_mac
                return d
            end
        end
        return nil
    end

    # Writes the FULL control block back to the device - Daikin's API
    # resets unspecified fields to defaults if you only send a delta,
    # so `changes` is merged into the last-read control_info first.
    def set_control(d, changes)
        import string
        if d.find("__control_ready") != true
            log(f"DAIKIN: control_info for {d.find('name','?')} not read yet, run get_control_info first", 1)
            return false
        end
        for k : changes.keys()
            d[k] = changes[k]
        end
        var qs = string.format("pow=%s&mode=%s&stemp=%s&shum=%s&f_rate=%s&f_dir=%s",
                                d["pow"], d["mode"], d["stemp"],
                                d.find("shum", "0"), d.find("f_rate", "A"), d.find("f_dir", "0"))
        var res = self.read(d["ip"], "aircon/set_control_info?" + qs)
        return res != nil
    end

    #- ---- Console/MQTT commands ----
        DaikinPower   <device>,<0|1|on|off>
        DaikinMode    <device>,<auto|dehumidify|cool|heat|fan>
        DaikinSetTemp <device>,<temperature>
        DaikinFan     <device>,<auto|quiet|1|2|3|4|5>
        DaikinRescan  (no payload) - forces a fresh discovery
        DaikinStatus  (no payload) - dumps current state as JSON
        <device> is matched against the discovered name first, then IP.
    -#
    def add_commands()
        tasmota.add_cmd('DaikinPower', / cmd, idx, payload, payload_json -> self.cmd_power(payload))
        tasmota.add_cmd('DaikinMode', / cmd, idx, payload, payload_json -> self.cmd_mode(payload))
        tasmota.add_cmd('DaikinSetTemp', / cmd, idx, payload, payload_json -> self.cmd_settemp(payload))
        tasmota.add_cmd('DaikinFan', / cmd, idx, payload, payload_json -> self.cmd_fan(payload))
        tasmota.add_cmd('DaikinRescan', / cmd, idx, payload, payload_json -> self.cmd_rescan(payload))
        tasmota.add_cmd('DaikinStatus', / cmd, idx, payload, payload_json -> self.cmd_status(payload))
        tasmota.add_cmd('DaikinMatter', / cmd, idx, payload, payload_json -> self.cmd_matter(payload))
    end

    # Shared guard for every command that touches self.cfg.devices - config
    # may not be loaded yet (still waiting on network-up, or discovery/
    # verification still in flight). Returns true (and sends a response)
    # if the caller should stop here; false if it's safe to proceed.
    # resp_cmnd_str() wraps whatever string you give it as
    # {"<CommandName>":"<that string>"} itself - passing it an
    # already-formatted JSON blob (as earlier versions of this file did)
    # just gets that whole blob escaped and wrapped a second time.
    def not_ready()
        if self.cfg == nil || !self.cfg.finished
            tasmota.resp_cmnd_str("not ready yet - still starting up, try again shortly")
            return true
        end
        return false
    end

    def cmd_power(payload)
        if self.not_ready() return end
        import string
        var p = string.split(payload, ",")
        if size(p) < 2
            tasmota.resp_cmnd_str("usage: DaikinPower <device>,<on|off>")
            return
        end
        var d = self.find_device(p[0])
        if d == nil
            tasmota.resp_cmnd_str("unknown device - check DaikinStatus for the exact name")
            return
        end
        var on = (p[1] == "1" || string.tolower(p[1]) == "on")
        var ok = self.set_control(d, {"pow": on ? "1" : "0"})
        if ok
            tasmota.resp_cmnd_done()
        else
            tasmota.resp_cmnd_failed()
        end
    end

    def cmd_mode(payload)
        if self.not_ready() return end
        import string
        var p = string.split(payload, ",")
        if size(p) < 2
            tasmota.resp_cmnd_str("usage: DaikinMode <device>,<auto|dehumidify|cool|heat|fan>")
            return
        end
        var d = self.find_device(p[0])
        var code = self.MODE_TO_CODE.find(string.tolower(p[1]))
        if d == nil
            tasmota.resp_cmnd_str("unknown device - check DaikinStatus for the exact name")
            return
        end
        if code == nil
            tasmota.resp_cmnd_str("unknown mode - use auto/dehumidify/cool/heat/fan")
            return
        end
        var ok = self.set_control(d, {"mode": code})
        if ok
            tasmota.resp_cmnd_done()
        else
            tasmota.resp_cmnd_failed()
        end
    end

    def cmd_settemp(payload)
        if self.not_ready() return end
        import string
        var p = string.split(payload, ",")
        if size(p) < 2
            tasmota.resp_cmnd_str("usage: DaikinSetTemp <device>,<temperature>")
            return
        end
        var d = self.find_device(p[0])
        if d == nil
            tasmota.resp_cmnd_str("unknown device - check DaikinStatus for the exact name")
            return
        end
        var temp = real(p[1])
        if temp < 16 || temp > 30
            tasmota.resp_cmnd_str("temperature must be between 16 and 30 C")
            return
        end
        var ok = self.set_control(d, {"stemp": str(temp)})
        if ok
            tasmota.resp_cmnd_done()
        else
            tasmota.resp_cmnd_failed()
        end
    end

    def cmd_fan(payload)
        if self.not_ready() return end
        import string
        var p = string.split(payload, ",")
        if size(p) < 2
            tasmota.resp_cmnd_str("usage: DaikinFan <device>,<auto|quiet|1|2|3|4|5>")
            return
        end
        var d = self.find_device(p[0])
        var code = self.FAN_TO_CODE.find(string.tolower(p[1]))
        if d == nil
            tasmota.resp_cmnd_str("unknown device - check DaikinStatus for the exact name")
            return
        end
        if code == nil
            tasmota.resp_cmnd_str("unknown fan rate - use auto/quiet/1/2/3/4/5")
            return
        end
        var ok = self.set_control(d, {"f_rate": code})
        if ok
            tasmota.resp_cmnd_done()
        else
            tasmota.resp_cmnd_failed()
        end
    end

    def cmd_rescan(payload)
        if self.cfg == nil
            tasmota.resp_cmnd_str("not ready yet - still starting up, try again shortly")
            return
        end
        # No need to touch persist here: a fresh discovery's completion()
        # overwrites persist.daikin_devices with whatever it finds.
        self.cfg.rescan()
        tasmota.resp_cmnd_done()
    end

    def cmd_matter(payload)
        if self.not_ready() return end
        import string
        var p = string.split(payload, ",")
        if size(p) < 2
            tasmota.resp_cmnd_str("usage: DaikinMatter <device>,<0|1|on|off>")
            return
        end
        var d = self.find_device(p[0])
        if d == nil
            tasmota.resp_cmnd_str("unknown device - check DaikinStatus for the exact name")
            return
        end
        var enable = (p[1] == "1" || string.tolower(p[1]) == "on")
        d["matter"] = enable ? 1 : 0
        self.cfg.save_to_persist(self.cfg.devices)

        self.setup_matter()

        if self.matter_mgr != nil
            self.matter_mgr.sync(self.cfg.devices)
        else
            log("DAIKIN: Matter setting saved to persist, but Matter bridge is not active on this Tasmota build", 1)
        end

        tasmota.resp_cmnd_done()
    end

    def cmd_status(payload)
        if self.not_ready() return end
        if size(self.cfg.devices) == 0
            tasmota.resp_cmnd_str("no devices found - try DaikinRescan")
            return
        end
        import json
        var out = []
        for d : self.cfg.devices
            out.push({"Name": d.find("name", "?"), "IP": d["ip"],
                       "Power": d.find("pow", "?"),
                       "Mode": self.CODE_TO_MODE.find(d.find("mode", "?"), d.find("mode", "?")),
                       "SetTemp": d.find("stemp", "?"),
                       "RoomTemp": d.find("htemp", "?"),
                       "OutdoorTemp": d.find("otemp", "?"),
                       "Reachable": d.find("__reachable", true),
                       "Matter": d.find("matter", 0) == 1 ? "on" : "off"})
        end
        # resp_cmnd() sends the string as-is (no extra wrapping), so we
        # must build the complete JSON ourselves rather than passing a
        # pre-encoded string to resp_cmnd_str() (which would escape it).
        tasmota.resp_cmnd(json.dump({"DaikinStatus": out}))
    end

    def json_append()
        import string
        if self.cfg == nil || !self.cfg.finished
            return nil
        end
        var msg = ""
        for d : self.cfg.devices
            if d.find("__sensor_ready") != true
                continue
            end
            msg += string.format(",\"Daikin_%s\":{\"Power\":%s,\"Mode\":\"%s\",\"Temperature\":%.2f,\"OutdoorTemperature\":%.2f,\"SetTemp\":%s,\"Reachable\":%s}",
                                  d.find("name", "AC"), d.find("pow", "0"),
                                  self.CODE_TO_MODE.find(d.find("mode", "0"), "?"),
                                  real(d.find("htemp", "0")), real(d.find("otemp", "0")),
                                  d.find("stemp", "0"), d.find("__reachable", true) ? "true" : "false")
        end
        if msg != ""
            tasmota.response_append(msg)
        end
        return true
    end

    def dump()
        print(self.cfg.devices)
    end

    def web_sensor()
        import string
        if self.cfg == nil || !self.cfg.finished
            return nil
        end
        var msg = ""
        for d : self.cfg.devices
            if d.find("__sensor_ready") != true
                continue
            end
            msg += string.format("{s}%s (%s){m}%s{e}"..
                                  "{s}Room Temperature{m}%.2f °C{e}"..
                                  "{s}Outdoor Temperature{m}%.2f °C{e}"..
                                  "{s}Target Temperature{m}%s °C{e}",
                                  d.find("name", "AC"), d["ip"],
                                  d.find("pow", "0") == "1" ? "On" : "Off",
                                  real(d.find("htemp", "0")), real(d.find("otemp", "0")),
                                  d.find("stemp", "-"))
        end
        if msg != ""
            tasmota.web_send_decimal(msg)
        end
        return true
    end
end

return DAIKIN()
