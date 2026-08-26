# rm Zigbee_Toggle.tapp; zip -j -0 Zigbee_Toggle.tapp Zigbee_Toggle/*
do                          # embed in `do` so we don't add anything to global namespace
  import introspect
  var zigbee_toggle = introspect.module('zigbee_toggle', true)     # load module but don't cache
  tasmota.add_extension(zigbee_toggle)
end

# to remove:
#       tasmota.unload_extension('Zigbee Toggle')
