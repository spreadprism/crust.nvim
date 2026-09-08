---@class Crust.Pi
local Pi = {}
Pi.__index = Pi

---@return Crust.Pi
function Pi.new()
	local self = setmetatable({}, Pi)

	return self
end

return Pi
