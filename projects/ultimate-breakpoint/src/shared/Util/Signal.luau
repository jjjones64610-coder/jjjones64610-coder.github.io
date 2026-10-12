--!strict
-- Minimal synchronous signal for communication between services/controllers.

local Signal = {}
Signal.__index = Signal

export type Connection = { Disconnect: (self: Connection) -> (), connected: boolean }
export type Signal = typeof(setmetatable({} :: { handlers: { (...any) -> () } }, Signal))

function Signal.new(): Signal
	return setmetatable({ handlers = {} }, Signal)
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): Connection
	table.insert(self.handlers, fn)
	local conn = { connected = true } :: any
	function conn.Disconnect(c)
		if not c.connected then
			return
		end
		c.connected = false
		local i = table.find(self.handlers, fn)
		if i then
			table.remove(self.handlers, i)
		end
	end
	return conn
end

function Signal.Fire(self: Signal, ...: any)
	for _, fn in table.clone(self.handlers) do
		local args = table.pack(...)
		local ok, err = pcall(function()
			fn(table.unpack(args, 1, args.n))
		end)
		if not ok then
			warn("[Signal] handler error: " .. tostring(err))
		end
	end
end

return Signal
