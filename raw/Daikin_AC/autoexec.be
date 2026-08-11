do
  import introspect
  var daikin_ext = introspect.module('daikin', true)
  tasmota.add_extension(daikin_ext)
end
