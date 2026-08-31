import matter
import global

var matter_base = global.matter_device.plugins_classes['thermostat']

class Matter_Plugin_Daikin_Thermostat : matter_base
    static var TYPE = "daikin_thermostat"
    static var DISPLAY_NAME = "Daikin Thermostat"
    static var VIRTUAL = true

    var daikin_driver_ref
    var daikin_mac
    var last_unknown_mode
    var last_reachable

    # Daikin's mode codes and Matter's SystemMode enum only happen to
    # agree numerically for Cool(3)/Heat(4).
    static MODE_D2M = {"0": 1, "2": 8, "3": 3, "4": 4, "6": 7}
    static MODE_M2D = {1: "0", 8: "2", 3: "3", 4: "4", 7: "6"}

    def init(device, endpoint, config)
        super(self).init(device, endpoint, config)
    end

    def parse_configuration(config)
        super(self).parse_configuration(config)
        self.daikin_mac = config.find("daikin_mac", nil)
    end

    def daikin_device()
        var drv = self.daikin_driver_ref
        if drv == nil || self.daikin_mac == nil
            return nil
        end
        return drv.find_device(self.daikin_mac)
    end

    # The base thermostat assumes that selecting Cool/Heat means the
    # compressor is running. Use Daikin's compressor frequency when the
    # adapter supplies it, while still reporting fan/dry operation.
    def compute_running_state()
        var d = self.daikin_device()
        if d == nil || d.find("pow", "0") == "0"
            return 0
        end
        var freq = d.find("cmpfreq", nil)
        if freq != nil && real(freq) <= 0
            return 0
        end
        var mode = d.find("mode")
        if mode == "3" return 0x0002 end
        if mode == "4" return 0x0001 end
        if mode == "2" || mode == "6" return 0x0004 end
        return 0
    end

    def update_running_state()
        var running = self.compute_running_state()
        if running != self.shadow_running_state
            self.shadow_running_state = running
            self.attribute_updated(0x0201, 0x0029)
        end
    end

    def update_shadow_lazy()
        var d = self.daikin_device()
        if d == nil
            return
        end
        var reachable = d.find("__reachable", true)
        if self.last_reachable != reachable
            self.last_reachable = reachable
            self.attribute_updated(0x0039, 0x0011)
        end
        if d.find("htemp") != nil
            var t = int(real(d["htemp"]) * 100)
            if t != self.shadow_local_temperature
                self.shadow_local_temperature = t
                self.attribute_updated(0x0201, 0x0000)
            end
        end
        if d.find("pow") != nil && d.find("mode") != nil
            if d["pow"] == "0"
                if self.shadow_system_mode != 0
                    self.set_system_mode(0)
                end
            else
                var matter_mode = self.MODE_D2M.find(d["mode"], nil)
                if matter_mode != nil
                    if self.shadow_system_mode != matter_mode
                        self.set_system_mode(matter_mode)
                    end
                    self.last_unknown_mode = nil
                elif self.last_unknown_mode != d["mode"]
                    self.last_unknown_mode = d["mode"]
                    log(f"DAIKIN_MATTER: Unsupported Daikin mode {d['mode']} on {d.find('name','?')}", 1)
                end
            end
            self.update_running_state()
        end
        if d.find("stemp") != nil
            var sp = int(real(d["stemp"]) * 100)
            if self.shadow_system_mode == 4
                if self.shadow_heating_setpoint != sp
                    self.set_heating_setpoint(sp)
                end
            else
                if self.shadow_cooling_setpoint != sp
                    self.set_cooling_setpoint(sp)
                end
            end
        end
    end

    # Supply stable bridge identity and actual poll reachability instead
    # of Tasmota's defaults for a local/virtual endpoint.
    def read_attribute(session, ctx, tlv_solo)
        if ctx.cluster == 0x0039
            var d = self.daikin_device()
            if ctx.attribute == 0x0011
                return tlv_solo.set(0x08, d != nil && d.find("__reachable", true))
            elif ctx.attribute == 0x000F || ctx.attribute == 0x0012
                return tlv_solo.set(0x0C, d == nil ? str(self.daikin_mac ? self.daikin_mac : "") : str(d.find("mac", self.daikin_mac ? self.daikin_mac : "")))
            end
        end
        return super(self).read_attribute(session, ctx, tlv_solo)
    end

    def thermostat_state_changed()
        var drv = self.daikin_driver_ref
        var d = self.daikin_device()
        if drv == nil || d == nil
            return
        end
        var changes = {}
        if self.shadow_system_mode == 0
            changes["pow"] = "0"
        else
            var mode = self.MODE_M2D.find(self.shadow_system_mode, nil)
            if mode == nil
                log(f"DAIKIN_MATTER: Unsupported Matter system mode {self.shadow_system_mode}", 1)
                return
            end
            changes["pow"] = "1"
            changes["mode"] = mode
            changes["stemp"] = str(self.active_setpoint() / 100.0)
        end
        drv.set_control(d, changes)
    end
