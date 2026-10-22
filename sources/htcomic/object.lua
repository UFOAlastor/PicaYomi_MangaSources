-- Private adapter helper, not a host base class or a public source contract.
local O={}
function O:extend(child) return setmetatable(child,{__index=self}) end
function O:hasCapability(name) return self.capabilities[name]==true end
function O:init() end
function O:getToken() return nil end
function O:isLoggedIn() return self:getToken()~=nil end
function O:getSortOptions() return {} end
function O:isCachedImageStale() return false end
return O
