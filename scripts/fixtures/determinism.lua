-- @trace order:1384-bp6t — one script, one byte stream: encode a 12-key table
-- and walk it with pairs. Runs in the CACHEABLE class, which has no print, so
-- it RETURNS both lines; `tillandsias-plan lua` prints return values.
local t = { alpha = 1, beta = 2, gamma = 3, delta = 4, eps = 5, zeta = 6,
            eta = 7, theta = 8, iota = 9, kappa = 10, lambda = 11, mu = 12 }
local walk = {}
for k, v in pairs(t) do walk[#walk + 1] = k .. "=" .. v end
return json.encode(t), table.concat(walk, ",")