end

# Register plugin class the canonical Tasmota way
matter.Plugin_Daikin_Thermostat = Matter_Plugin_Daikin_Thermostat

class DAIKIN_MATTER
    var daikin_driver
    var matter_device

    def init(daikin_driver)
        import global
        self.daikin_driver = daikin_driver
        self.matter_device = global.matter_device
    end

    def identity(d)
        return d.find("mac", d.find("name"))
    end

    # Create a plugin instance for an existing persisted endpoint.
    def _restore_plugin(ep, conf)
        var plugin = Matter_Plugin_Daikin_Thermostat(self.matter_device, ep, conf)
        plugin.daikin_driver_ref = self.daikin_driver
        self.matter_device.plugins.push(plugin)
        return plugin
    end

    # Create a brand-new endpoint: allocate ep number, create plugin, persist.
    def _new_endpoint(conf)
        var md = self.matter_device
        var ep = md.next_ep
        md.next_ep = ep + 1
        conf['type'] = 'daikin_thermostat'
        var plugin = Matter_Plugin_Daikin_Thermostat(md, ep, conf)
        plugin.daikin_driver_ref = self.daikin_driver
        md.plugins.push(plugin)
        if md.plugins_config == nil
            md.plugins_config = {}
        end
        md.plugins_config[str(ep)] = conf
        md.save_param()
        tasmota.yield()
        return ep
    end

    def reconcile(d)
        var id = self.identity(d)
        if id == nil || self.matter_device == nil || self.matter_device.plugins_config == nil
            return nil
        end
        for ep_s : self.matter_device.plugins_config.keys()
            var conf = self.matter_device.plugins_config[ep_s]
            if conf.find("type") != "daikin_thermostat"
                continue
            end
            if conf.find("daikin_mac") != id
                continue
            end
            var ep = int(ep_s)
            var plugin = self.matter_device.find_plugin_by_endpoint(ep)
            if plugin == nil
                plugin = self._restore_plugin(ep, conf)
                log(f"DAIKIN_MATTER: Restored persisted endpoint {ep} for {d.find('name','?')}", 2)
            end
            if plugin != nil
                plugin.daikin_driver_ref = self.daikin_driver
            end
            return ep
        end
        return nil
    end

    def add(d)
        var existing = self.reconcile(d)
        if existing != nil return existing end
        var conf = {'name': d.find("name"), 'daikin_mac': d.find("mac")}
        var ep = self._new_endpoint(conf)
        log(f"DAIKIN_MATTER: Added Matter endpoint {ep} for {d.find('name','?')}", 2)
        return ep
    end

    def remove(d)
        var id = self.identity(d)
        if id == nil || self.matter_device == nil || self.matter_device.plugins_config == nil
            return false
        end
        for ep_s : self.matter_device.plugins_config.keys()
            var conf = self.matter_device.plugins_config[ep_s]
            if conf.find("type") != "daikin_thermostat" continue end
            if conf.find("daikin_mac") != id continue end
            var ep = int(ep_s)
            try
                self.matter_device.bridge_remove_endpoint(ep)
                log(f"DAIKIN_MATTER: Removed Matter endpoint {ep} for {d.find('name','?')}", 2)
                return true
            except .. as e, m
                log(f"DAIKIN_MATTER: Failed to remove endpoint: {e} {m}", 1)
                return false
            end
        end
        return false
    end

    def sync(devices)
        if devices == nil return end
        for d : devices
            var enabled = (d.find("matter", 0) == 1 || d.find("matter", 0) == "1" || d.find("matter", 0) == true)
            if enabled
                self.add(d)
            else
                self.remove(d)
            end
        end
    end

    def unload()
        self.daikin_driver = nil
        self.matter_device = nil
    end
end

return {"DAIKIN_MATTER": DAIKIN_MATTER}

