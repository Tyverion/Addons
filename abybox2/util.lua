local util = {}

function util.params_hex(p)
  local t = {}; for i=1,#p do t[#t+1]=('%02X'):format(p:byte(i)) end
  return table.concat(t, ' ')
end

function util.params_tail_u32_le(p)
  if #p < 32 then return 0 end
  local b1,b2,b3,b4 = p:byte(29,32) -- 1-based; bytes 28..31 zero-based
  return b1 + b2*256 + b3*65536 + b4*16777216
end

function util.chest_sig(zone, menu_id, p)
  return ('%d:%d:%08X'):format(zone, menu_id, util.params_tail_u32_le(p or ''))
end

function util.chest_state_byte(p) return (p and #p>=1) and p:byte(1) or nil end
function util.chest_w1(p)
  if not p or #p<4 then return nil end
  local lo,hi = p:byte(3), p:byte(4) -- 1-based; bytes 2..3 zero-based
  return lo + hi*256
end

return util
